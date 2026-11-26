import Foundation
import NaturalLanguage

/// Deterministic, precision-first cleanup of a dictation: fillers, stutters and repeats,
/// restarts, cue corrections ("Tuesday, no wait, Wednesday"), spoken commands and a punctuation
/// tidy. Every rule needs clear evidence before it fires; anything ambiguous is left exactly as
/// it was heard, because a wrongly deleted word is worse than a missed fix.
///
/// No models and no network. NaturalLanguage's word tagger is consulted only on the rare paths
/// that need a word class (a noun-phrase repair, a capital after a stray full stop).
public enum TranscriptCleanup {
    public struct Output: Equatable, Sendable {
        public var text: String
        public var edits: [CleanupEdit]
    }

    /// Cleans `text` with `options`. Line breaks the speaker asked for are kept as "\n".
    public static func clean(_ text: String, options: CleanupOptions = .full) -> Output {
        let (tokens, edits) = run(TranscriptTokenizer.tokenize(text), options: options)
        return Output(text: TranscriptTokenizer.render(tokens), edits: edits.sorted().map(\.edit))
    }

    static func run(_ tokens: [WordToken], options: CleanupOptions) -> ([WordToken], [PositionedEdit]) {
        var work = CleanupWork(tokens)
        guard !options.isEmpty, !tokens.isEmpty else { return (tokens, []) }
        if options.fillers { work.removeHardFillers() }
        if options.spokenCommands { work.applySpokenCommands() }
        if options.repeats || options.restarts { work.removeRepeats(words: options.repeats, phrases: options.restarts) }
        if options.corrections { work.applyCueCorrections() }
        if options.restarts { work.removePartialRestarts() }
        if options.fillers { work.removeSoftFillers() }
        if options.punctuationTidy { work.tidyPunctuation() }
        if options.sentenceCase { work.applySentenceCase() }
        if options.dropFinalFullStopWhenShort { work.dropFinalFullStopIfShort() }
        return (work.t, work.edits)
    }
}

/// An edit with where it happened in the original words, for sorting into transcript order.
struct PositionedEdit: Comparable, Sendable {
    var position: Int
    var sequence: Int
    var edit: CleanupEdit
    static func < (a: PositionedEdit, b: PositionedEdit) -> Bool {
        (a.position, a.sequence) < (b.position, b.sequence)
    }
}

struct CleanupWork {
    typealias L = CleanupLexicon
    var t: [WordToken]
    var edits: [PositionedEdit] = []
    private var sequence = 0
    private let tags = TagCache()

    init(_ tokens: [WordToken]) { t = tokens }

    // MARK: Recording edits

    mutating func record(_ kind: CleanupEdit.Kind, removed: String, inserted: String, at position: Int) {
        sequence += 1
        edits.append(PositionedEdit(position: position, sequence: sequence, edit: CleanupEdit(kind: kind, removed: removed, inserted: inserted)))
    }

    // MARK: Positions

    func isSentenceStart(_ i: Int) -> Bool {
        i == 0 || t[i].breakBefore > 0 || t[i - 1].endsSentence
    }

    /// The first word of the sentence word `i` is in.
    func sentenceStart(of i: Int) -> Int {
        var s = i
        while s > 0 && !isSentenceStart(s) { s -= 1 }
        return s
    }

    /// Nothing more in this clause after word `i`: a pause, a break or the end.
    func boundaryAfter(_ i: Int) -> Bool {
        i == t.count - 1 || t[i].hasPause || t[i + 1].breakBefore > 0 || t[i + 1].isPunctuationOnly
    }

    func words(_ r: Range<Int>) -> [String] { t[r].map(\.lower) }

    func anyQuoted(_ r: Range<Int>) -> Bool { t[r].contains { $0.quoted } }

    static func isIForm(_ lower: String) -> Bool { lower == "i" || lower.hasPrefix("i'") }

    // MARK: Removing words

    /// Removes words `r`, carrying a full stop that ended the span onto the word before, keeping
    /// line breaks, and fixing the capital of the word after. `fillerCommas` drops a comma that
    /// only set the removed words off ("I think, um, we" → "I think we").
    mutating func remove(_ r: Range<Int>, kind: CleanupEdit.Kind, fillerCommas: Bool = false, record shouldRecord: Bool = true) {
        guard !r.isEmpty, r.lowerBound >= 0, r.upperBound <= t.count else { return }
        let first = t[r.lowerBound]
        let last = t[r.upperBound - 1]
        let removedText = TranscriptTokenizer.render(t[r])
        let wasSentenceStart = isSentenceStart(r.lowerBound)
        let p = r.lowerBound - 1
        let n = r.upperBound
        if p >= 0 {
            if last.endsSentence && !t[p].endsSentence {
                t[p].trail = Self.strippingPause(t[p].trail) + Self.terminal(of: last.trail)
            } else if fillerCommas, t[p].endsWithComma, last.endsWithComma, n < t.count, !keepsCommaBefore(n), !commaIsStructural(after: p) {
                t[p].trail = Self.strippingPause(t[p].trail)
            }
        }
        if n < t.count {
            t[n].breakBefore = max(t[n].breakBefore, first.breakBefore)
            let startsNow = p < 0 || t[p].endsSentence || t[n].breakBefore > 0
            if startsNow {
                if wasSentenceStart && first.isCapitalised && !t[n].quoted { t[n].capitalise() }
            } else if t[n].isCapitalised, !t[n].isAllCaps, !t[n].quoted, L.functionWords.contains(t[n].lower), !Self.isIForm(t[n].lower) {
                t[n].lowercaseFirst()
            }
        }
        t.removeSubrange(r)
        tags.invalidate()
        if shouldRecord { record(kind, removed: removedText, inserted: "", at: first.origin) }
    }

    /// A conjunction that starts a new clause keeps the comma before it ("the shop, and bought").
    /// "so" only when a subject follows it ("so we"), not as an adverb ("so tired").
    func keepsCommaBefore(_ n: Int) -> Bool {
        let w = t[n].lower
        if ["and", "but", "or", "because", "then", "which", "although", "though"].contains(w) { return true }
        guard w == "so", n + 1 < t.count else { return false }
        if L.subjectPronouns.contains(t[n + 1].lower) || L.determiners.contains(t[n + 1].lower) { return true }
        if ["much", "many", "very", "really", "far", "long", "good", "bad"].contains(t[n + 1].lower) { return false }
        tags.fill(t)
        let next = tags.lexical[n + 1]
        return next != .adjective && next != .adverb
    }

    /// A comma the sentence needs whatever was removed after it: after a name ("Hi Aoife,"),
    /// after the sentence's first word ("Yes,", "Thanks,"), or closing a subordinate clause
    /// ("If you can,").
    func commaIsStructural(after p: Int) -> Bool {
        if t[p].isCapitalised && !isSentenceStart(p) && !Self.isIForm(t[p].lower) { return true }
        if isSentenceStart(p) { return Self.interjections.contains(t[p].lower) }
        let start = sentenceStart(of: p)
        var i = p - 1
        while i >= start, !t[i].hasPause { i -= 1 }
        return L.subordinators.contains(t[i + 1].lower)
    }

    static let interjections: Set<String> = [
        "yes", "yeah", "yep", "no", "nope", "thanks", "ok", "okay", "well", "right", "sure", "hi", "hello", "hey",
        "sorry", "look", "listen", "honestly", "anyway", "grand", "great", "cheers", "morning", "afternoon",
    ]

    /// The trail without a trailing comma, semicolon, colon or dash.
    static func strippingPause(_ trail: String) -> String {
        var s = trail
        while let c = s.last, ",;:-—–".contains(c) { s.removeLast() }
        return s
    }

    /// The sentence-ending punctuation at the end of a trail ("." "?" "!" "…").
    static func terminal(of trail: String) -> String {
        let core = trail.trimmingCharacters(in: WordToken.closers)
        if core.hasSuffix("...") { return "..." }
        guard let c = core.last, ".?!…".contains(c) else { return "." }
        return String(c)
    }

    // MARK: 1. Filled pauses

    mutating func removeHardFillers() {
        var i = 0
        while i < t.count {
            let tok = t[i]
            if !tok.quoted, !tok.isAllCaps, tok.lead.isEmpty, L.hardFillers.contains(tok.lower) {
                remove(i..<(i + 1), kind: .filler, fillerCommas: true)
                continue
            }
            i += 1
        }
    }

    // MARK: 2. Spoken commands

    private enum Command { case punctuation(String), lineBreak(Int) }

    private static let commands: [([String], Command)] = [
        (["new", "paragraph"], .lineBreak(2)), (["next", "paragraph"], .lineBreak(2)),
        (["new", "line"], .lineBreak(1)), (["newline"], .lineBreak(1)),
        (["full", "stop"], .punctuation(".")), (["period"], .punctuation(".")),
        (["comma"], .punctuation(",")), (["question", "mark"], .punctuation("?")),
        (["exclamation", "mark"], .punctuation("!")), (["exclamation", "point"], .punctuation("!")),
        (["semicolon"], .punctuation(";")),
    ]

    /// Words before a command word that make it an ordinary noun ("the Oxford comma", "a
    /// trial period", "a new line of products").
    private static let commandNounModifiers: Set<String> = [
        "oxford", "serial", "big", "huge", "giant", "real", "trial", "grace", "notice", "waiting", "time",
        "cooling-off", "cooling", "probation", "probationary", "holding", "billing", "reporting", "rest",
        "test", "sample", "summer", "school", "free", "menstrual", "heavy", "light", "initial", "long",
        "short", "same", "whole", "entire", "honeymoon", "transition", "transitional", "follow-up", "review",
        "recovery", "incubation", "lock-in", "lockout", "sales", "tax", "accounting", "financial", "fiscal",
        "fourth", "first", "second", "third", "last", "next", "final", "extra", "missing", "stray", "every",
        "one", "single", "inverted", "brand",
    ]
    private static let commandNounFollowers: Set<String> = [
        "of", "for", "separated", "delimited", "splice", "splices", "sign", "over", "about", "is", "was",
        "has", "had", "there", "here", "key", "button", "character", "after", "between", "in",
    ]

    mutating func applySpokenCommands() {
        var i = 1
        while i < t.count {
            guard let (length, command) = matchCommand(at: i) else { i += 1; continue }
            let end = i + length
            let removedText = TranscriptTokenizer.render(t[i..<end])
            let position = t[i].origin
            let breakBefore = t[i].breakBefore
            switch command {
            case .punctuation(let mark):
                let p = i - 1
                let isTerminal = mark != "," && mark != ";"
                if !(isTerminal && t[p].endsSentence) {
                    var trail = Self.strippingPause(t[p].trail)
                    if trail.hasSuffix(".") && !trail.hasSuffix("...") { trail.removeLast() }
                    t[p].trail = trail + mark
                }
                t.removeSubrange(i..<end)
                if i < t.count {
                    t[i].breakBefore = max(t[i].breakBefore, breakBefore)
                    if isTerminal {
                        if !t[i].quoted { t[i].capitalise() }
                    } else if t[i].isCapitalised, !t[i].isAllCaps, L.functionWords.contains(t[i].lower), !Self.isIForm(t[i].lower) {
                        t[i].lowercaseFirst()
                    }
                }
                record(.spokenCommand, removed: removedText, inserted: mark, at: position)
            case .lineBreak(let count):
                t.removeSubrange(i..<end)
                if i < t.count {
                    t[i].breakBefore = max(t[i].breakBefore, count)
                    if !t[i].quoted { t[i].capitalise() }
                }
                record(.spokenCommand, removed: removedText, inserted: String(repeating: "\n", count: count), at: position)
            }
            tags.invalidate()
        }
    }

    private func matchCommand(at i: Int) -> (Int, Command)? {
        for (words, command) in Self.commands {
            let end = i + words.count
            guard end <= t.count else { continue }
            guard (0..<words.count).allSatisfy({ t[i + $0].lower == words[$0] && !t[i + $0].quoted && t[i + $0].lead.isEmpty }) else { continue }
            // Inner words carry no punctuation ("new, line" is not a command).
            guard (i..<(end - 1)).allSatisfy({ t[$0].trail.isEmpty }) else { continue }
            let prev = t[i - 1]
            if prev.isPunctuationOnly { continue }
            if L.determiners.contains(prev.lower) || Self.commandNounModifiers.contains(prev.lower) { continue }
            if L.prepositions.contains(prev.lower) && !prev.hasPause { continue }
            if end < t.count, t[end - 1].trail.isEmpty, Self.commandNounFollowers.contains(t[end].lower) { continue }
            if words == ["period"] {
                // "period" is a full stop only at the end, or before a new sentence.
                let atEnd = end == t.count
                let beforeSentence = !atEnd && (t[end - 1].endsSentence || t[end].isCapitalised || matchesAnyCommand(at: end)
                    || Self.sentenceOpeners.contains(t[end].lower))
                guard atEnd || beforeSentence else { continue }
            }
            return (words.count, command)
        }
        return nil
    }

    /// Lowercase words that plainly begin a new sentence after a spoken "period".
    private static let sentenceOpeners: Set<String> = CleanupLexicon.subjectPronouns.union([
        "the", "this", "my", "our", "your", "see", "thanks", "thank", "please", "can", "could", "would", "will",
        "also", "talk", "speak", "call", "ring", "send", "take", "let", "let's", "hope", "looking", "best",
    ])

    private func matchesAnyCommand(at i: Int) -> Bool {
        Self.commands.contains { words, _ in
            i + words.count <= t.count && (0..<words.count).allSatisfy { t[i + $0].lower == words[$0] }
        }
    }

    // MARK: 3. Stutters and repeats

    mutating func removeRepeats(words: Bool, phrases: Bool) {
        if words {
            collapseHyphenStutters()
            removeCutOffFragments()
            removeWordRuns()
        }
        removePhraseRepeats(short: words, long: phrases)
    }

    /// "I-I-I think" → "I think" (function words only: "bye-bye" and "so-so" are words).
    private mutating func collapseHyphenStutters() {
        for i in t.indices where !t[i].quoted && t[i].core.contains("-") {
            let parts = t[i].core.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2, let first = parts.first, !first.isEmpty,
                  parts.allSatisfy({ $0.lowercased() == first.lowercased() }),
                  L.stutterWords.contains(first.lowercased()) else { continue }
            let before = t[i].text
            t[i].core = parts.last!
            if first.first?.isUppercase == true { t[i].capitalise() }
            record(.repetition, removed: before, inserted: t[i].text, at: t[i].origin)
        }
    }

    /// "th- the" → "the": a cut-off start of the next word.
    private mutating func removeCutOffFragments() {
        var i = 0
        while i + 1 < t.count {
            let tok = t[i]
            let next = t[i + 1]
            if !tok.quoted, tok.trail == "-", tok.lead.isEmpty, (1...4).contains(tok.core.count), tok.core.allSatisfy(\.isLetter),
               next.core.count > tok.core.count, next.lower.hasPrefix(tok.lower) {
                remove(i..<(i + 1), kind: .repetition)
                continue
            }
            i += 1
        }
    }

    /// "the the", "I, I", "to to to": runs of one function word.
    private mutating func removeWordRuns() {
        var i = 0
        while i + 1 < t.count {
            let word = t[i].lower
            guard !t[i].quoted, !t[i].isPunctuationOnly, L.stutterWords.contains(word) || canCollapseDouble(at: i) else { i += 1; continue }
            var j = i
            while j + 1 < t.count, t[j + 1].lower == word, !t[j + 1].quoted, t[j].trail.isEmpty || t[j].trail == "," || t[j].endsWithCutOff,
                  t[j + 1].breakBefore == 0 {
                j += 1
            }
            if j > i {
                remove(i..<j, kind: .repetition)
                continue
            }
            i += 1
        }
    }

    /// Words that can be doubled grammatically ("what it is is", "carry on on Monday", "she had
    /// had enough") are a stutter only where that reading is impossible.
    private func canCollapseDouble(at i: Int) -> Bool {
        let word = t[i].lower
        let prev = i > 0 && !isSentenceStart(i) ? t[i - 1].lower : nil
        switch word {
        case "is", "was":
            guard let prev else { return true }
            return !["it", "what", "that", "this", "thing", "problem", "point", "issue", "question", "truth", "fact", "all", "which", "who"].contains(prev)
        case "on", "in":
            // After a verb the first one is a particle ("log in in the morning").
            guard let prev else { return true }
            return L.auxiliaries.contains(prev) || L.subjectPronouns.contains(prev) || L.determiners.contains(prev)
        case "had", "that", "you", "her", "do", "did":
            return prev == nil
        default:
            return false
        }
    }

    /// An adjacent exact repeat of 2–12 words, followed by more of the sentence. Two words are
    /// a repetition ("I think I think we"); three or more a restart (the abandoned clause).
    private mutating func removePhraseRepeats(short: Bool, long: Bool) {
        guard short || long else { return }
        var i = 0
        while i + 3 < t.count {
            var matched = 0
            let maxN = min(12, (t.count - i) / 2)
            if maxN >= 2 {
                for n in stride(from: maxN, through: 2, by: -1) {
                    if (n == 2 && !short) || (n > 2 && !long) { continue }
                    if isPhraseRepeat(at: i, length: n) { matched = n; break }
                }
            }
            if matched > 0 {
                remove(i..<(i + matched), kind: matched == 2 ? .repetition : .restart)
                continue
            }
            i += 1
        }
    }

    private func isPhraseRepeat(at i: Int, length n: Int) -> Bool {
        let a = i, b = i + n
        guard b + n < t.count else { return false } // something must follow the second copy
        for k in 0..<n {
            let x = t[a + k], y = t[b + k]
            guard x.lower == y.lower, !x.quoted, !y.quoted, !x.isPunctuationOnly, !y.isPunctuationOnly else { return false }
            if k < n - 1 && (!x.trail.isEmpty || !y.trail.isEmpty) { return false }
            if k > 0 && (x.breakBefore > 0 || y.breakBefore > 0) { return false }
        }
        let firstEnd = t[b - 1]
        if firstEnd.endsSentence && n < 3 { return false }
        if firstEnd.trail.contains("?") || firstEnd.trail.contains("!") { return false }
        let secondEnd = t[b + n - 1]
        if secondEnd.endsSentence { return false }
        let follower = t[b + n]
        if follower.isPunctuationOnly || follower.breakBefore > 0 { return false }
        let phrase = words(a..<b).joined(separator: " ")
        if L.emphaticPhrases.contains(phrase) { return false }
        // "New York, New York": a repeated name is a name.
        if t[b..<(b + n)].allSatisfy({ $0.isCapitalised && !Self.isIForm($0.lower) }) { return false }
        // Digit runs and phone numbers.
        if t[a..<b].allSatisfy({ Self.isNumber($0) }) { return false }
        // "Fine thanks, fine thanks": two content words repeated across a pause are emphasis.
        if n == 2 && firstEnd.hasPause && !L.functionWords.contains(t[b - 1].lower) { return false }
        // "If you can, you can come": the first copy closes a subordinate clause.
        if a > 0 && L.subordinators.contains(t[a - 1].lower) && firstEnd.hasPause { return false }
        return true
    }

    // MARK: 4. Cue corrections

    private enum RepairClass: Equatable { case day, month, number, name, nounPhrase }

    private struct Repair {
        var start: Int          // first word, including prefixes such as "on"
        var coreStart: Int      // first word of the typed phrase
        var end: Int            // last word (inclusive)
        var cls: RepairClass
        var unit: Int?          // index of a trailing unit word
        var prefixes: [String]
    }

    private static let cues: [[String]] = [
        ["sorry", "i", "mean"], ["no", "i", "mean"], ["let", "me", "rephrase", "that"], ["let", "me", "rephrase"],
        ["no", "wait"], ["wait", "no"], ["no", "sorry"], ["sorry", "no"], ["no", "actually"], ["actually", "no"],
        ["or", "rather"], ["i", "mean"], ["scratch", "that"], ["make", "that"], ["sorry"], ["actually"],
        ["correction"], ["wait"],
    ]
    /// Cues that, with no typed repair after them, take back the clause or sentence before.
    private static let clauseCues: Set<[String]> = [["scratch", "that"], ["let", "me", "rephrase"], ["let", "me", "rephrase", "that"]]

    mutating func applyCueCorrections() {
        var c = 0
        while c < t.count {
            guard let cue = matchCue(at: c) else { c += 1; continue }
            let cueEnd = c + cue.count       // first word after the cue
            if c > 0, let (repair, reparandum) = firstCorrection(cueStart: c, cueEnd: cueEnd) {
                applyCorrection(reparandum: reparandum, cueEnd: cueEnd, repair: repair)
                c = max(0, reparandum.lowerBound)
                continue
            }
            if Self.clauseCues.contains(cue), takeBackClause(cueStart: c, cueEnd: cueEnd) {
                c = 0
                continue
            }
            c += 1
        }
    }

    private func firstCorrection(cueStart c: Int, cueEnd: Int) -> (Repair, Range<Int>)? {
        for repair in parseRepairs(from: cueEnd) {
            if let reparandum = parseReparandum(endingAt: c - 1, like: repair) { return (repair, reparandum) }
        }
        return nil
    }

    private func matchCue(at c: Int) -> [String]? {
        for cue in Self.cues {
            let end = c + cue.count
            guard end <= t.count else { continue }
            guard (0..<cue.count).allSatisfy({ t[c + $0].lower == cue[$0] && !t[c + $0].quoted }) else { continue }
            // Inside a cue only a comma may sit between words ("no, wait").
            guard (c..<(end - 1)).allSatisfy({ t[$0].trail.isEmpty || t[$0].trail == "," }) else { continue }
            return cue
        }
        return nil
    }

    /// Every reading of the words after a cue as a typed repair that stands alone.
    private func parseRepairs(from s: Int) -> [Repair] {
        var j = s
        var prefixes: [String] = []
        while j < t.count, t[j].isPunctuationOnly { j += 1 }
        let start = j
        while j < t.count, prefixes.count < 2, L.repairPrefixes.contains(t[j].lower), t[j].trail.isEmpty, !t[j].quoted {
            prefixes.append(t[j].lower)
            j += 1
        }
        guard j < t.count, !t[j].quoted else { return [] }
        var candidates: [Repair] = []
        let word = t[j]
        if L.weekdays.contains(word.lower) || L.relativeDays.contains(word.lower) {
            candidates.append(Repair(start: start, coreStart: j, end: j, cls: .day, unit: nil, prefixes: prefixes))
        } else if L.months.contains(word.lower) && word.isCapitalised {
            candidates.append(Repair(start: start, coreStart: j, end: j, cls: .month, unit: nil, prefixes: prefixes))
        } else if Self.isNumber(word) {
            var e = j
            while e + 1 < t.count, t[e].trail.isEmpty, Self.isNumber(t[e + 1]), !t[e + 1].quoted { e += 1 }
            if e + 1 < t.count, t[e].trail.isEmpty, isCountedWord(e + 1) {
                candidates.append(Repair(start: start, coreStart: j, end: e + 1, cls: .number, unit: e + 1, prefixes: prefixes))
            }
            candidates.append(Repair(start: start, coreStart: j, end: e, cls: .number, unit: nil, prefixes: prefixes))
        } else if L.determiners.contains(word.lower), word.lower != "no", word.trail.isEmpty, prefixes.isEmpty || prefixes.allSatisfy({ L.prepositions.contains($0) }) {
            for length in 1...3 {
                let e = j + length
                guard e < t.count, (j..<e).allSatisfy({ t[$0].trail.isEmpty && !t[$0].quoted }) else { break }
                candidates.append(Repair(start: start, coreStart: j, end: e, cls: .nounPhrase, unit: nil, prefixes: prefixes))
            }
        } else if isNameWord(j) {
            var e = j
            while e + 1 < t.count, e - j < 2, t[e].trail.isEmpty, isNameWord(e + 1), !L.weekdays.contains(t[e + 1].lower) { e += 1 }
            candidates.append(Repair(start: start, coreStart: j, end: e, cls: .name, unit: nil, prefixes: prefixes))
        }
        return candidates.filter { repairEndsCleanly($0) && (($0.cls != .nounPhrase) || isNounPhrase(($0.coreStart + 1)...$0.end)) }
    }

    /// A repair stands alone: it ends the clause, or only a linking word follows it.
    private func repairEndsCleanly(_ r: Repair) -> Bool {
        if boundaryAfter(r.end) { return true }
        return L.followsRepair.contains(t[r.end + 1].lower)
    }

    private func parseReparandum(endingAt e: Int, like repair: Repair) -> Range<Int>? {
        guard e >= 0, !t[e].quoted, !t[e].isPunctuationOnly else { return nil }
        // A question answered ("Is it Tuesday? No, Wednesday") is not a correction.
        if t[e].trail.contains("?") || t[e].trail.contains("!") { return nil }
        var start: Int
        switch repair.cls {
        case .day:
            guard L.weekdays.contains(t[e].lower) || L.relativeDays.contains(t[e].lower) else { return nil }
            start = e
        case .month:
            guard L.months.contains(t[e].lower), t[e].isCapitalised else { return nil }
            start = e
        case .number:
            var s = e
            var ourUnit: Int?
            if !Self.isNumber(t[e]), e > 0, isCountedWord(e), Self.isNumber(t[e - 1]), t[e - 1].trail.isEmpty { s = e - 1; ourUnit = e }
            guard Self.isNumber(t[s]) else { return nil }
            // "20 chairs, no wait, 30 chairs" or "6 places, actually 8"; never "2 kids, sorry, 3 dogs".
            if let theirs = repair.unit {
                guard let ours = ourUnit, Self.sameUnit(t[ours], t[theirs]) else { return nil }
            }
            while s > 0, t[s - 1].trail.isEmpty, Self.isNumber(t[s - 1]), !t[s - 1].quoted { s -= 1 }
            start = s
        case .name:
            guard isNameWord(e) else { return nil }
            var s = e
            while s > 0, e - s < 2, t[s - 1].trail.isEmpty, isNameWord(s - 1), !t[s - 1].quoted { s -= 1 }
            // A capital that only starts the sentence proves nothing.
            if isSentenceStart(s) && !isTaggedName(s) { return nil }
            start = s
        case .nounPhrase:
            var found: Int?
            for length in 1...3 {
                let d = e - length
                guard d >= 0, (d..<e).allSatisfy({ t[$0].trail.isEmpty && !t[$0].quoted }) else { break }
                if L.determiners.contains(t[d].lower), t[d].lower != "no", isNounPhrase((d + 1)...e) { found = d; break }
            }
            guard let d = found else { return nil }
            let repairWords = repair.end - repair.coreStart
            let ourWords = e - d
            guard abs(repairWords - ourWords) <= 1 else { return nil }
            start = d
        }
        // "on Tuesday, sorry, on Wednesday": the wrong preposition goes too.
        for prefix in repair.prefixes.reversed() {
            guard start > 0, t[start - 1].lower == prefix, t[start - 1].trail.isEmpty, !t[start - 1].quoted else { break }
            start -= 1
        }
        return start..<(e + 1)
    }

    private mutating func applyCorrection(reparandum: Range<Int>, cueEnd: Int, repair: Repair) {
        let removeRange = reparandum.lowerBound..<repair.start
        // A repair without the reparandum's unit keeps it: "50 euros, sorry, 60" → "60 euros".
        let lastOfReparandum = reparandum.upperBound - 1
        let reparandumUnit = repair.cls == .number && !Self.isNumber(t[lastOfReparandum]) ? t[lastOfReparandum] : nil
        if let unit = reparandumUnit, repair.unit == nil {
            let removedText = TranscriptTokenizer.render(t[reparandum.lowerBound...repair.end])
            let position = t[reparandum.lowerBound].origin
            var unitToken = unit
            unitToken.trail = t[repair.end].trail
            unitToken.breakBefore = 0
            t[repair.end].trail = ""
            t.insert(unitToken, at: repair.end + 1)
            let newEnd = repair.end + 1 - removeRange.count
            remove(removeRange, kind: .selfCorrection, record: false)
            let insertedText = TranscriptTokenizer.render(t[(newEnd - (repair.end - repair.start))...newEnd])
            record(.selfCorrection, removed: removedText, inserted: insertedText, at: position)
        } else {
            remove(removeRange, kind: .selfCorrection)
        }
    }

    /// "Scratch that" / "let me rephrase": takes back the clause before it, or the previous
    /// sentence when the cue starts a sentence. Only when the cue is set off on both sides.
    private mutating func takeBackClause(cueStart c: Int, cueEnd: Int) -> Bool {
        guard c > 0 else { return false }
        let setOffBefore = isSentenceStart(c) || t[c - 1].hasPause
        let setOffAfter = cueEnd == t.count || t[cueEnd - 1].hasPause || t[cueEnd].breakBefore > 0
        guard setOffBefore, setOffAfter else { return false }
        let from = isSentenceStart(c) ? sentenceStart(of: c - 1) : sentenceStart(of: c)
        guard from < c, !anyQuoted(from..<cueEnd) else { return false }
        remove(from..<cueEnd, kind: .selfCorrection)
        return true
    }

    // MARK: 5. Partial restarts

    /// "where you could… where you can": a fragment that ends on an unfinished word (or a
    /// cut-off mark), restarted with the same two or more opening words.
    mutating func removePartialRestarts() {
        var k = 0
        while k + 2 < t.count {
            guard let (p, c) = partialRestart(at: k) else { k += 1; continue }
            remove(p..<c, kind: .restart)
            k = p
        }
    }

    private func partialRestart(at k: Int) -> (Int, Int)? {
        let tok = t[k]
        guard !tok.quoted, !tok.isPunctuationOnly, !tok.endsSentence else { return nil }
        var c = k + 1
        var cutOff = tok.endsWithCutOff
        while c < t.count, t[c].isPunctuationOnly { cutOff = cutOff || t[c].lead.contains("…") || t[c].trail.contains("…") || t[c].trail.contains("—") || t[c].trail.contains("-"); c += 1 }
        guard tok.endsWithComma || cutOff, c + 2 < t.count, t[c].breakBefore == 0 else { return nil }
        guard cutOff || L.incompleteEnd.contains(tok.lower) else { return nil }
        let floor = max(sentenceStart(of: k), k - 12)
        var p = k - 1
        while p >= floor {
            if t[p].lower == t[c].lower, p + 1 <= k, t[p + 1].lower == t[c + 1].lower {
                var m = 0
                while p + m <= k, c + m < t.count, t[p + m].lower == t[c + m].lower { m += 1 }
                let tail = k - (p + m) + 1
                if m >= 2, (1...3).contains(tail), c + m < t.count,
                   (p..<k).allSatisfy({ t[$0].trail.isEmpty }), !anyQuoted(p..<(c + m)),
                   !(p > 0 && L.subordinators.contains(t[p - 1].lower)) {
                    return (p, c)
                }
            }
            p -= 1
        }
        return nil
    }

    // MARK: 6. Fillers that are also words

    mutating func removeSoftFillers() {
        var i = 0
        while i < t.count {
            if let length = softFiller(at: i) {
                remove(i..<(i + length), kind: .filler, fillerCommas: true)
                continue
            }
            i += 1
        }
    }

    private static let likeFollowers: Set<String> = [
        "so", "really", "very", "totally", "completely", "just", "literally", "actually", "super", "i", "i'm",
        "i've", "i'd", "i'll", "you", "we", "he", "she", "they", "it", "it's", "that's", "there's", "honestly",
        "basically", "seriously", "absolutely", "not", "never", "always", "what",
    ]

    private func softFiller(at i: Int) -> Int? {
        let tok = t[i]
        guard !tok.quoted, tok.lead.isEmpty else { return nil }
        let setOffBefore = isSentenceStart(i) || t[i - 1].endsWithComma
        guard setOffBefore else { return nil }
        if (tok.lower == "you" || tok.lower == "i"), i + 1 < t.count, tok.trail.isEmpty, !t[i + 1].quoted,
           (tok.lower == "you" && t[i + 1].lower == "know") || (tok.lower == "i" && t[i + 1].lower == "mean") {
            let second = t[i + 1]
            // Something must remain after it in the sentence, unless the filler ends it after a comma.
            if second.endsWithComma, i + 2 < t.count, !t[i + 2].isPunctuationOnly { return 2 }
            if second.trail == ".", i > 0, t[i - 1].endsWithComma { return 2 }
            return nil
        }
        if tok.lower == "like", tok.endsWithComma, i + 1 < t.count, Self.likeFollowers.contains(t[i + 1].lower), !t[i + 1].quoted {
            return 1
        }
        return nil
    }

    // MARK: 7. Punctuation

    mutating func tidyPunctuation() {
        for i in t.indices where !t[i].quoted {
            let tidied = Self.tidyTrail(t[i].trail)
            if tidied != t[i].trail {
                let before = t[i].text
                t[i].trail = tidied
                record(.punctuation, removed: before, inserted: t[i].text, at: t[i].origin)
            }
        }
        var i = 0
        while i + 1 < t.count {
            let tok = t[i]
            // A full stop after a word that can't end a sentence was a pause.
            if !tok.quoted, tok.trail == ".", L.cannotEndSentence.contains(tok.lower), t[i + 1].breakBefore == 0, !t[i + 1].quoted {
                let before = TranscriptTokenizer.render(t[i...(i + 1)])
                t[i].trail = ""
                if t[i + 1].isCapitalised, !t[i + 1].isAllCaps, !Self.isIForm(t[i + 1].lower), !isTaggedName(i + 1) {
                    t[i + 1].lowercaseFirst()
                }
                tags.invalidate()
                record(.punctuation, removed: before, inserted: TranscriptTokenizer.render(t[i...(i + 1)]), at: tok.origin)
            }
            // A capital on a small word after a comma.
            let next = t[i + 1]
            if tok.endsWithComma, !next.quoted, next.isCapitalised, !next.isAllCaps, next.breakBefore == 0,
               L.functionWords.contains(next.lower), !Self.isIForm(next.lower) {
                let before = next.text
                t[i + 1].lowercaseFirst()
                record(.punctuation, removed: before, inserted: t[i + 1].text, at: next.origin)
            }
            i += 1
        }
    }

    static func tidyTrail(_ trail: String) -> String {
        guard trail.count > 1 else { return trail }
        var s = trail
        let pairs: [(String, String)] = [(",,", ","), (",.", "."), (".,", "."), (";,", ";"), (",;", ";"), ("??", "?"), (",?", "?"), (".?", "?"), (",!", "!"), (":,", ":")]
        var changed = true
        while changed {
            changed = false
            for (from, to) in pairs where s.contains(from) {
                s = s.replacingOccurrences(of: from, with: to)
                changed = true
            }
        }
        // Two full stops are one; three are an ellipsis.
        if s.hasSuffix("..") && !s.hasSuffix("...") { s.removeLast() }
        return s
    }

    // MARK: 8. Sentence case

    mutating func applySentenceCase() {
        for i in t.indices where isSentenceStart(i) && !t[i].quoted && !t[i].isPunctuationOnly {
            let core = t[i].core
            guard let first = core.first, first.isLowercase,
                  !core.dropFirst().contains(where: \.isUppercase),
                  !core.contains(where: { "./@_#\\".contains($0) }) else { continue }
            let before = t[i].text
            t[i].capitalise()
            record(.punctuation, removed: before, inserted: t[i].text, at: t[i].origin)
        }
    }

    /// Casual: "see you at 5." → "see you at 5" when it is one short sentence.
    mutating func dropFinalFullStopIfShort() {
        guard let last = t.last, t.count <= 12, last.trail == ".", !last.quoted else { return }
        guard !t.dropLast().contains(where: { $0.endsSentence || $0.breakBefore > 0 }), !t.contains(where: { $0.breakBefore > 0 }) else { return }
        let before = last.text
        t[t.count - 1].trail = ""
        record(.punctuation, removed: before, inserted: t[t.count - 1].text, at: last.origin)
    }

    // MARK: Word classes

    static func isNumber(_ tok: WordToken) -> Bool {
        let w = tok.lower
        if CleanupLexicon.numberWords.contains(w) { return true }
        if w.contains("-") {
            let parts = w.split(separator: "-")
            if parts.count > 1, parts.allSatisfy({ CleanupLexicon.numberWords.contains(String($0)) }) { return true }
        }
        var s = Substring(w)
        if let c = s.first, "£€$".contains(c) { s = s.dropFirst() }
        guard let first = s.first, first.isNumber else { return false }
        var i = s.startIndex
        while i < s.endIndex, s[i].isNumber || ".,:".contains(s[i]) { i = s.index(after: i) }
        let suffix = String(s[i...])
        return suffix.isEmpty || ["st", "nd", "rd", "th", "pm", "am", "k", "m", "p", "%", "mg", "ml", "kg", "g", "s"].contains(suffix)
    }

    /// A unit ("mg", "pm") or a counted noun after a number ("tablets", "chairs").
    private func isCountedWord(_ i: Int) -> Bool {
        let tok = t[i]
        if tok.quoted || tok.isPunctuationOnly || Self.isNumber(tok) { return false }
        if L.units.contains(Self.unitKey(tok)) { return true }
        guard tok.core.allSatisfy({ $0.isLetter }), !tok.isCapitalised, !L.functionWords.contains(tok.lower),
              !L.followsRepair.contains(tok.lower), !L.weekdays.contains(tok.lower), !L.relativeDays.contains(tok.lower) else { return false }
        tags.fill(t)
        return tags.lexical[i] == .noun
    }

    /// "tablet" and "tablets", "box" and "boxes", "pm" and "pm".
    static func sameUnit(_ a: WordToken, _ b: WordToken) -> Bool {
        let x = unitKey(a), y = unitKey(b)
        if x == y { return true }
        if CleanupLexicon.units.contains(x) && CleanupLexicon.units.contains(y) {
            let times: Set<String> = ["pm", "am", "a.m", "p.m", "o'clock"]
            return times.contains(x) && times.contains(y)
        }
        func singular(_ w: String) -> String {
            if w.hasSuffix("es"), w.count > 3, ["x", "s", "ch", "sh"].contains(where: { w.dropLast(2).hasSuffix($0) }) { return String(w.dropLast(2)) }
            if w.hasSuffix("s"), w.count > 2 { return String(w.dropLast()) }
            return w
        }
        return singular(x) == singular(y)
    }

    static func unitKey(_ tok: WordToken) -> String {
        var w = tok.lower
        while w.hasSuffix(".") { w.removeLast() }
        return w
    }

    /// A capitalised word that could be (part of) a name.
    private func isNameWord(_ i: Int) -> Bool {
        let tok = t[i]
        guard tok.isCapitalised, !tok.quoted, tok.core.count > 1 || tok.core == "O",
              tok.core.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "-" }),
              !tok.lower.hasSuffix("'s"),
              !CleanupLexicon.notNames.contains(tok.lower),
              !CleanupLexicon.weekdays.contains(tok.lower), !CleanupLexicon.months.contains(tok.lower),
              !CleanupLexicon.relativeDays.contains(tok.lower) else { return false }
        return true
    }

    // MARK: NaturalLanguage

    private func isTaggedName(_ i: Int) -> Bool {
        tags.fill(t)
        guard let name = tags.names[i] else { return false }
        return name == .personalName || name == .placeName || name == .organizationName
    }

    /// The words after a determiner are a noun phrase: no verbs, prepositions or conjunctions.
    private func isNounPhrase(_ r: ClosedRange<Int>) -> Bool {
        guard r.lowerBound <= r.upperBound, r.upperBound < t.count else { return false }
        for i in r where L.functionWords.contains(t[i].lower) && t[i].lower != "one" { return false }
        tags.fill(t)
        for i in r {
            guard let tag = tags.lexical[i] else { continue }
            switch tag {
            case .verb, .preposition, .conjunction, .particle, .determiner, .adverb: return false
            case .pronoun where t[i].lower != "one": return false
            default: continue
            }
        }
        return true
    }
}

/// Word classes for the current words, computed only when a rule needs them and again only
/// after the words change. Owned by one `CleanupWork`, never shared across threads.
final class TagCache {
    var lexical: [NLTag?] = []
    var names: [NLTag?] = []
    private var valid = false

    func invalidate() { valid = false }

    func fill(_ tokens: [WordToken]) {
        guard !valid || lexical.count != tokens.count else { return }
        var text = ""
        var offsets: [Int] = []
        for tok in tokens {
            if !text.isEmpty { text += " " }
            offsets.append(text.count + tok.lead.count)
            text += tok.text
        }
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .nameType])
        tagger.string = text
        let starts = offsets.map { text.index(text.startIndex, offsetBy: $0) }
        lexical = tokens.indices.map { i in
            tokens[i].core.isEmpty ? nil : tagger.tag(at: starts[i], unit: .word, scheme: .lexicalClass).0
        }
        names = tokens.indices.map { i in
            tokens[i].core.isEmpty ? nil : tagger.tag(at: starts[i], unit: .word, scheme: .nameType).0
        }
        valid = true
    }
}
