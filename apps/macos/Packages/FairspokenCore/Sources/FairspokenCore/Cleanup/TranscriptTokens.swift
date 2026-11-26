import Foundation

/// A word of a transcript with the punctuation stuck to it: `lead` + `core` + `trail`
/// ("(“Hello," is lead "(“", core "Hello", trail ","). Cleanup works on these, never on raw
/// character offsets, so removing a word can carry its punctuation to the right neighbour.
struct WordToken: Equatable, Sendable {
    var lead: String
    var core: String { didSet { lower = Self.lowered(core) } }
    var trail: String
    /// Index of the word in the text the tokens were first made from: edits sort by it.
    var origin: Int
    /// Line breaks before this word: 0 none, 1 a new line, 2 a new paragraph.
    var breakBefore: Int = 0
    /// Inside quotation marks or "quote … unquote": never changed.
    var quoted = false
    /// `core` lowercased, with straight apostrophes (kept in step with `core`).
    private(set) var lower: String

    init(lead: String, core: String, trail: String, origin: Int, breakBefore: Int = 0, quoted: Bool = false) {
        self.lead = lead
        self.core = core
        self.trail = trail
        self.origin = origin
        self.breakBefore = breakBefore
        self.quoted = quoted
        lower = Self.lowered(core)
    }

    static func lowered(_ s: String) -> String {
        let l = s.lowercased()
        return l.contains("’") ? l.replacingOccurrences(of: "’", with: "'") : l
    }
    var text: String { lead + core + trail }
    /// A token that is only punctuation ("—", "…").
    var isPunctuationOnly: Bool { core.isEmpty }

    /// The trail ends a sentence ("." "?" "!" "…"), ignoring closing quotes and brackets.
    var endsSentence: Bool {
        guard let last = lastMark else { return false }
        return last == "." || last == "?" || last == "!" || last == "…"
    }

    /// The trail is a pause: any punctuation that isn't a closing quote or bracket.
    var hasPause: Bool { lastMark != nil }

    var endsWithComma: Bool { lastMark == "," || lastMark == ";" }

    /// A cut-off marker after the word: "…", "...", "-", "—", "–".
    var endsWithCutOff: Bool {
        guard let last = lastMark else { return false }
        return last == "…" || last == "-" || last == "—" || last == "–" || (last == "." && trail.hasSuffix("..."))
    }

    /// The last character of the trail that isn't a closing quote or bracket.
    private var lastMark: Character? {
        guard !trail.isEmpty else { return nil }
        return trail.last { !Self.closerCharacters.contains($0) }
    }

    static let closerCharacters: Set<Character> = ["\"", "”", "’", "'", ")", "]", "}", "»"]

    var isCapitalised: Bool { core.first?.isUppercase == true }
    var isAllCaps: Bool { core.count > 1 && core == core.uppercased() && core.contains(where: \.isLetter) }

    mutating func capitalise() {
        guard let first = core.first, first.isLowercase else { return }
        core = first.uppercased() + core.dropFirst()
    }

    mutating func lowercaseFirst() {
        guard let first = core.first, first.isUppercase else { return }
        core = first.lowercased() + core.dropFirst()
    }

    static let closers = CharacterSet(charactersIn: "\"”’')]}»")
    static let leadingPunctuation: Set<Character> = ["\"", "“", "‘", "(", "[", "{", "«", "'"]
    static let trailingPunctuation: Set<Character> = [".", ",", ";", ":", "!", "?", "\"", "”", "’", ")", "]", "}", "»", "…", "-", "—", "–", "'"]
}

enum TranscriptTokenizer {
    /// Splits on whitespace; newlines become `breakBefore` on the next word. Punctuation that
    /// stands alone (" ," or " .") joins the word before it.
    static func tokenize(_ text: String) -> [WordToken] {
        var tokens: [WordToken] = []
        var pendingBreak = 0
        var index = 0
        var chunk = ""

        func flush() {
            guard !chunk.isEmpty else { return }
            defer { chunk = "" }
            var lead = ""
            var core = Substring(chunk)
            while let c = core.first, WordToken.leadingPunctuation.contains(c), core.count > 1 || c != "'" {
                lead.append(c)
                core = core.dropFirst()
            }
            var trail = ""
            while let c = core.last, WordToken.trailingPunctuation.contains(c) {
                // "rock'n'roll" keeps its apostrophes; a closing ' after a word is punctuation.
                trail.insert(c, at: trail.startIndex)
                core = core.dropLast()
            }
            let isPunctuation = core.isEmpty
            if isPunctuation, pendingBreak == 0, var last = tokens.popLast(), Self.joinsPrevious(lead + trail) {
                last.trail += lead + trail
                tokens.append(last)
                return
            }
            tokens.append(WordToken(lead: lead, core: String(core), trail: trail, origin: index, breakBefore: pendingBreak))
            index += 1
            pendingBreak = 0
        }

        var newlines = 0
        for c in text {
            if c.isNewline {
                flush()
                newlines += 1
            } else if c.isWhitespace {
                flush()
            } else {
                if newlines > 0 {
                    if !tokens.isEmpty { pendingBreak = min(2, newlines) }
                    newlines = 0
                }
                chunk.append(c)
            }
        }
        flush()
        markQuotes(&tokens)
        return tokens
    }

    /// Plain sentence punctuation typed with a space before it ("word ,"), which belongs on the word.
    private static func joinsPrevious(_ punctuation: String) -> Bool {
        !punctuation.isEmpty && punctuation.allSatisfy { ",.;:!?".contains($0) }
    }

    /// Marks words inside double quotes, and between spoken "quote" and "unquote"/"end quote".
    static func markQuotes(_ tokens: inout [WordToken]) {
        var open = false
        var spoken = false
        for i in tokens.indices {
            let opens = tokens[i].lead.contains { $0 == "\"" || $0 == "“" }
            if opens { open = true }
            let lower = tokens[i].lower
            if !open, lower == "quote", i + 1 < tokens.count, tokens[i].trail.isEmpty || tokens[i].endsWithComma { spoken = true }
            if open || spoken { tokens[i].quoted = true }
            if spoken, lower == "unquote" || (lower == "quote" && i > 0 && tokens[i - 1].lower == "end") { spoken = false }
            let closes = tokens[i].trail.contains { $0 == "\"" || $0 == "”" }
            if closes, open { open = false }
        }
    }

    /// Joins words with single spaces; breaks become "\n" (or "\n\n"), or a space when
    /// `multiline` is false.
    static func render(_ tokens: [WordToken], multiline: Bool = true) -> String {
        var out = ""
        for (i, t) in tokens.enumerated() {
            if i > 0 {
                if t.breakBefore > 0 && multiline {
                    out += String(repeating: "\n", count: t.breakBefore)
                } else {
                    out += " "
                }
            }
            out += t.text
        }
        return out
    }

    static func render(_ tokens: ArraySlice<WordToken>) -> String {
        tokens.map(\.text).joined(separator: " ")
    }
}
