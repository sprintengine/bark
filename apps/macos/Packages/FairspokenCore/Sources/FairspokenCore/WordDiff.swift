import Foundation

/// A word-level diff between what was said and what was pasted, for the dictation view: runs of
/// kept, added and removed words. Words match when they agree ignoring case and punctuation, and
/// a kept run shows the pasted spelling. Long texts beyond `maxCells` are shown as one rewrite.
public struct WordDiff: Equatable, Sendable {
    public enum Kind: Sendable { case same, added, removed }

    public struct Run: Equatable, Sendable {
        public var kind: Kind
        public var words: [String]
        public var text: String { words.joined(separator: " ") }
    }

    public var runs: [Run]
    /// For each word of the original, whether the result dropped it.
    public var removedInOriginal: [Bool]
    public var originalWords: [String]

    /// Above this many comparisons (words × words) the texts count as a rewrite.
    public static let maxCells = 250_000

    public var addedCount: Int { runs.filter { $0.kind == .added }.reduce(0) { $0 + $1.words.count } }
    public var removedCount: Int { runs.filter { $0.kind == .removed }.reduce(0) { $0 + $1.words.count } }
    /// Places where the text changed: a removal next to an addition counts once.
    public var changeCount: Int {
        var n = 0
        var inChange = false
        for run in runs {
            if run.kind == .same { inChange = false } else if !inChange { n += 1; inChange = true }
        }
        return n
    }
    public var isUnchanged: Bool { runs.allSatisfy { $0.kind == .same } }

    public init(from original: String, to result: String) {
        let a = Self.words(original), b = Self.words(result)
        originalWords = a
        let na = a.map(Self.normalize), nb = b.map(Self.normalize)
        var ops: [(Kind, String)] = []
        var dropped = Array(repeating: true, count: a.count)
        if a.count * b.count > Self.maxCells {
            ops = a.map { (.removed, $0) } + b.map { (.added, $0) }
        } else {
            // Longest common subsequence, filled from the end so the walk runs forwards.
            var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
            if !a.isEmpty && !b.isEmpty {
                for i in stride(from: a.count - 1, through: 0, by: -1) {
                    for j in stride(from: b.count - 1, through: 0, by: -1) {
                        table[i][j] = na[i] == nb[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
                    }
                }
            }
            var i = 0, j = 0
            while i < a.count || j < b.count {
                if i < a.count, j < b.count, na[i] == nb[j] {
                    ops.append((.same, b[j])); dropped[i] = false; i += 1; j += 1
                } else if j < b.count, i == a.count || table[i][j + 1] >= table[i + 1][j] {
                    ops.append((.added, b[j])); j += 1
                } else {
                    ops.append((.removed, a[i])); i += 1
                }
            }
        }
        removedInOriginal = dropped
        // Within a change, removals first, then additions: "~~um so can~~ Could".
        var runs: [Run] = []
        var pendingRemoved: [String] = [], pendingAdded: [String] = []
        func flush() {
            if !pendingRemoved.isEmpty { runs.append(Run(kind: .removed, words: pendingRemoved)) }
            if !pendingAdded.isEmpty { runs.append(Run(kind: .added, words: pendingAdded)) }
            pendingRemoved = []; pendingAdded = []
        }
        for (kind, word) in ops {
            switch kind {
            case .removed: pendingRemoved.append(word)
            case .added: pendingAdded.append(word)
            case .same:
                flush()
                if let last = runs.last, last.kind == .same { runs[runs.count - 1].words.append(word) } else {
                    runs.append(Run(kind: .same, words: [word]))
                }
            }
        }
        flush()
        self.runs = runs
    }

    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    static func normalize(_ word: String) -> String {
        String(word.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }
}
