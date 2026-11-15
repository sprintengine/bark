import Foundation

/// What the transcriber actually heard, word by word, against the passage that was read: a
/// word-level sequence alignment (Levenshtein with a fixed backtrace), so every passage word is a
/// hit, a miss or a substitution and every heard word a hit, an insertion or a substitution.
/// Capitalisation and punctuation never count against a match. The same comparison as the
/// desktop app's `transcriptCompare.ts`.
public struct TranscriptComparison: Equatable, Sendable {
    public enum TokenState: String, Sendable {
        case hit, miss, inserted, substituted
    }

    public struct Token: Equatable, Sendable {
        /// As it appeared, for display (capitals and punctuation kept).
        public var raw: String
        /// Lowercased, letters and digits only: what is matched.
        public var normalized: String
        public var state: TokenState
        /// The aligned token's index on the other side, or nil when unmatched.
        public var counterpart: Int?
    }

    /// Passage words in order: hit, miss or substituted.
    public var target: [Token]
    /// Heard words in order: hit, inserted or substituted.
    public var heard: [Token]
    public var hits: Int
    /// Passage words with no heard counterpart.
    public var deletions: Int
    /// Passage words heard as a different word.
    public var substitutions: Int
    /// Heard words with no passage counterpart.
    public var insertions: Int

    /// Passage words that didn't come through (dropped or heard differently).
    public var misses: Int { deletions + substitutions }
    /// The passage's word count: the denominator of `accuracy`.
    public var total: Int { target.count }
    /// Rounded percent of passage words heard correctly.
    public var accuracy: Int {
        if total == 0 { return heard.isEmpty ? 100 : 0 }
        return Int((Double(hits) / Double(total) * 100).rounded())
    }

    /// Lowercased with everything but letters and digits removed.
    public static func normalize(_ raw: String) -> String {
        String(raw.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// Splits on whitespace, dropping tokens that are only punctuation.
    static func tokenize(_ text: String) -> [(raw: String, normalized: String)] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
            .map { ($0, normalize($0)) }
            .filter { !$0.1.isEmpty }
    }

    /// Compares `transcript` (what came back) against `passage` (what was read).
    public init(transcript: String, passage: String) {
        let t = Self.tokenize(passage)
        let r = Self.tokenize(transcript)
        let n = t.count, m = r.count

        // d[i][j]: the cost of turning passage[0..<i] into transcript[0..<j].
        var d = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { d[i][0] = i }
        for j in 0...m { d[0][j] = j }
        if n > 0 && m > 0 {
            for i in 1...n {
                for j in 1...m {
                    let sub = t[i - 1].normalized == r[j - 1].normalized ? 0 : 1
                    d[i][j] = min(d[i - 1][j - 1] + sub, d[i - 1][j] + 1, d[i][j - 1] + 1)
                }
            }
        }

        var target = t.map { Token(raw: $0.raw, normalized: $0.normalized, state: .miss, counterpart: nil) }
        var heard = r.map { Token(raw: $0.raw, normalized: $0.normalized, state: .inserted, counterpart: nil) }
        var hits = 0, substitutions = 0, deletions = 0, insertions = 0

        // Backtrace with a fixed precedence (diagonal, deletion, insertion), so repeated words
        // always align the same way.
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0 && j > 0 {
                let same = t[i - 1].normalized == r[j - 1].normalized
                if d[i][j] == d[i - 1][j - 1] + (same ? 0 : 1) {
                    target[i - 1].state = same ? .hit : .substituted
                    target[i - 1].counterpart = j - 1
                    heard[j - 1].state = same ? .hit : .substituted
                    heard[j - 1].counterpart = i - 1
                    if same { hits += 1 } else { substitutions += 1 }
                    i -= 1
                    j -= 1
                    continue
                }
            }
            if i > 0 && d[i][j] == d[i - 1][j] + 1 {
                target[i - 1].state = .miss
                deletions += 1
                i -= 1
                continue
            }
            heard[j - 1].state = .inserted
            insertions += 1
            j -= 1
        }

        self.target = target
        self.heard = heard
        self.hits = hits
        self.deletions = deletions
        self.substitutions = substitutions
        self.insertions = insertions
    }
}
