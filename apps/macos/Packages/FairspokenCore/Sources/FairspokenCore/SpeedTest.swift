import Foundation

/// The speed test: type a passage, then say it, and see how much faster the voice is. Everything
/// here is measurement, free of UI and audio, so every number the test shows can be checked. The
/// same rules as the desktop app's `speedTest.ts`: net words per minute at five characters a word,
/// a typing check that a skipped space can't cascade, and an accuracy gate below which a spoken
/// result is not celebrated.
public enum SpeedTest {
    /// The standard net-WPM convention: five characters make a word.
    public static let charactersPerWord = 5.0
    /// Below this transcript accuracy (percent), the spoken leg is too rough to count as a win.
    public static let accuracyGate = 80

    // MARK: Typing

    /// Net words per minute: correctly typed characters, at five a word, over the time taken.
    public static func netWPM(correctCharacters: Int, seconds: Double) -> Int {
        guard seconds > 0, correctCharacters > 0 else { return 0 }
        return Int((Double(correctCharacters) / charactersPerWord / (seconds / 60)).rounded())
    }

    /// Correct keystrokes over all keystrokes, as a percent (100 before anything is typed).
    public static func accuracyPercent(typed: Int, errors: Int) -> Int {
        guard typed > 0 else { return 100 }
        return max(0, Int((Double(typed - errors) / Double(typed) * 100).rounded()))
    }

    public enum CellState: Sendable { case done, wrong, pending }

    public struct Cell: Equatable, Sendable {
        public var character: Character
        public var state: CellState
        /// A passage space the typist ran past (shown as a marked gap).
        public var missingSpace: Bool
    }

    public struct TypingAnalysis: Equatable, Sendable {
        public var cells: [Cell]
        /// Exact matches: the numerator of net WPM.
        public var correctCharacters: Int
        /// Wrong characters plus skipped spaces, in what has been typed so far.
        public var errors: Int
        /// The whole passage is covered: the typing leg is done.
        public var reachedEnd: Bool
        /// The caret's passage index, nil once the passage is complete.
        public var cursor: Int?
    }

    /// Lines what was typed up against the passage. Strictly by index, one missing space would
    /// put every later character a slot early and turn the rest red; here a skipped space counts
    /// once as a mistake but keeps the typed character for the next word, so the words after it
    /// line up again. It stays character by character: a typing test cares about exact keys.
    public static func analyzeTyping(_ typed: String, passage: String) -> TypingAnalysis {
        let target = Array(passage)
        let keys = Array(typed)
        var cells = target.map { Cell(character: $0, state: .pending, missingSpace: false) }
        var correct = 0, errors = 0, k = 0, i = 0
        while i < target.count, k < keys.count {
            if keys[k] == target[i] {
                cells[i].state = .done
                correct += 1
                k += 1
            } else if target[i] == " " {
                // Two words run together: one mistake, and the typed key goes to the next word.
                cells[i].state = .wrong
                cells[i].missingSpace = true
                errors += 1
            } else {
                cells[i].state = .wrong
                errors += 1
                k += 1
            }
            i += 1
        }
        let reachedEnd = i >= target.count
        return TypingAnalysis(cells: cells, correctCharacters: correct, errors: errors, reachedEnd: reachedEnd,
                              cursor: reachedEnd ? nil : i)
    }

    /// The typing leg's result.
    public struct TypingResult: Equatable, Sendable {
        public var seconds: Double
        public var wpm: Int
        public var accuracy: Int
        public init(seconds: Double, wpm: Int, accuracy: Int) {
            self.seconds = seconds
            self.wpm = wpm
            self.accuracy = accuracy
        }
    }

    /// The result of typing `typed` against `passage` in `seconds`.
    public static func typingResult(typed: String, passage: String, seconds: Double) -> TypingResult {
        let analysis = analyzeTyping(typed, passage: passage)
        return TypingResult(seconds: seconds, wpm: netWPM(correctCharacters: analysis.correctCharacters, seconds: seconds),
                            accuracy: accuracyPercent(typed: typed.count, errors: analysis.errors))
    }

    // MARK: Speaking

    /// The passage's words (what was read aloud).
    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    /// The whole run, typed and spoken, measured.
    public struct Outcome: Equatable, Sendable {
        public var typing: TypingResult
        /// From the recording's start to its end.
        public var speakingSeconds: Double
        /// The passage's words over the recording time.
        public var speakingWPM: Int
        public var comparison: TranscriptComparison
        /// Typing time over speaking time; 0 when there is no speaking time.
        public var multiplier: Double
        /// The passage's word count.
        public var words: Int

        /// The transcript was too rough to call the run a win.
        public var gated: Bool { comparison.accuracy < SpeedTest.accuracyGate }
        /// How much less time speaking took (never negative).
        public var secondsSaved: Double { max(0, typing.seconds - speakingSeconds) }
    }

    public static func outcome(passage: String, typing: TypingResult, transcript: String, speakingSeconds: Double) -> Outcome {
        let words = wordCount(passage)
        let comparison = TranscriptComparison(transcript: transcript, passage: passage)
        let speakingWPM = speakingSeconds > 0 ? Int((Double(words) / speakingSeconds * 60).rounded()) : 0
        let multiplier = speakingSeconds > 0 ? typing.seconds / speakingSeconds : 0
        return Outcome(typing: typing, speakingSeconds: speakingSeconds, speakingWPM: speakingWPM, comparison: comparison,
                       multiplier: multiplier, words: words)
    }

    // MARK: Results kept

    /// A finished run as kept on disk (`speed-test.json`, the desktop app's schema plus the
    /// accuracy and times of each leg). Measurements only, never the transcript.
    public struct Record: Codable, Equatable, Sendable {
        public var typingWpm: Int
        public var speakingWpm: Int
        public var multiplier: Double
        /// The spoken leg's accuracy (percent).
        public var accuracy: Int
        /// Seconds since 1970.
        public var recordedAt: Int64
        public var typingAccuracy: Int?
        public var typingSeconds: Double?
        public var speakingSeconds: Double?
        public var words: Int?

        public init(typingWpm: Int, speakingWpm: Int, multiplier: Double, accuracy: Int, recordedAt: Int64,
                    typingAccuracy: Int? = nil, typingSeconds: Double? = nil, speakingSeconds: Double? = nil, words: Int? = nil) {
            self.typingWpm = typingWpm
            self.speakingWpm = speakingWpm
            self.multiplier = multiplier
            self.accuracy = accuracy
            self.recordedAt = recordedAt
            self.typingAccuracy = typingAccuracy
            self.typingSeconds = typingSeconds
            self.speakingSeconds = speakingSeconds
            self.words = words
        }

        public init(_ outcome: Outcome, at date: Date) {
            self.init(typingWpm: outcome.typing.wpm, speakingWpm: outcome.speakingWPM, multiplier: outcome.multiplier,
                      accuracy: outcome.comparison.accuracy, recordedAt: Int64(date.timeIntervalSince1970),
                      typingAccuracy: outcome.typing.accuracy, typingSeconds: outcome.typing.seconds,
                      speakingSeconds: outcome.speakingSeconds, words: outcome.words)
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            typingWpm = c.lenientInt(.typingWpm) ?? 0
            speakingWpm = c.lenientInt(.speakingWpm) ?? 0
            multiplier = c.lenientDouble(.multiplier) ?? 0
            accuracy = c.lenientInt(.accuracy) ?? 0
            recordedAt = Int64(c.lenientDouble(.recordedAt) ?? 0)
            typingAccuracy = c.lenientInt(.typingAccuracy)
            typingSeconds = c.lenientDouble(.typingSeconds)
            speakingSeconds = c.lenientDouble(.speakingSeconds)
            words = c.lenientInt(.words)
        }

        public var date: Date { Date(timeIntervalSince1970: TimeInterval(recordedAt)) }
    }

    /// The latest run and the best (highest multiplier).
    public struct Summary: Codable, Equatable, Sendable {
        public var last: Record?
        public var best: Record?

        public init(last: Record? = nil, best: Record? = nil) {
            self.last = last
            self.best = best
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            last = try? c.decodeIfPresent(Record.self, forKey: .last)
            best = try? c.decodeIfPresent(Record.self, forKey: .best)
        }

        /// Keeps `record` as the latest, and as the best when it beats the best. True when it did.
        @discardableResult
        public mutating func record(_ record: Record) -> Bool {
            let isBest = best.map { record.multiplier > $0.multiplier } ?? true
            last = record
            if isBest { best = record }
            return isBest
        }
    }

    /// Only a run whose transcript passed the gate, and that has both times, is kept.
    public static func isKeepable(_ outcome: Outcome) -> Bool {
        !outcome.gated && outcome.multiplier > 0 && outcome.typing.seconds > 0
    }

    // MARK: Passages

    /// Read-aloud passages, deliberately several sentences long (about 75–85 words): a one-liner
    /// undersells the typing and narrows the gap between the legs. Plain, comfortable to say, no
    /// code, links or dense punctuation to trip the typist or the transcriber; similar lengths, so
    /// runs compare. The desktop app's passages.
    public static let passages: [String] = [
        "The harbor lights came on one by one as the evening fog rolled in, and the small boats turned for home before the tide could change against them. By the time the last of them reached the pier the rain had started in earnest, and the harbour master stood under the narrow awning, counting the masts as they came in and marking each one off in a notebook he had carried for longer than most of the crews had been alive.",
        "She left the office a little after six, walked the long way home past the river, and decided that whatever the meeting decided tomorrow could wait until tomorrow. The streets were quiet for a weekday, the cafes were closing one by one, and somewhere a few blocks over a band was tuning up for a show that probably would not start on time. She bought a coffee she did not need and drank it slowly, in no hurry at all to be anywhere.",
        "Most of the team agreed the new plan was simpler, though nobody could say for certain how the older systems would behave once the weekend migration finished. They had tested what they could, written down the parts they were unsure about, and agreed to meet early on Monday in case something needed a quick decision. For now there was nothing to do but wait, watch the dashboards, and trust that the work they had done carefully over the last month would hold.",
        "The train was late again, which gave her time to finish the chapter she had been carrying around for a week. The platform filled slowly with the usual evening crowd, people checking their phones and shifting their bags from one shoulder to the other. When the announcement finally came it was almost an apology, and the whole platform seemed to sigh at once before drifting toward the yellow line to wait for the doors to open.",
        "Nobody had expected the garden to do so well in its first year, least of all the people who had planted it. By midsummer the beds were crowded with tomatoes and beans, the herbs had spread well past their borders, and there were more courgettes than anyone in the building could reasonably eat. They left baskets of them in the lobby with a small handwritten sign, and somehow, by the end of each day, the baskets were always empty.",
        "The recipe had been in the family for so long that no one could say where it came from, and over the years each cook had changed it a little. Someone had added more garlic, someone else had quietly cut the sugar, and the result was a dish that tasted slightly different at every table yet somehow always the same. On cold evenings it was the first thing they reached for, and the smell of it filled the kitchen long before dinner.",
    ]

    /// A passage at random, never `excluding` (the one just used) when there is another.
    public static func pickPassage<G: RandomNumberGenerator>(excluding: String? = nil, using generator: inout G) -> String {
        let pool = passages.filter { $0 != excluding }
        return (pool.isEmpty ? passages : pool).randomElement(using: &generator)!
    }

    public static func pickPassage(excluding: String? = nil) -> String {
        var generator = SystemRandomNumberGenerator()
        return pickPassage(excluding: excluding, using: &generator)
    }
}
