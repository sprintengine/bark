import Foundation

/// The pure half of the edit watcher (`src-tauri/src/edit_diff.rs`): find a dictation again in
/// its field's current text, diff it word by word against what was inserted, and pick out the
/// edits that look like the user fixing a misheard word. The Accessibility reads live in the app
/// (`EditWatcher`); everything here is platform-neutral so it can be unit-tested.
///
/// Offsets are `Character`s except where noted: Accessibility reports UTF-16 code units, which
/// are converted once in `InsertionAnchor.init(field:selectionStart:selectionLength:inserted:)`.
public enum EditDiff {
    /// Text kept on each side of an insertion to find it again later. It lives only in memory
    /// until the watch is evaluated, and is never persisted.
    public static let contextCharacters = 80
    /// The shortest anchor tried when the user also edited the text next to the dictation;
    /// shorter anchors match too many places.
    static let minAnchorCharacters = 8
    /// A fix replaces at most this many words with at most this many words.
    static let maxFixWords = 3
    /// Word diffs are quadratic; larger regions are treated as rewrites.
    static let maxDiffWords = 2000
}

/// Where a dictation landed: the text around it and what was inserted.
public struct InsertionAnchor: Equatable, Sendable {
    /// Up to `EditDiff.contextCharacters` immediately before the insertion.
    public var before: String
    public var inserted: String
    /// Up to `EditDiff.contextCharacters` immediately after the insertion.
    public var after: String
    /// Character offset of the insertion's start when it was made.
    public var start: Int

    public init(before: String, inserted: String, after: String, start: Int) {
        self.before = before
        self.inserted = inserted
        self.after = after
        self.start = start
    }

    /// Builds the anchor from the field's text and selection, read just before `inserted`
    /// replaced the selection. The selection is in UTF-16 code units, as `AXSelectedTextRange`
    /// reports it.
    public init(field value: String, selectionStart: Int, selectionLength: Int, inserted: String) {
        let utf16 = Array(value.utf16)
        let start = min(max(selectionStart, 0), utf16.count)
        let end = min(start + max(selectionLength, 0), utf16.count)
        let before = String(decoding: utf16[..<start], as: UTF16.self)
        let after = String(decoding: utf16[end...], as: UTF16.self)
        let beforeCount = before.count
        self.before = String(before.suffix(EditDiff.contextCharacters))
        self.inserted = inserted
        self.after = String(after.prefix(EditDiff.contextCharacters))
        self.start = beforeCount
    }

    /// The dictated region in the field's current text: whatever now sits between the text that
    /// surrounded the insertion. Offsets shift when the user types elsewhere, so the context is
    /// searched for, nearest the old position first, and trimmed down when the user edited it
    /// too. Nil when the context is gone or the region is implausibly large.
    public func locate(in current: String) -> String? {
        let text = Array(current)
        let insertedCount = inserted.count

        let before = Array(self.before)
        let start: Int
        if before.isEmpty {
            start = 0
        } else {
            guard let found = EditDiff.anchorLengths(before.count).lazy.compactMap({ length -> Int? in
                let needle = Array(before[(before.count - length)...])
                let expected = max(self.start - length, 0)
                return EditDiff.nearestOccurrence(in: text, of: needle, from: 0, expected: expected).map { $0 + length }
            }).first else { return nil }
            start = found
        }

        let after = Array(self.after)
        let end: Int
        if after.isEmpty {
            end = text.count
        } else {
            guard let found = EditDiff.anchorLengths(after.count).lazy.compactMap({ length -> Int? in
                EditDiff.nearestOccurrence(in: text, of: Array(after[..<length]), from: start, expected: start + insertedCount)
            }).first else { return nil }
            end = found
        }

        let region = String(text[start..<end])
        let trimmed = EditDiff.trimAdjacentTyping(inserted: inserted, region: region,
                                                  openStart: before.isEmpty, openEnd: after.isEmpty)
        return trimmed.count <= insertedCount * 3 + 200 ? trimmed : nil
    }
}

/// A short substitution the user made that sounds like what was dictated.
public struct Mishearing: Equatable, Sendable {
    public var heard: String
    public var intended: String
    public init(heard: String, intended: String) {
        self.heard = heard
        self.intended = intended
    }
}

public enum EditOutcome: Equatable, Sendable {
    /// The words are as dictated (punctuation and spacing may differ).
    case unchanged
    /// Some words changed. `fixes` holds the changes that look like a misheard word being
    /// corrected; other edits are ignored.
    case edited(fixes: [Mishearing])
    /// Too much changed to read word fixes out of it.
    case rewrite
}

extension EditDiff {
    /// Diffs the dictation against its edited region word by word and classifies each change.
    /// Only a 1–3-word substitution that sounds like the original is a fix; insertions,
    /// deletions and unrelated replacements are not, and a region where most words changed is a
    /// rewrite.
    public static func classify(inserted: String, edited: String) -> EditOutcome {
        let old = words(inserted)
        let new = words(edited)
        if old.count > maxDiffWords || new.count > maxDiffWords { return .rewrite }
        let hunks = diffWords(old, new)
        if hunks.isEmpty { return .unchanged }
        let removed = hunks.reduce(0) { $0 + $1.removed.count }
        if old.isEmpty || (old.count > maxFixWords && removed * 2 > old.count) { return .rewrite }
        let fixes = hunks
            .filter { (1...maxFixWords).contains($0.removed.count) && (1...maxFixWords).contains($0.added.count) }
            .map { Mishearing(heard: $0.removed.joined(separator: " "), intended: $0.added.joined(separator: " ")) }
            .filter { $0.heard != $0.intended && misheardAs($0.heard, $0.intended) }
        return .edited(fixes: fixes)
    }

    /// Whether `intended` could be what the speaker said when the model wrote `heard` ("cloud"
    /// for "Claude", "rocket deck" for "RocketDeck"). Spacing, case and punctuation are ignored,
    /// and the user's fix gets one letter more leeway than a mishearing would
    /// (`misheard_as` in transcript_cleanup.rs), because a person confirmed it.
    public static func misheardAs(_ heard: String, _ intended: String) -> Bool {
        let heard = Array(normalizeTerm(heard))
        let intendedKey = normalizeTerm(intended)
        let intended = Array(intendedKey)
        guard !heard.isEmpty, !intended.isEmpty else { return false }
        return levenshtein(heard, intended, within: mishearingBudget(intendedKey) + 1)
    }

    /// Whether `phrase`'s words appear, in order, among `text`'s words (case-insensitive).
    public static func containsWords(_ text: String, _ phrase: String) -> Bool {
        func split(_ value: String) -> [String] {
            value.split(whereSeparator: { !isAlphanumeric($0) }).map { $0.lowercased() }
        }
        let text = split(text)
        let phrase = split(phrase)
        guard !phrase.isEmpty, phrase.count <= text.count else { return false }
        return (0...(text.count - phrase.count)).contains { Array(text[$0..<($0 + phrase.count)]) == phrase }
    }

    // MARK: Words

    static func isAlphanumeric(_ c: Character) -> Bool { c.isLetter || c.isNumber }

    static func normalizeTerm(_ term: String) -> String {
        String(term.filter(isAlphanumeric)).lowercased()
    }

    /// Short terms must be spoken exactly; longer ones may be misheard by about one letter in five.
    static func mishearingBudget(_ term: String) -> Int {
        let count = term.count
        return count <= 4 ? 0 : max(count / 5, 1)
    }

    static func levenshtein(_ a: [Character], _ b: [Character], within budget: Int) -> Bool {
        if abs(a.count - b.count) > budget { return false }
        var previous = Array(0...b.count)
        for (i, ca) in a.enumerated() {
            var current = [i + 1]
            current.reserveCapacity(b.count + 1)
            for (j, cb) in b.enumerated() {
                let cost = ca == cb ? 0 : 1
                current.append(min(previous[j + 1] + 1, current[j] + 1, previous[j] + cost))
            }
            previous = current
        }
        return previous[b.count] <= budget
    }

    /// Words with surrounding punctuation removed, so "Dublin," and "Dublin." compare equal; case
    /// is kept because capitalising a name is a fix.
    static func words(_ text: String) -> [String] {
        wordTokens(Array(text)).map(\.word)
    }

    /// `words`, each with the character offset of the whitespace-delimited token it came from.
    static func wordTokens(_ text: [Character]) -> [(offset: Int, word: String)] {
        var tokens: [(offset: Int, word: String)] = []
        var tokenStart: Int?
        for index in 0...text.count {
            let isSpace = index == text.count || text[index].isWhitespace
            switch (isSpace, tokenStart) {
            case (false, nil):
                tokenStart = index
            case (true, let start?):
                var slice = text[start..<index]
                while let first = slice.first, !isAlphanumeric(first) { slice = slice.dropFirst() }
                while let last = slice.last, !isAlphanumeric(last) { slice = slice.dropLast() }
                if !slice.isEmpty { tokens.append((start, String(slice))) }
                tokenStart = nil
            default:
                break
            }
        }
        return tokens
    }

    // MARK: Locating

    /// Drops text the user typed next to the dictation rather than into it: a run of new words
    /// before the first dictated word, or after the last one. That run is only cut off at a line
    /// break (a new paragraph above or below) or where the region is open-ended because the
    /// dictation started or ended the field; otherwise it may be the user's edit and is kept.
    static func trimAdjacentTyping(inserted: String, region: String, openStart: Bool, openEnd: Bool) -> String {
        let old = words(inserted)
        let chars = Array(region)
        let tokens = wordTokens(chars)
        if old.count > maxDiffWords || tokens.count > maxDiffWords { return region }
        let new = tokens.map(\.word)
        let hunks = diffWords(old, new)
        func endsLine(_ cut: Int) -> Bool {
            var end = cut
            while end > 0, chars[end - 1] == " " || chars[end - 1] == "\t" { end -= 1 }
            return end > 0 && chars[end - 1].isNewline
        }

        var start = 0
        if let first = hunks.first, first.removed.isEmpty, first.newStart == 0, first.newEnd < new.count {
            let cut = tokens[first.newEnd].offset
            if openStart || endsLine(cut) { start = cut }
        }
        var end = chars.count
        if let last = hunks.last, last.removed.isEmpty, last.newEnd == new.count, last.newStart > 0 {
            let cut = tokens[last.newStart].offset
            if cut > start && (openEnd || endsLine(cut)) { end = cut }
        }
        return String(chars[start..<end])
    }

    /// Anchor lengths to try, longest first: the whole context, then shorter pieces next to the
    /// insertion.
    static func anchorLengths(_ available: Int) -> [Int] {
        var lengths = [available]
        for length in [40, 20, minAnchorCharacters] where length < available { lengths.append(length) }
        return lengths
    }

    /// The occurrence of `needle` at or after `from` that starts closest to `expected`.
    static func nearestOccurrence(in text: [Character], of needle: [Character], from: Int, expected: Int) -> Int? {
        guard !needle.isEmpty, needle.count <= text.count, from <= text.count - needle.count else { return nil }
        var best: Int?
        for index in from...(text.count - needle.count) where text[index] == needle[0] {
            guard text[index..<(index + needle.count)].elementsEqual(needle) else { continue }
            if best.map({ abs(index - expected) < abs($0 - expected) }) ?? true { best = index }
        }
        return best
    }

    // MARK: Diff

    struct Hunk {
        var removed: [String] = []
        var added: [String] = []
        /// The added words' index range in the new word list.
        var newStart = 0
        var newEnd = 0
    }

    /// The runs of words that differ between `old` and `new`, from a longest common subsequence
    /// alignment.
    static func diffWords(_ old: [String], _ new: [String]) -> [Hunk] {
        let n = old.count, m = new.count
        // lcs[i][j] = LCS length of old[i...] and new[j...].
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    lcs[i][j] = old[i] == new[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }

        var hunks: [Hunk] = []
        var current = Hunk()
        var i = 0, j = 0
        while i < n || j < m {
            if i < n && j < m && old[i] == new[j] {
                if !current.removed.isEmpty || !current.added.isEmpty {
                    hunks.append(current)
                    current = Hunk()
                }
                i += 1
                j += 1
                current.newStart = j
                current.newEnd = j
            } else if j < m && (i == n || lcs[i][j + 1] >= lcs[i + 1][j]) {
                current.added.append(new[j])
                j += 1
                current.newEnd = j
            } else {
                current.removed.append(old[i])
                i += 1
            }
        }
        if !current.removed.isEmpty || !current.added.isEmpty { hunks.append(current) }
        return hunks
    }
}
