import Foundation

/// Ranking for the ⌘K palette: dictations by their words and app, commands and settings by
/// name and a few keywords. Every word typed has to be found somewhere in an entry; a whole
/// word beats the start of a word, which beats the middle of one. Matching ignores case and
/// accents ("aoife" finds "Aoife", "cafe" finds "café"). Ties keep the order given (for
/// dictations, newest first).
public enum PaletteSearch {
    /// One searchable entry: its title (counted in full) and other fields (counted at a
    /// discount, e.g. the app's name or keywords).
    public struct Fields: Sendable {
        public var title: String
        public var other: [String]
        public init(title: String, other: [String] = []) {
            self.title = title
            self.other = other
        }
    }

    static let wholeWord = 100
    static let wordStart = 70
    static let inside = 35
    /// Letters in order inside one word ("trnscr" → "Transcription"): commands only.
    static let scattered = 12

    /// The entry's score for `query`, or nil when some word of the query isn't in it. An empty
    /// query matches everything with 0.
    public static func score(_ query: String, _ fields: Fields, allowScattered: Bool = false) -> Int? {
        let tokens = tokenize(query)
        guard !tokens.isEmpty else { return 0 }
        let title = fold(fields.title)
        let others = fields.other.map(fold)
        var total = 0
        for token in tokens {
            let inTitle = match(token, in: title, allowScattered: allowScattered)
            let inOthers = others.compactMap { match(token, in: $0, allowScattered: allowScattered) }.max().map { $0 * 6 / 10 }
            guard let best = [inTitle, inOthers].compactMap({ $0 }).max() else { return nil }
            total += best
        }
        // The whole query as typed, in the title: a phrase beats the same words apart.
        if tokens.count > 1, title.contains(tokens.joined(separator: " ")) { total += 40 }
        return total
    }

    /// `items` that match, best first; equal scores keep their order. `limit` caps the result.
    public static func rank<T>(_ items: [T], query: String, limit: Int? = nil, allowScattered: Bool = false,
                               fields: (T) -> Fields) -> [T] {
        let scored = items.enumerated().compactMap { index, item -> (Int, Int, T)? in
            score(query, fields(item), allowScattered: allowScattered).map { ($0, index, item) }
        }
        let sorted = scored.sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }.map(\.2)
        return limit.map { Array(sorted.prefix($0)) } ?? sorted
    }

    /// Where the query's words are in `text` (first of each), to underline them.
    public static func matchRanges(_ query: String, in text: String) -> [Range<String.Index>] {
        tokenize(query).compactMap { token in
            text.range(of: token, options: [.caseInsensitive, .diacriticInsensitive])
        }
        .sorted { $0.lowerBound < $1.lowerBound }
    }

    static func tokenize(_ query: String) -> [String] {
        fold(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func match(_ token: String, in text: String, allowScattered: Bool) -> Int? {
        var best: Int?
        var searchStart = text.startIndex
        while let range = text.range(of: token, range: searchStart..<text.endIndex) {
            let startsWord = range.lowerBound == text.startIndex || !isWordCharacter(text[text.index(before: range.lowerBound)])
            let endsWord = range.upperBound == text.endIndex || !isWordCharacter(text[range.upperBound])
            let value = startsWord ? (endsWord ? wholeWord : wordStart) : inside
            best = max(best ?? 0, value)
            if value == wholeWord { break }
            searchStart = text.index(after: range.lowerBound)
        }
        if best == nil, allowScattered, token.count >= 3, isScattered(token, in: text) { best = scattered }
        return best
    }

    private static func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber }

    /// The token's letters in order within one word of `text`, starting at that word's start.
    private static func isScattered(_ token: String, in text: String) -> Bool {
        for word in text.split(whereSeparator: { !isWordCharacter($0) }) where word.first == token.first {
            var it = word.makeIterator()
            var found = true
            for c in token {
                var hit = false
                while let w = it.next() { if w == c { hit = true; break } }
                if !hit { found = false; break }
            }
            if found { return true }
        }
        return false
    }
}
