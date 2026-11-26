import Foundation

/// Lays out cleaned words for a style: plain text, and minimal HTML (no fonts or colours) for
/// email, notes and documents. Only words that were spoken are reshaped: a greeting or sign-off
/// is moved to its own line only when the speaker said one, and nothing is ever invented.
public enum StyleFormatter {
    public struct Output: Equatable, Sendable {
        public var plainText: String
        public var html: String?
        public var edits: [CleanupEdit]
    }

    /// Formats `text` (already cleaned) for `style`.
    /// `spokenCues` is the user's spoken-commands switch: without it, "heading", "bullet point" and
    /// "number one" stay words.
    public static func format(_ text: String, style: DictationStyle.ID, multiline: Bool = true, richText: Bool = true,
                              spokenCues: Bool = true) -> Output {
        let (plain, html, edits) = format(TranscriptTokenizer.tokenize(text), style: style, multiline: multiline, richText: richText,
                                          spokenCues: spokenCues)
        return Output(plainText: plain, html: html, edits: edits.sorted().map(\.edit))
    }

    static func format(_ tokens: [WordToken], style: DictationStyle.ID, multiline: Bool, richText: Bool,
                       spokenCues: Bool = true) -> (String, String?, [PositionedEdit]) {
        guard multiline else { return (TranscriptTokenizer.render(tokens, multiline: false), nil, []) }
        var layout = Layout(tokens)
        switch style {
        case .email: layout.layOutEmail()
        case .notes, .document: if spokenCues { layout.layOutStructured() } else { layout.blocks = layout.paragraphs(tokens[...]) }
        case .verbatim, .casual, .clean, .code: return (TranscriptTokenizer.render(tokens), nil, [])
        }
        let html = richText && style.producesHTML ? layout.html() : nil
        return (layout.plain(), html, layout.edits)
    }
}

struct Layout {
    enum Block: Equatable {
        /// Lines of words.
        case paragraph([[WordToken]])
        case heading([WordToken])
        case list(ordered: Bool, items: [[WordToken]])
    }

    typealias L = CleanupLexicon
    var t: [WordToken]
    var blocks: [Block] = []
    var edits: [PositionedEdit] = []
    private var sequence = 0

    init(_ tokens: [WordToken]) { t = tokens }

    mutating func record(_ removed: String, _ inserted: String, at position: Int) {
        sequence += 1
        edits.append(PositionedEdit(position: position, sequence: sequence, edit: CleanupEdit(kind: .formatting, removed: removed, inserted: inserted)))
    }

    func isSentenceStart(_ i: Int) -> Bool { i == 0 || t[i].breakBefore > 0 || t[i - 1].endsSentence || t[i - 1].trail.hasSuffix(":") }

    // MARK: Email

    static let greetings: Set<String> = ["hi", "hello", "hey", "hiya", "dear", "morning", "afternoon", "evening"]
    static let greetingNames: Set<String> = ["team", "all", "everyone", "everybody", "folks", "both", "there", "guys", "y'all"]
    static let signOffs: [[String]] = [
        ["kind", "regards"], ["best", "regards"], ["warm", "regards"], ["warmest", "regards"], ["many", "thanks"],
        ["thanks", "very", "much"], ["thank", "you", "very", "much"], ["thanks", "so", "much"], ["thanks", "a", "million"],
        ["thanks", "a", "lot"], ["thanks", "again"], ["thank", "you"], ["thanks"], ["cheers"], ["regards"],
        ["all", "the", "best"], ["best", "wishes"], ["best"], ["talk", "soon"], ["speak", "soon"], ["take", "care"],
        ["yours", "sincerely"], ["yours", "faithfully"], ["sincerely"], ["yours"], ["love"], ["see", "you", "soon"],
    ]
    /// Sign-offs that need a name after them to count ("Best, Aoife", never "Best." alone).
    static let signOffsNeedingName: Set<[String]> = [["best"], ["yours"], ["love"], ["regards"]]
    static let topicMarkers: [[String]] = [
        ["also"], ["separately"], ["secondly"], ["finally"], ["lastly"], ["additionally"], ["meanwhile"], ["regarding"],
        ["on", "another", "note"], ["one", "more", "thing"], ["another", "thing"], ["in", "other", "news"], ["by", "the", "way"],
        ["as", "for"], ["in", "the", "meantime"],
    ]

    mutating func layOutEmail() {
        guard !t.isEmpty else { return }
        let greetingEnd = findGreeting()
        let bodyStart = (greetingEnd ?? -1) + 1
        let signOff = findSignOff(after: bodyStart)
        if let g = greetingEnd {
            let before = t[g].text
            t[g].trail = "," + String(t[g].trail.filter { "\"”')".contains($0) })
            t[g + 1].breakBefore = 2
            t[g + 1].capitalise()
            record(before, t[g].text + "\n\n", at: t[g].origin)
        }
        if let (s, nameStart) = signOff {
            t[s].breakBefore = 2
            t[s].capitalise()
            let phraseEnd = (nameStart ?? t.count) - 1
            let beforePhrase = t[phraseEnd].text
            if let n = nameStart {
                t[phraseEnd].trail = ","
                t[n].breakBefore = 1
                t[t.count - 1].trail = Layout.stripFinalStop(t[t.count - 1].trail)
            } else {
                t[phraseEnd].trail = Layout.stripFinalStop(t[phraseEnd].trail)
            }
            record("", "\n\n", at: t[s].origin)
            record(beforePhrase, (nameStart == nil ? t[phraseEnd].text : t[phraseEnd].text + "\n"), at: t[s].origin)
        }
        splitTopicParagraphs(from: bodyStart, to: signOff?.0 ?? t.count)
        blocks = paragraphs(t[...])
    }

    /// The index of the greeting's last word: "Hi Aoife," "Dear Mr Byrne," "Hello team".
    private func findGreeting() -> Int? {
        guard t.count >= 3, !t[0].quoted else { return nil }
        var i = 0
        let first = t[0].lower
        guard Self.greetings.contains(first) || (first == "good" && ["morning", "afternoon", "evening"].contains(t[1].lower) && t[0].trail.isEmpty) else { return nil }
        if first == "good" { i = 1 }
        var names = 0
        while !t[i].hasPause, i + 1 < t.count, names < 4, t[i + 1].breakBefore == 0 {
            let next = t[i + 1]
            let isName = (next.isCapitalised && !L.notNames.contains(next.lower) && !next.lower.hasPrefix("i'") && next.lower != "i")
                || Self.greetingNames.contains(next.lower) || L.titles.contains(next.lower.trimmingCharacters(in: CharacterSet(charactersIn: ".")))
            guard isName else { break }
            i += 1
            names += 1
        }
        if t[i].trail.contains("?") { return nil }
        let bare = ["hi", "hello", "hey", "hiya"].contains(first)
        guard names > 0 || t[i].hasPause || bare else { return nil }
        if first == "dear", names == 0 { return nil }
        // Something has to follow.
        guard i + 1 < t.count else { return nil }
        return i
    }

    /// The final sentence when it is only a sign-off and an optional name: its first word, and
    /// the name's first word.
    private func findSignOff(after bodyStart: Int) -> (Int, Int?)? {
        var s = t.count - 1
        while s > 0 && !isSentenceStart(s) { s -= 1 }
        guard s > bodyStart, !t[s].quoted else { return nil }
        for phrase in Self.signOffs {
            let end = s + phrase.count
            guard end <= t.count, (0..<phrase.count).allSatisfy({ t[s + $0].lower == phrase[$0] }) else { continue }
            guard (s..<(end - 1)).allSatisfy({ t[$0].trail.isEmpty }) else { continue }
            let nameCount = t.count - end
            if nameCount == 0 {
                if Self.signOffsNeedingName.contains(phrase) { return nil }
                return (s, nil)
            }
            guard nameCount <= 3, (end..<t.count).allSatisfy({ t[$0].isCapitalised && !t[$0].quoted && !L.notNames.contains(t[$0].lower) }),
                  (end..<(t.count - 1)).allSatisfy({ t[$0].trail.isEmpty }) else { return nil }
            return (s, end)
        }
        return nil
    }

    /// Long bodies only: a new paragraph before "Also, …", "Separately, …" and the like.
    private mutating func splitTopicParagraphs(from start: Int, to end: Int) {
        guard start < end, !(start + 1..<end).contains(where: { t[$0].breakBefore > 0 }) else { return }
        let sentenceStarts = (start..<end).filter { $0 == start || isSentenceStart($0) }
        guard sentenceStarts.count >= 4 else { return }
        for s in sentenceStarts.dropFirst() {
            for marker in Self.topicMarkers where s + marker.count < end {
                if (0..<marker.count).allSatisfy({ t[s + $0].lower == marker[$0] }) {
                    t[s].breakBefore = 2
                    record("", "\n\n", at: t[s].origin)
                    break
                }
            }
        }
    }

    static func stripFinalStop(_ trail: String) -> String {
        var s = trail
        while let c = s.last, c == "." || c == "," { s.removeLast() }
        return s
    }

    // MARK: Notes and documents

    private enum Cue { case bullet, numbered(Int), ordinal(Int), heading }

    static let ordinals: [String: Int] = [
        "first": 1, "firstly": 1, "second": 2, "secondly": 2, "third": 3, "thirdly": 3, "fourth": 4, "fourthly": 4,
        "fifth": 5, "fifthly": 5, "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10,
    ]
    static let numberNames: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "1": 1, "2": 2, "3": 3, "4": 4, "5": 5, "6": 6, "7": 7, "8": 8, "9": 9, "10": 10,
    ]

    /// A spoken cue at `i` and how many words it takes.
    private func cue(at i: Int, listOpen: Bool) -> (Cue, Int)? {
        let tok = t[i]
        guard !tok.quoted else { return nil }
        let prevIsDeterminer = i > 0 && L.determiners.contains(t[i - 1].lower) && !t[i - 1].hasPause
        // "bullet point" (never "points": "use bullet points for the summary" is prose) at the
        // start of a sentence or after a pause, or anywhere once the dictation has another one.
        if tok.lower == "bullet", !prevIsDeterminer, i + 2 < t.count, t[i + 1].lower == "point", tok.trail.isEmpty,
           isSentenceStart(i) || t[i - 1].hasPause || listOpen || bulletCueCount >= 2 {
            return (.bullet, 2)
        }
        if ["next", "new"].contains(tok.lower), i + 1 < t.count, tok.trail.isEmpty, !prevIsDeterminer {
            let w = t[i + 1].lower
            if w == "bullet" { return (.bullet, i + 2 < t.count && t[i + 2].lower == "point" && t[i + 1].trail.isEmpty ? 3 : 2) }
            if listOpen, w == "item" || w == "point" { return (.bullet, 2) }
        }
        if tok.lower == "number", tok.trail.isEmpty, i + 1 < t.count, let n = Self.numberNames[t[i + 1].lower], !prevIsDeterminer,
           isSentenceStart(i) || t[i - 1].hasPause || listOpen {
            return (.numbered(n), 2)
        }
        if let n = Self.ordinals[tok.lower], isSentenceStart(i), i + 1 < t.count, tok.hasPause || tok.lower.hasSuffix("ly") {
            return (.ordinal(n), 1)
        }
        if (tok.lower == "finally" || tok.lower == "lastly"), isSentenceStart(i), tok.hasPause, i + 1 < t.count {
            return (.ordinal(0), 1)
        }
        if tok.lower == "heading", isSentenceStart(i), i + 1 < t.count {
            return (.heading, 1)
        }
        return nil
    }

    /// "bullet point" pairs in the whole dictation: two or more make a list wherever they sit.
    /// Counted once, when the structured layout starts.
    private var bulletCueCount = 0

    mutating func layOutStructured() {
        bulletCueCount = (0..<max(0, t.count - 1)).filter { t[$0].lower == "bullet" && t[$0 + 1].lower == "point" && !t[$0].quoted }.count
        // Numbered and ordinal lists count only as a sequence from one.
        let numbered = sequenceCues { if case .numbered(let n) = $0 { n } else { nil } }
        let ordinal = sequenceCues { if case .ordinal(let n) = $0 { n } else { nil } }
        var out: [Block] = []
        var paragraph: [WordToken] = []
        var list: (ordered: Bool, items: [[WordToken]])?
        var item: [WordToken] = []
        var i = 0

        func flushParagraph() {
            if !paragraph.isEmpty { out.append(contentsOf: paragraphs(paragraph[...])); paragraph = [] }
        }
        func flushItem() {
            if !item.isEmpty { list?.items.append(item); item = [] }
        }
        func flushList() {
            flushItem()
            guard var l = list, !l.items.isEmpty else { list = nil; return }
            // "…Number two, book the room. Let me know if that works.": the last item ends with its
            // first sentence, and what follows is a paragraph after the list.
            var after: [WordToken] = []
            if var last = l.items.popLast() {
                // A real sentence end: not "Dr." (see `endsSentence`), and a capital follows ("9 a.m. tomorrow" isn't one).
                if let end = last.indices.dropLast().first(where: { last[$0].endsSentence && last[$0 + 1].isCapitalised }) {
                    after = Array(last[(end + 1)...])
                    last = Array(last[...end])
                    if !after.isEmpty { after[0].breakBefore = 2 }
                }
                l.items.append(last)
            }
            out.append(.list(ordered: l.ordered, items: l.items))
            list = nil
            paragraph = after
        }

        while i < t.count {
            if t[i].breakBefore == 2, list != nil { flushList() }
            if let (kind, length) = cue(at: i, listOpen: list != nil) {
                var accepted = true
                var ordered = false
                switch kind {
                case .bullet: ordered = list?.ordered ?? false
                case .numbered: accepted = numbered.contains(i); ordered = true
                case .ordinal(let n): accepted = ordinal.contains(i) || (n == 0 && list?.ordered == true); ordered = true
                case .heading:
                    accepted = false
                    if let end = headingEnd(from: i + 1, cue: i) {
                        flushList()
                        flushParagraph()
                        let words = Array(t[(i + 1)...end])
                        out.append(.heading(Self.cleanItem(words)))
                        record(TranscriptTokenizer.render(t[i...i]), "", at: t[i].origin)
                        i = end + 1
                        if i < t.count { t[i].breakBefore = max(t[i].breakBefore, 2) }
                        continue
                    }
                }
                if accepted {
                    flushItem()
                    if list == nil || list!.ordered != ordered {
                        flushList()
                        flushParagraph()
                        list = (ordered, [])
                    }
                    record(TranscriptTokenizer.render(t[i..<(i + length)]), ordered ? "\(list!.items.count + 1). " : "- ", at: t[i].origin)
                    i += length
                    continue
                }
            }
            if list != nil {
                var tok = t[i]
                if item.isEmpty { tok.breakBefore = 0 }
                item.append(tok)
            } else {
                paragraph.append(t[i])
            }
            i += 1
        }
        flushList()
        flushParagraph()
        blocks = out.map { block in
            guard case .list(let ordered, let items) = block else { return block }
            return .list(ordered: ordered, items: items.map(Self.cleanItem).filter { !$0.isEmpty })
        }
    }

    /// Indices of numbered/ordinal cues that run 1, 2, 3… (at least two of them).
    private func sequenceCues(_ number: (Cue) -> Int?) -> Set<Int> {
        var found: [(Int, Int)] = []
        var i = 0
        while i < t.count {
            if let (kind, length) = cue(at: i, listOpen: !found.isEmpty), let n = number(kind) {
                let expected = (found.last?.1 ?? 0) + 1
                if n == expected || (n == 0 && !found.isEmpty) {
                    found.append((i, n == 0 ? expected : n))
                } else if n == 1 {
                    if found.count >= 2 { break }
                    found = [(i, 1)]
                }
                i += length
                continue
            }
            i += 1
        }
        return found.count >= 2 ? Set(found.map(\.0)) : []
    }

    /// "Heading: shopping list" or "Heading, shopping list" (or a heading followed by a line
    /// break or a list): the heading's last word, at most eight words in.
    private func headingEnd(from s: Int, cue: Int) -> Int? {
        guard s < t.count else { return nil }
        var e = s
        while e < t.count - 1, !t[e].hasPause, t[e + 1].breakBefore == 0, e - s < 8 { e += 1 }
        guard e - s < 8 else { return nil }
        let markedByCue = t[cue].trail.hasSuffix(":") || t[cue].trail.hasSuffix(",")
        let followedByBreak = e + 1 < t.count && (t[e + 1].breakBefore > 0 || self.cue(at: e + 1, listOpen: false) != nil)
        return markedByCue || followedByBreak ? e : nil
    }

    /// An item or heading without trailing commas, full stops and a dangling "and", capitalised.
    static func cleanItem(_ words: [WordToken]) -> [WordToken] {
        var w = words
        while let last = w.last, last.isPunctuationOnly { w.removeLast() }
        if w.count > 1, let last = w.last, ["and", "or", "then"].contains(last.lower), last.trail.isEmpty || last.hasPause { w.removeLast() }
        guard !w.isEmpty else { return w }
        let sentences = w.indices.dropLast().filter { w[$0].endsSentence && w[$0 + 1].isCapitalised }.count
        var last = w[w.count - 1]
        if last.isAmbiguousAbbreviation || CleanupLexicon.units.contains(last.lower) && last.lower.contains(".") {
            // "9 a.m." keeps its full stop.
        } else if sentences == 0 {
            while let c = last.trail.last, ".,;:".contains(c), !last.trail.hasSuffix("...") { last.trail.removeLast() }
        } else {
            while let c = last.trail.last, ",;:".contains(c) { last.trail.removeLast() }
        }
        w[w.count - 1] = last
        var first = w[0]
        while let c = first.lead.first, c == "," { first.lead.removeFirst() }
        first.capitalise()
        first.breakBefore = 0
        w[0] = first
        return w
    }

    // MARK: Paragraphs

    /// Words split into paragraphs at double breaks and lines at single ones.
    func paragraphs(_ words: ArraySlice<WordToken>) -> [Block] {
        var out: [Block] = []
        var lines: [[WordToken]] = []
        var line: [WordToken] = []
        for (n, tok) in words.enumerated() {
            if n > 0 && tok.breakBefore == 2 {
                lines.append(line)
                out.append(.paragraph(lines))
                lines = []
                line = []
            } else if n > 0 && tok.breakBefore == 1 {
                lines.append(line)
                line = []
            }
            line.append(tok)
        }
        if !line.isEmpty { lines.append(line) }
        if !lines.isEmpty { out.append(.paragraph(lines)) }
        return out
    }

    // MARK: Rendering

    static func words(_ w: [WordToken]) -> String { w.map(\.text).joined(separator: " ") }

    func plain() -> String {
        blocks.map { block -> String in
            switch block {
            case .paragraph(let lines): return lines.map(Self.words).joined(separator: "\n")
            case .heading(let words): return Self.words(words)
            case .list(let ordered, let items):
                return items.enumerated().map { n, item in (ordered ? "\(n + 1). " : "- ") + Self.words(item) }.joined(separator: "\n")
            }
        }.joined(separator: "\n\n")
    }

    /// Paragraphs as `<div>` lines with a blank `<div><br></div>` between them (how mail
    /// composers write paragraphs), headings as `<h2>`, lists as `<ul>`/`<ol>`.
    func html() -> String {
        var parts: [String] = []
        for (n, block) in blocks.enumerated() {
            switch block {
            case .paragraph(let lines):
                if n > 0, case .paragraph = blocks[n - 1] { parts.append("<div><br></div>") }
                parts.append(contentsOf: lines.map { "<div>\(Self.escape(Self.words($0)))</div>" })
            case .heading(let words):
                parts.append("<h2>\(Self.escape(Self.words(words)))</h2>")
            case .list(let ordered, let items):
                let tag = ordered ? "ol" : "ul"
                parts.append("<\(tag)>" + items.map { "<li>\(Self.escape(Self.words($0)))</li>" }.joined() + "</\(tag)>")
            }
        }
        return parts.joined()
    }

    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(c)
            }
        }
        return out
    }
}
