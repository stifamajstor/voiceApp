import Foundation

public enum CorrectionEditValidator {
    public static func apply(
        _ edits: [CorrectionEdit],
        to text: String,
        maxWordChangeRatio: Double = CloudCorrectionConfig.maxWordChangeRatio
    ) throws -> String {
        guard !edits.isEmpty else { return text }

        var matched: [(range: Range<String.Index>, edit: CorrectionEdit)] = []
        matched.reserveCapacity(edits.count)

        for edit in edits {
            guard !edit.original.isEmpty else {
                throw EditValidationError.emptyOriginal
            }
            let occurrences = findOccurrences(of: edit.original, in: text)
            guard !occurrences.isEmpty else {
                throw EditValidationError.originalNotFound(edit.original)
            }
            guard occurrences.count == 1, let range = occurrences.first else {
                throw EditValidationError.ambiguousMatch(edit.original)
            }
            matched.append((range: range, edit: edit))
        }

        matched.sort { $0.range.lowerBound < $1.range.lowerBound }

        for index in 1..<matched.count {
            if matched[index - 1].range.upperBound > matched[index].range.lowerBound {
                throw EditValidationError.overlappingEdits
            }
        }

        let totalWords = wordTokens(in: text).count
        let maxAllowed = totalWords == 0 ? 0 : max(1, Int(Double(totalWords) * maxWordChangeRatio))
        var changedWords = 0
        for (_, edit) in matched {
            changedWords += changedWordCount(from: edit.original, to: edit.replacement)
        }
        if changedWords > maxAllowed {
            throw EditValidationError.excessiveChanges(
                changedWords: changedWords,
                totalWords: totalWords,
                maxAllowed: maxAllowed
            )
        }

        var result = ""
        result.reserveCapacity(text.count)
        var cursor = text.startIndex
        for (range, edit) in matched {
            result.append(contentsOf: text[cursor..<range.lowerBound])
            result.append(edit.replacement)
            cursor = range.upperBound
        }
        result.append(contentsOf: text[cursor..<text.endIndex])

        if result.count > max(text.count * 2 + 128, 256) {
            throw EditValidationError.excessiveChanges(
                changedWords: max(changedWords, 1),
                totalWords: totalWords,
                maxAllowed: maxAllowed
            )
        }

        return result
    }

    static func changedWordCount(from original: String, to replacement: String) -> Int {
        var orig = wordTokens(in: original)
        var repl = wordTokens(in: replacement)

        while let a = orig.first, let b = repl.first, a == b {
            orig.removeFirst()
            repl.removeFirst()
        }
        while let a = orig.last, let b = repl.last, a == b {
            orig.removeLast()
            repl.removeLast()
        }
        return max(orig.count, repl.count)
    }

    static func wordTokens(in text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for scalar in text.unicodeScalars {
            let isWordChar = scalar.properties.isAlphabetic
                || scalar.properties.generalCategory == .decimalNumber
                || scalar.properties.generalCategory == .letterNumber
                || scalar.properties.generalCategory == .otherNumber
            if isWordChar {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private static func findOccurrences(of substring: String, in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(of: substring, options: [.literal], range: searchStart..<text.endIndex) {
            ranges.append(range)
            searchStart = range.upperBound
        }
        return ranges
    }
}
