import Foundation

public enum CorrectionEditValidator {
    private static let shellSignificantScalars: Set<Unicode.Scalar> = Set(
        [">", "<", "|", "&", ";", "$", "`", "\\"].compactMap { Unicode.Scalar($0) }
    )

    public static func apply(
        _ edits: [CorrectionEdit],
        to text: String,
        protectedRanges: [Range<String.Index>] = [],
        maxWordChangeRatio: Double = CloudCorrectionConfig.maxWordChangeRatio
    ) throws -> String {
        guard !edits.isEmpty else { return text }

        let textWordRanges = wordTokenRanges(in: text)
        var matched: [(range: Range<String.Index>, edit: CorrectionEdit)] = []
        matched.reserveCapacity(edits.count)

        for edit in edits {
            guard !edit.original.isEmpty else {
                throw EditValidationError.emptyOriginal
            }
            guard edit.original.first?.isWhitespace != true,
                  edit.original.last?.isWhitespace != true,
                  edit.replacement.first?.isWhitespace != true,
                  edit.replacement.last?.isWhitespace != true else {
                throw EditValidationError.invalidWhitespaceOrControlCharacters
            }
            guard controlOrNewlineScalars(in: edit.replacement) == controlOrNewlineScalars(in: edit.original) else {
                throw EditValidationError.invalidWhitespaceOrControlCharacters
            }
            if let first = edit.replacement.unicodeScalars.first {
                let category = first.properties.generalCategory
                guard category != .nonspacingMark, category != .spacingMark,
                      category != .enclosingMark, category != .format,
                      !first.properties.isDefaultIgnorableCodePoint else {
                    throw EditValidationError.invalidWhitespaceOrControlCharacters
                }
            }
            // Preserve existing emoji joiners/variation selectors only inside the same grapheme.
            let originalInvisibleGraphemes = edit.original.filter { $0.unicodeScalars.contains(where: isInvisible) }
            let replacementInvisibleGraphemes = edit.replacement.filter { $0.unicodeScalars.contains(where: isInvisible) }
            guard originalInvisibleGraphemes == replacementInvisibleGraphemes else {
                throw EditValidationError.invalidWhitespaceOrControlCharacters
            }
            if introducesDisallowedShellCharacters(from: edit.original, to: edit.replacement) {
                throw EditValidationError.disallowedShellCharacters
            }

            let origEditWords = wordTokenRanges(in: edit.original)
            let replEditWords = wordTokenRanges(in: edit.replacement)
            guard !origEditWords.isEmpty, !replEditWords.isEmpty else {
                throw EditValidationError.unalignedWordBoundary(edit.original)
            }
            guard origEditWords.count <= CloudCorrectionConfig.maxEditWordCount,
                  replEditWords.count <= CloudCorrectionConfig.maxEditWordCount,
                  abs(replEditWords.count - origEditWords.count) <= CloudCorrectionConfig.maxEditWordCountDelta,
                  edit.replacement.count <= edit.original.count * 2 + 8,
                  edit.replacement.unicodeScalars.count <= edit.original.unicodeScalars.count * 2 + 16 else {
                throw EditValidationError.excessiveExpansion
            }

            let occurrences = findGraphemeOccurrences(of: edit.original, in: text)
            guard !occurrences.isEmpty else {
                throw EditValidationError.originalNotFound(edit.original)
            }
            guard occurrences.count == 1, let range = occurrences.first else {
                throw EditValidationError.ambiguousMatch(edit.original)
            }

            guard !isStrictlyInsideAnyWord(range.lowerBound, wordRanges: textWordRanges),
                  !isStrictlyInsideAnyWord(range.upperBound, wordRanges: textWordRanges) else {
                throw EditValidationError.unalignedWordBoundary(edit.original)
            }

            if !protectedRanges.isEmpty,
               let changedRange = changedRangeInText(
                   matchRange: range,
                   in: text,
                   original: edit.original,
                   replacement: edit.replacement
               ),
               protectedRanges.contains(where: { $0.overlaps(changedRange) }) {
                throw EditValidationError.protectedDictionarySpan(edit.original)
            }

            matched.append((range: range, edit: edit))
        }

        matched.sort { $0.range.lowerBound < $1.range.lowerBound }

        for index in 1..<matched.count {
            if matched[index - 1].range.upperBound > matched[index].range.lowerBound {
                throw EditValidationError.overlappingEdits
            }
        }

        let totalWords = textWordRanges.count
        let maxAllowed = totalWords < CloudCorrectionConfig.minWordsForCloudCorrection
            ? 0
            : Int(floor(Double(totalWords) * maxWordChangeRatio + 1e-9))

        var result = ""
        result.reserveCapacity(text.count)
        var cursor = text.startIndex
        for (range, edit) in matched {
            result.append(contentsOf: text[cursor..<range.lowerBound])
            result.append(edit.replacement)
            cursor = range.upperBound
        }
        result.append(contentsOf: text[cursor..<text.endIndex])

        let expectedGraphemes = text.count + matched.reduce(0) {
            $0 + $1.edit.replacement.count - text[$1.range].count
        }
        guard result.count == expectedGraphemes else {
            throw EditValidationError.invalidWhitespaceOrControlCharacters
        }
        let changedWords = changedWordCount(from: text, to: result)
        if changedWords > maxAllowed {
            throw EditValidationError.excessiveChanges(
                changedWords: changedWords, totalWords: totalWords, maxAllowed: maxAllowed
            )
        }

        if result.count > text.count * 2 + 16
            || result.unicodeScalars.count > text.unicodeScalars.count * 2 + 32 {
            throw EditValidationError.excessiveExpansion
        }

        return result
    }

    static func changedWordCount(from original: String, to replacement: String) -> Int {
        guard original != replacement else { return 0 }
        let originalWords = wordTokens(in: original)
        let replacementWords = wordTokens(in: replacement)
        // Diff the complete transcript so removing punctuation cannot hide merged neighbours.
        let difference = replacementWords.difference(from: originalWords)
        return max(1, max(difference.removals.count, difference.insertions.count))
    }

    static func wordTokens(in text: String) -> [String] {
        wordTokenRanges(in: text).map { String(text[$0]) }
    }

    private static func wordTokenRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { _, range, _, _ in
            ranges.append(range)
        }
        return ranges
    }

    private static func isStrictlyInsideAnyWord(_ index: String.Index, wordRanges: [Range<String.Index>]) -> Bool {
        wordRanges.contains { $0.lowerBound < index && index < $0.upperBound }
    }

    private static func findGraphemeOccurrences(of substring: String, in text: String) -> [Range<String.Index>] {
        let targetChars = Array(substring)
        guard !targetChars.isEmpty else { return [] }

        var charIndices: [String.Index] = []
        charIndices.reserveCapacity(text.count)
        var chars: [Character] = []
        chars.reserveCapacity(text.count)

        var idx = text.startIndex
        while idx < text.endIndex {
            charIndices.append(idx)
            chars.append(text[idx])
            idx = text.index(after: idx)
        }

        guard chars.count >= targetChars.count else { return [] }
        var ranges: [Range<String.Index>] = []
        let lastStart = chars.count - targetChars.count
        for start in 0...lastStart {
            if chars[start..<(start + targetChars.count)].elementsEqual(targetChars) {
                let lower = charIndices[start]
                let upper = (start + targetChars.count < charIndices.count)
                    ? charIndices[start + targetChars.count]
                    : text.endIndex
                ranges.append(lower..<upper)
            }
        }
        return ranges
    }

    private static func changedRangeInText(
        matchRange: Range<String.Index>,
        in text: String,
        original: String,
        replacement: String
    ) -> Range<String.Index>? {
        guard original != replacement else { return nil }

        let origChars = Array(original)
        let replChars = Array(replacement)

        var matchCharBoundaries: [String.Index] = []
        matchCharBoundaries.reserveCapacity(origChars.count + 1)
        var cursor = matchRange.lowerBound
        while cursor < matchRange.upperBound {
            matchCharBoundaries.append(cursor)
            cursor = text.index(after: cursor)
        }
        matchCharBoundaries.append(matchRange.upperBound)

        guard matchCharBoundaries.count == origChars.count + 1 else {
            return matchRange
        }

        var prefixLen = 0
        while prefixLen < origChars.count,
              prefixLen < replChars.count,
              origChars[prefixLen] == replChars[prefixLen] {
            prefixLen += 1
        }
        while prefixLen > 0 {
            if origChars[prefixLen - 1].isWhitespace && replChars[prefixLen - 1].isWhitespace {
                break
            }
            prefixLen -= 1
        }

        var suffixLen = 0
        while suffixLen < origChars.count - prefixLen,
              suffixLen < replChars.count - prefixLen,
              origChars[origChars.count - 1 - suffixLen] == replChars[replChars.count - 1 - suffixLen] {
            suffixLen += 1
        }
        while suffixLen > 0 {
            if origChars[origChars.count - suffixLen].isWhitespace
                && replChars[replChars.count - suffixLen].isWhitespace {
                break
            }
            suffixLen -= 1
        }

        let lowerOffset = prefixLen
        let upperOffset = origChars.count - suffixLen
        guard lowerOffset < upperOffset else {
            return matchRange
        }
        return matchCharBoundaries[lowerOffset]..<matchCharBoundaries[upperOffset]
    }

    private static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .format
            || scalar.properties.isDefaultIgnorableCodePoint
            || (scalar.properties.isWhitespace && scalar != " ")
            || scalar == "\u{2800}"
    }

    private static func controlOrNewlineScalars(in text: String) -> [Unicode.Scalar] {
        text.unicodeScalars.filter { scalar in
            let category = scalar.properties.generalCategory
            return category == .control
                || category == .lineSeparator
                || category == .paragraphSeparator
                || CharacterSet.newlines.contains(scalar)
        }
    }

    private static func introducesDisallowedShellCharacters(from original: String, to replacement: String) -> Bool {
        var origCounts: [Unicode.Scalar: Int] = [:]
        for scalar in original.unicodeScalars where shellSignificantScalars.contains(scalar) {
            origCounts[scalar, default: 0] += 1
        }
        var replCounts: [Unicode.Scalar: Int] = [:]
        for scalar in replacement.unicodeScalars where shellSignificantScalars.contains(scalar) {
            replCounts[scalar, default: 0] += 1
        }
        for (scalar, count) in replCounts where count > origCounts[scalar, default: 0] {
            return true
        }
        return false
    }
}
