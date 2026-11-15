import Foundation

/// The user's corrections, applied to a transcript as `apply_transcript_post_processing` in
/// post_processing.rs applies them: in order, each enabled one whose `models` scope includes the
/// speech model that heard it (or that has no scope), whole-phrase and case-insensitive unless
/// the correction says otherwise.
public enum TranscriptCorrections {
    public static func apply(_ text: String, corrections: [TranscriptCorrection], speechModel: String) -> String {
        var result = text
        for correction in corrections where correction.enabled {
            // A scoped (learned) correction only fixes the speech models that made the
            // mishearing; another model may hear that phrase correctly.
            guard correction.models.isEmpty || correction.models.contains(speechModel) else { continue }
            result = replacePhrase(in: result, from: correction.from.trimmingCharacters(in: .whitespacesAndNewlines),
                                   to: correction.to.trimmingCharacters(in: .whitespacesAndNewlines),
                                   caseSensitive: correction.caseSensitive, wholePhrase: correction.wholePhrase)
        }
        return result
    }

    static func replacePhrase(in text: String, from: String, to: String, caseSensitive: Bool, wholePhrase: Bool) -> String {
        guard !text.isEmpty, !from.isEmpty else { return text }
        let options: String.CompareOptions = caseSensitive ? [.literal] : [.caseInsensitive]
        var output = ""
        var cursor = text.startIndex
        var searchFrom = text.startIndex
        while searchFrom < text.endIndex,
              let found = text.range(of: from, options: options, range: searchFrom..<text.endIndex) {
            if wholePhrase && !isPhraseBoundary(text, found) {
                searchFrom = text.index(after: found.lowerBound)
                continue
            }
            output += text[cursor..<found.lowerBound]
            output += to
            cursor = found.upperBound
            searchFrom = found.upperBound
        }
        guard cursor != text.startIndex else { return text }
        output += text[cursor...]
        return output
    }

    private static func isPhraseBoundary(_ text: String, _ range: Range<String.Index>) -> Bool {
        let before = range.lowerBound > text.startIndex ? text[text.index(before: range.lowerBound)] : nil
        let after = range.upperBound < text.endIndex ? text[range.upperBound] : nil
        return !(before.map(isWordCharacter) ?? false) && !(after.map(isWordCharacter) ?? false)
    }

    private static func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
}
