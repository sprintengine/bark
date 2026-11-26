import Foundation

/// Simple, deterministic edit commands for the composer under a dictation ("correct this
/// dictation"): "change X to Y", "replace X with Y", "delete X", "add Y at the end" (and "at
/// the start"). Nil when the command isn't one of these, or X isn't in the text exactly once
/// ("delete it" in a text with three "it"s is ambiguous): the composer then treats what was
/// typed as a note instead.
public enum NoteEditCommand {
    public struct Result: Equatable, Sendable {
        public var text: String
        public var edits: [CleanupEdit]
    }

    /// First words that start a command.
    public static let verbs: Set<String> = ["change", "replace", "swap", "correct", "delete", "remove", "cut", "add", "append", "put"]

    /// What a composer typed is a command rather than an edited copy of `text`: it starts with a
    /// command verb that `text` itself doesn't start with, and it applies.
    public static func command(_ typed: String, for text: String) -> Result? {
        func firstWord(_ s: String) -> String? {
            s.split(whereSeparator: \.isWhitespace).first.map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        }
        guard let verb = firstWord(typed), verbs.contains(verb), firstWord(text) != verb else { return nil }
        return apply(typed, to: text)
    }

    public static func apply(_ command: String, to text: String) -> Result? {
        var c = command.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = c.last, ".!".contains(last) { c.removeLast() }
        let lower = c.lowercased()
        for (verb, joiner) in [("change ", " to "), ("replace ", " with "), ("swap ", " for "), ("correct ", " to ")] where lower.hasPrefix(verb) {
            return substitute(String(c.dropFirst(verb.count)), joiner: joiner, in: text)
        }
        for verb in ["delete ", "remove ", "cut "] where lower.hasPrefix(verb) {
            let target = unquote(String(c.dropFirst(verb.count)))
            guard !target.isEmpty, let result = replace(target, with: "", in: text) else { return nil }
            return result
        }
        for verb in ["add ", "append ", "put "] where lower.hasPrefix(verb) {
            let rest = String(c.dropFirst(verb.count))
            let restLower = rest.lowercased()
            for suffix in [" at the end", " to the end", " on the end", " at the bottom"] where restLower.hasSuffix(suffix) {
                return append(unquote(String(rest.dropLast(suffix.count))), to: text, atStart: false)
            }
            for suffix in [" at the start", " at the beginning", " to the start", " at the top"] where restLower.hasSuffix(suffix) {
                return append(unquote(String(rest.dropLast(suffix.count))), to: text, atStart: true)
            }
            if verb == "append " { return append(unquote(rest), to: text, atStart: false) }
        }
        return nil
    }

    /// "change go to the shop to go to the cafe": the split whose left side is in the text, the
    /// longest such left side first.
    private static func substitute(_ rest: String, joiner: String, in text: String) -> Result? {
        let lower = rest.lowercased()
        var searchEnd = lower.endIndex
        while let range = lower.range(of: joiner, options: .backwards, range: lower.startIndex..<searchEnd) {
            let from = unquote(String(rest[rest.startIndex..<range.lowerBound]))
            let to = unquote(String(rest[range.upperBound...]))
            if !from.isEmpty, !to.isEmpty, let result = replace(from, with: to, in: text) { return result }
            searchEnd = range.lowerBound
        }
        return nil
    }

    /// The one whole-phrase, case-insensitive occurrence of `from` replaced (or removed), with a
    /// capital kept where the old words had one, and spacing and punctuation tidied after removal.
    static func replace(_ from: String, with to: String, in text: String) -> Result? {
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: from) + "(?![\\p{L}\\p{N}])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard matches.count == 1 else { return nil }
        var out = ""
        var cursor = 0
        var edits: [CleanupEdit] = []
        for m in matches {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let old = ns.substring(with: m.range)
            var new = to
            if let f = old.first, f.isUppercase, let g = new.first, g.isLowercase { new = g.uppercased() + new.dropFirst() }
            out += new
            edits.append(CleanupEdit(kind: .selfCorrection, removed: old, inserted: new))
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        if to.isEmpty { out = tidyAfterRemoval(out, removedAtStart: matches[0].range.location == 0) }
        return Result(text: out, edits: edits)
    }

    private static func append(_ addition: String, to text: String, atStart: Bool) -> Result? {
        let add = addition.trimmingCharacters(in: .whitespaces)
        guard !add.isEmpty else { return nil }
        let base = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if atStart {
            var first = add
            if let f = first.first, f.isLowercase { first = f.uppercased() + first.dropFirst() }
            return Result(text: base.isEmpty ? first : first + " " + base, edits: [CleanupEdit(kind: .selfCorrection, removed: "", inserted: first)])
        }
        var next = add
        let endsSentence = base.last.map { ".?!".contains($0) } ?? true
        if endsSentence, let f = next.first, f.isLowercase { next = f.uppercased() + next.dropFirst() }
        return Result(text: base.isEmpty ? next : base + " " + next, edits: [CleanupEdit(kind: .selfCorrection, removed: "", inserted: next)])
    }

    private static func unquote(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'“”‘’")))
    }

    /// Collapses the double spaces and stranded punctuation a removal leaves, and gives the text
    /// its capital back when the removed words began it. Casing elsewhere is left as it was.
    static func tidyAfterRemoval(_ text: String, removedAtStart: Bool) -> String {
        var tokens = TranscriptTokenizer.tokenize(text)
        for i in tokens.indices where tokens[i].trail.count > 1 { tokens[i].trail = CleanupWork.tidyTrail(tokens[i].trail) }
        if removedAtStart, let first = tokens.indices.first { tokens[first].capitalise() }
        return TranscriptTokenizer.render(tokens)
    }
}
