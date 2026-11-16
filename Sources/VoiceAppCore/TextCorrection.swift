import Foundation

public struct TextReplacement: Equatable, Sendable {
    public let original: String
    /// UTF-16 range in the original input, suitable for NSString and NSAttributedString.
    public let range: NSRange
    public let replacement: String
    public let termID: UUID
}

public struct TextCorrectionResult: Equatable, Sendable {
    public let text: String
    public let replacements: [TextReplacement]
    public let converged: Bool
}

/// Applies up to eight longest-match passes. A false convergence flag means a pass or growth limit was reached.
public func correctText(_ text: String, terms: [DictionaryTerm]) -> TextCorrectionResult {
    CorrectionMatcher(terms: terms).correct(text)
}

private struct DictionaryCorrectionEdit {
    let range: NSRange
    let term: DictionaryTerm
}

private struct CorrectionSource {
    let range: NSRange
    let termID: UUID?
    let generation: Int
}

/// Prebuilt dictionary matcher that can be reused across dictations until terms change.
public struct CorrectionMatcher: Sendable {
    public static let empty = CorrectionMatcher(terms: [])

    private struct Node: Sendable {
        var children: [Unicode.Scalar: Int] = [:]
        var terms: [DictionaryTerm] = []
    }

    private var nodes = [Node()]

    public init(terms: [DictionaryTerm]) {
        let locale = Locale(identifier: "en_US_POSIX")
        for term in terms {
            let trimmedText = DictionaryTerm.trimEdgeWhitespace(term.text)
            guard term.deletedAt == nil, !trimmedText.isEmpty else { continue }
            var normalizedTerm = term
            normalizedTerm.text = trimmedText
            var seen: Set<String> = []
            for value in [trimmedText] + term.aliases {
                let trimmedValue = DictionaryTerm.trimEdgeWhitespace(value)
                guard !trimmedValue.isEmpty else { continue }
                let folded = trimmedValue.folding(options: .caseInsensitive, locale: locale)
                    .precomposedStringWithCanonicalMapping
                var scalars: [Unicode.Scalar] = []
                for scalar in folded.unicodeScalars {
                    if scalar.properties.isWhitespace {
                        if scalars.last != " " { scalars.append(" ") }
                    } else {
                        scalars.append(scalar)
                    }
                }
                while scalars.first == " " { scalars.removeFirst() }
                while scalars.last == " " { scalars.removeLast() }
                guard !scalars.isEmpty, seen.insert(String(String.UnicodeScalarView(scalars))).inserted else { continue }
                var node = 0
                for scalar in scalars {
                    if let child = nodes[node].children[scalar] {
                        node = child
                    } else {
                        let child = nodes.count
                        nodes.append(Node())
                        nodes[node].children[scalar] = child
                        node = child
                    }
                }
                nodes[node].terms.append(normalizedTerm)
            }
        }
    }

    /// Applies up to eight longest-match passes. A false convergence flag means a pass or growth limit was reached.
    public func correct(_ text: String) -> TextCorrectionResult {
        guard !text.isEmpty, !nodes[0].children.isEmpty else {
            return TextCorrectionResult(text: text, replacements: [], converged: true)
        }
        let original = text as NSString
        var output = text
        var sources = (0..<original.length).map {
            CorrectionSource(range: NSRange(location: $0, length: 1), termID: nil, generation: 0)
        }
        let growthLimit = original.length.addingReportingOverflow(1_048_576)
        let maximumLength = growthLimit.overflow ? Int.max : growthLimit.partialValue
        var generation = 0
        var converged = false
        for _ in 0..<8 {
            let edits = edits(in: output)
            if edits.isEmpty {
                converged = true
                break
            }
            var length = sources.count
            var fits = true
            for edit in edits {
                let change = edit.term.text.utf16.count - edit.range.length
                let next = length.addingReportingOverflow(change)
                if next.overflow || next.partialValue > maximumLength { fits = false; break }
                length = next.partialValue
            }
            guard fits else { break }
            let units = Array(output.utf16)
            var nextUnits: [UInt16] = []
            var nextSources: [CorrectionSource] = []
            nextUnits.reserveCapacity(length)
            nextSources.reserveCapacity(length)
            var cursor = 0
            for edit in edits {
                nextUnits.append(contentsOf: units[cursor..<edit.range.location])
                nextSources.append(contentsOf: sources[cursor..<edit.range.location])
                let end = NSMaxRange(edit.range)
                var sourceRange = sources[edit.range.location].range
                for source in sources[edit.range.location..<end] {
                    sourceRange = NSUnionRange(sourceRange, source.range)
                }
                generation += 1
                let replacement = Array(edit.term.text.utf16)
                nextUnits.append(contentsOf: replacement)
                nextSources.append(contentsOf: repeatElement(
                    CorrectionSource(range: sourceRange, termID: edit.term.id, generation: generation),
                    count: replacement.count))
                cursor = end
            }
            nextUnits.append(contentsOf: units[cursor...])
            nextSources.append(contentsOf: sources[cursor...])
            output = String(decoding: nextUnits, as: UTF16.self)
            sources = nextSources
        }
        // The eighth pass may itself reach the fixed point; checking does not apply a ninth pass.
        if !converged { converged = edits(in: output).isEmpty }
        return TextCorrectionResult(text: output,
            replacements: mergedReplacements(original: original, output: output as NSString, sources: sources),
            converged: converged)
    }

    private func edits(in text: String) -> [DictionaryCorrectionEdit] {
        let string = text as NSString
        let boundaries = WordBoundaries(text)
        let units = normalizedUnits(text)
        var candidates: [DictionaryCorrectionEdit] = []
        for start in units.indices where units[start].isStart && boundaries.allowsStart(units[start].range.location) {
            var node = 0
            var end = start
            while end < units.count, let child = nodes[node].children[units[end].scalar] {
                node = child
                if units[end].isEnd && !nodes[node].terms.isEmpty {
                    let range = NSRange(location: units[start].range.location,
                        length: NSMaxRange(units[end].range) - units[start].range.location)
                    if boundaries.allowsEnd(NSMaxRange(range)) {
                        for term in nodes[node].terms { candidates.append(DictionaryCorrectionEdit(range: range, term: term)) }
                    }
                }
                end += 1
            }
        }
        candidates.sort {
            if $0.range.length != $1.range.length { return $0.range.length > $1.range.length }
            if $0.range.location != $1.range.location { return $0.range.location < $1.range.location }
            if $0.term.id != $1.term.id { return $0.term.id.uuidString < $1.term.id.uuidString }
            return $0.term.text.utf8.lexicographicallyPrecedes($1.term.text.utf8)
        }
        var occupied = Array(repeating: false, count: string.length)
        var edits: [DictionaryCorrectionEdit] = []
        for candidate in candidates {
            let range = candidate.range.location..<NSMaxRange(candidate.range)
            guard !occupied[range].contains(true) else { continue }
            for index in range { occupied[index] = true }
            if !string.substring(with: candidate.range).utf8.elementsEqual(candidate.term.text.utf8) {
                edits.append(candidate)
            }
        }
        return edits.sorted { $0.range.location < $1.range.location }
    }
}

private struct CorrectionUnit {
    let scalar: Unicode.Scalar
    var range: NSRange
    let isStart: Bool
    let isEnd: Bool
}

private func normalizedUnits(_ text: String) -> [CorrectionUnit] {
    var units: [CorrectionUnit] = []
    let locale = Locale(identifier: "en_US_POSIX")
    var offset = 0
    for character in text {
        let value = String(character)
        let range = NSRange(location: offset, length: value.utf16.count)
        offset += range.length
        if value.unicodeScalars.allSatisfy({ $0.properties.isWhitespace }) {
            if units.last?.scalar == " " {
                units[units.count - 1].range = NSUnionRange(units[units.count - 1].range, range)
            } else {
                units.append(CorrectionUnit(scalar: " ", range: range, isStart: true, isEnd: true))
            }
        } else {
            let folded = Array(value.folding(options: .caseInsensitive, locale: locale)
                .precomposedStringWithCanonicalMapping.unicodeScalars)
            for (index, scalar) in folded.enumerated() {
                // Folding can expand a grapheme (for example ß); never match only part of its source.
                units.append(CorrectionUnit(scalar: scalar, range: range,
                    isStart: index == 0, isEnd: index == folded.count - 1))
            }
        }
    }
    return units
}

private struct WordBoundaries {
    private var word: [Bool] = []
    private var joiner: [Bool] = []

    init(_ text: String) {
        word.reserveCapacity(text.utf16.count)
        joiner.reserveCapacity(text.utf16.count)
        for scalar in text.unicodeScalars {
            let isWord: Bool
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .nonspacingMark, .spacingMark, .enclosingMark, .decimalNumber, .letterNumber,
                 .otherNumber, .connectorPunctuation:
                isWord = true
            default:
                isWord = false
            }
            let isJoiner = "'’‐‑-".unicodeScalars.contains(scalar)
            for _ in scalar.utf16 {
                word.append(isWord)
                joiner.append(isJoiner)
            }
        }
    }

    func allowsStart(_ start: Int) -> Bool {
        if start > 0, word[start - 1] { return false }
        // Joiners inside a word are not boundaries; surrounding quotation marks still are.
        return !(start > 1 && joiner[start - 1] && word[start - 2])
    }

    func allowsEnd(_ end: Int) -> Bool {
        if end < word.count, word[end] { return false }
        return !(end + 1 < word.count && joiner[end] && word[end + 1])
    }
}

private func mergedReplacements(original: NSString, output: NSString, sources: [CorrectionSource]) -> [TextReplacement] {
    var replacements: [TextReplacement] = []
    var cursor = 0
    while cursor < sources.count {
        guard var termID = sources[cursor].termID else { cursor += 1; continue }
        var range = sources[cursor].range
        var generation = sources[cursor].generation
        let start = cursor
        cursor += 1
        // A partial rewrite still owns the whole earlier source range, including its unchanged edges.
        while cursor < sources.count, sources[cursor].range.location < NSMaxRange(range) {
            let source = sources[cursor]
            range = NSUnionRange(range, source.range)
            if source.generation > generation, let lastTerm = source.termID {
                generation = source.generation
                termID = lastTerm
            }
            cursor += 1
        }
        let replacement = output.substring(with: NSRange(location: start, length: cursor - start))
        let before = original.substring(with: range)
        if !before.utf8.elementsEqual(replacement.utf8) {
            replacements.append(TextReplacement(original: before, range: range, replacement: replacement, termID: termID))
        }
    }
    return replacements
}
