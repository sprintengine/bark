import Foundation
import Testing
@testable import FairspokenCore

@Suite("Speed test")
struct SpeedTestTests {
    // MARK: Typing

    @Test func netWPMCountsFiveCharactersAWord() {
        // 250 correct characters = 50 words, in a minute.
        #expect(SpeedTest.netWPM(correctCharacters: 250, seconds: 60) == 50)
        // The same in 30 s is twice as fast.
        #expect(SpeedTest.netWPM(correctCharacters: 250, seconds: 30) == 100)
        #expect(SpeedTest.netWPM(correctCharacters: 0, seconds: 30) == 0)
        #expect(SpeedTest.netWPM(correctCharacters: 100, seconds: 0) == 0)
    }

    @Test func accuracyIsCorrectKeysOverAllKeys() {
        #expect(SpeedTest.accuracyPercent(typed: 0, errors: 0) == 100)
        #expect(SpeedTest.accuracyPercent(typed: 100, errors: 4) == 96)
        #expect(SpeedTest.accuracyPercent(typed: 3, errors: 1) == 67)
        // Skipped spaces count as errors without a keystroke; never below zero.
        #expect(SpeedTest.accuracyPercent(typed: 2, errors: 5) == 0)
    }

    @Test func exactTypingIsAllDone() {
        let a = SpeedTest.analyzeTyping("the cat", passage: "the cat sat")
        #expect(a.correctCharacters == 7)
        #expect(a.errors == 0)
        #expect(!a.reachedEnd)
        #expect(a.cursor == 7)
        #expect(a.cells.prefix(7).allSatisfy { $0.state == .done })
        #expect(a.cells.suffix(4).allSatisfy { $0.state == .pending })
    }

    @Test func aWrongCharacterIsOneMistakeAndTheRestStaysAligned() {
        let a = SpeedTest.analyzeTyping("thx cat", passage: "the cat")
        #expect(a.errors == 1)
        #expect(a.correctCharacters == 6)
        #expect(a.cells[2].state == .wrong)
        #expect(!a.cells[2].missingSpace)
        #expect(a.reachedEnd)
        #expect(a.cursor == nil)
    }

    @Test func aSkippedSpaceDoesNotTurnTheRestRed() {
        // "thecat sat": the space after "the" was missed; "cat sat" still lines up.
        let a = SpeedTest.analyzeTyping("thecat sat", passage: "the cat sat")
        #expect(a.errors == 1)
        #expect(a.correctCharacters == 10)
        #expect(a.cells[3].state == .wrong)
        #expect(a.cells[3].missingSpace)
        #expect(a.cells[4...].allSatisfy { $0.state == .done })
        #expect(a.reachedEnd)
    }

    @Test func nothingTypedLeavesEverythingPending() {
        let a = SpeedTest.analyzeTyping("", passage: "abc")
        #expect(a.cells.allSatisfy { $0.state == .pending })
        #expect(a.cursor == 0)
        #expect(!a.reachedEnd)
    }

    @Test func typingResultMeasuresTheLeg() {
        let passage = "the cat sat"
        let r = SpeedTest.typingResult(typed: "the cat sat", passage: passage, seconds: 6)
        // 11 characters / 5 = 2.2 words in 0.1 min = 22 wpm.
        #expect(r.wpm == 22)
        #expect(r.accuracy == 100)
        #expect(r.seconds == 6)
    }

    // MARK: Transcript comparison

    @Test func anIdenticalTranscriptIsAllHits() {
        let c = TranscriptComparison(transcript: "The cat sat.", passage: "the cat sat")
        #expect(c.hits == 3)
        #expect(c.accuracy == 100)
        #expect(c.target.map(\.state) == [.hit, .hit, .hit])
        #expect(c.target[0].raw == "the")
        #expect(c.heard[2].raw == "sat.")
    }

    @Test func capitalsAndPunctuationNeverCount() {
        let c = TranscriptComparison(transcript: "HARBOUR, master!", passage: "harbour master")
        #expect(c.accuracy == 100)
        #expect(TranscriptComparison.normalize("Don't!") == "dont")
    }

    @Test func aSubstitutionIsNotADroppedWord() {
        let c = TranscriptComparison(transcript: "the dog sat", passage: "the cat sat")
        #expect(c.hits == 2)
        #expect(c.substitutions == 1)
        #expect(c.deletions == 0)
        #expect(c.insertions == 0)
        #expect(c.target[1].state == .substituted)
        #expect(c.target[1].counterpart == 1)
        #expect(c.heard[1].state == .substituted)
        #expect(c.accuracy == 67)
    }

    @Test func droppedAndExtraWordsAreTold() {
        let dropped = TranscriptComparison(transcript: "the sat", passage: "the cat sat")
        #expect(dropped.deletions == 1)
        #expect(dropped.target[1].state == .miss)
        #expect(dropped.misses == 1)

        let extra = TranscriptComparison(transcript: "the big cat sat", passage: "the cat sat")
        #expect(extra.insertions == 1)
        #expect(extra.heard[1].state == .inserted)
        #expect(extra.accuracy == 100)
    }

    @Test func wordOrderMatters() {
        // An order-blind count would call this perfect.
        let c = TranscriptComparison(transcript: "sat cat the", passage: "the cat sat")
        #expect(c.hits == 1)
        #expect(c.accuracy == 33)
    }

    @Test func repeatedWordsAlignTheSameWayEveryTime() {
        let a = TranscriptComparison(transcript: "one by one", passage: "one by one by one")
        let b = TranscriptComparison(transcript: "one by one", passage: "one by one by one")
        #expect(a == b)
        #expect(a.hits == 3)
        #expect(a.deletions == 2)
    }

    @Test func emptySidesAreHandled() {
        #expect(TranscriptComparison(transcript: "", passage: "the cat").accuracy == 0)
        #expect(TranscriptComparison(transcript: "", passage: "").accuracy == 100)
        #expect(TranscriptComparison(transcript: "hello", passage: "").accuracy == 0)
        // Stray punctuation is not a word.
        #expect(TranscriptComparison(transcript: "— the cat", passage: "the cat").insertions == 0)
    }

    // MARK: Outcome and the gate

    @Test func aCleanRunIsCelebratedWithMeasuredNumbers() {
        let passage = SpeedTest.passages[0]
        let words = SpeedTest.wordCount(passage)
        let typing = SpeedTest.TypingResult(seconds: 120, wpm: 42, accuracy: 97)
        let o = SpeedTest.outcome(passage: passage, typing: typing, transcript: passage, speakingSeconds: 40)
        #expect(!o.gated)
        #expect(o.comparison.accuracy == 100)
        #expect(o.multiplier == 3)
        #expect(o.speakingWPM == Int((Double(words) / 40 * 60).rounded()))
        #expect(o.secondsSaved == 80)
        #expect(o.words == words)
        #expect(SpeedTest.isKeepable(o))
    }

    @Test func aRoughTranscriptIsGatedAndNotKept() {
        let passage = "one two three four five six seven eight nine ten"
        let typing = SpeedTest.TypingResult(seconds: 20, wpm: 30, accuracy: 100)
        // 7 of 10 words: below the 80% gate.
        let rough = SpeedTest.outcome(passage: passage, typing: typing, transcript: "one two three four five six seven",
                                      speakingSeconds: 4)
        #expect(rough.comparison.accuracy == 70)
        #expect(rough.gated)
        #expect(!SpeedTest.isKeepable(rough))
        // 8 of 10 is exactly on the gate, and passes.
        let ok = SpeedTest.outcome(passage: passage, typing: typing, transcript: "one two three four five six seven eight",
                                   speakingSeconds: 4)
        #expect(!ok.gated)
    }

    @Test func noSpeakingTimeIsNoMultiplier() {
        let typing = SpeedTest.TypingResult(seconds: 20, wpm: 30, accuracy: 100)
        let o = SpeedTest.outcome(passage: "a b", typing: typing, transcript: "a b", speakingSeconds: 0)
        #expect(o.multiplier == 0)
        #expect(o.speakingWPM == 0)
        #expect(!SpeedTest.isKeepable(o))
    }

    // MARK: Results kept

    private func record(_ multiplier: Double, at: Int64) -> SpeedTest.Record {
        SpeedTest.Record(typingWpm: 40, speakingWpm: 150, multiplier: multiplier, accuracy: 95, recordedAt: at)
    }

    @Test func theFirstRunIsTheBest() {
        var summary = SpeedTest.Summary()
        let isBest = summary.record(record(3.0, at: 1))
        #expect(isBest)
        #expect(summary.best?.multiplier == 3.0)
        #expect(summary.last?.multiplier == 3.0)
    }

    @Test func theBestMovesOnlyOnAHigherMultiplier() {
        var summary = SpeedTest.Summary()
        summary.record(record(3.5, at: 1))
        let slowerIsBest = summary.record(record(2.9, at: 2))
        #expect(!slowerIsBest)
        #expect(summary.last?.multiplier == 2.9)
        #expect(summary.best?.multiplier == 3.5)
        let fasterIsBest = summary.record(record(4.1, at: 3))
        #expect(fasterIsBest)
        #expect(summary.best?.multiplier == 4.1)
    }

    @Test func readsTheDesktopAppsFile() throws {
        // The desktop app writes only these five keys.
        let json = #"{"last":{"typingWpm":41,"speakingWpm":148,"multiplier":3.25,"accuracy":96,"recordedAt":1750000000},"best":null}"#
        let summary = try JSONDecoder().decode(SpeedTest.Summary.self, from: Data(json.utf8))
        #expect(summary.last?.typingWpm == 41)
        #expect(summary.last?.multiplier == 3.25)
        #expect(summary.last?.typingSeconds == nil)
        #expect(summary.best == nil)
    }

    @Test func aRecordRoundTripsWithEachLegsDetail() throws {
        let typing = SpeedTest.TypingResult(seconds: 95.5, wpm: 48, accuracy: 96)
        let o = SpeedTest.outcome(passage: SpeedTest.passages[1], typing: typing, transcript: SpeedTest.passages[1], speakingSeconds: 31.2)
        let r = SpeedTest.Record(o, at: Date(timeIntervalSince1970: 1_750_000_000))
        let back = try JSONDecoder().decode(SpeedTest.Record.self, from: JSONEncoder().encode(r))
        #expect(back == r)
        #expect(back.typingSeconds == 95.5)
        #expect(back.speakingSeconds == 31.2)
        #expect(back.typingAccuracy == 96)
    }

    // MARK: Passages

    @Test func passagesAreLongEnoughToMeasure() {
        #expect(SpeedTest.passages.count == 6)
        for p in SpeedTest.passages {
            #expect((70...100).contains(SpeedTest.wordCount(p)))
            // Plain text the typist can type: no curly quotes or dashes.
            #expect(p.allSatisfy { $0.isASCII })
        }
    }

    @Test func aNewPassageIsNeverTheOneJustUsed() {
        var generator = SystemRandomNumberGenerator()
        for p in SpeedTest.passages {
            for _ in 0..<20 { #expect(SpeedTest.pickPassage(excluding: p, using: &generator) != p) }
        }
        #expect(SpeedTest.passages.contains(SpeedTest.pickPassage()))
    }

    // MARK: Lifetime stats

    @Test func aMeasuredTypingSpeedReplacesTheAssumedOne() {
        // 40 words dictated in 20 s. At the assumed 40 wpm typing takes 60 s → 40 s saved.
        var usage = UsageStats()
        usage.record(words: 40, recordingSeconds: 20)
        #expect(usage.typingWPMInUse == 40)
        #expect(usage.typingSeconds == 60)
        #expect(usage.timeSavedSeconds == 40)
        // A measured 80 wpm types them in 30 s: 10 s saved.
        usage.measuredTypingWpm = 80
        #expect(usage.typingSeconds == 30)
        #expect(usage.timeSavedSeconds == 10)
    }

    @Test func measuredTypingSpeedIsKeptSane() throws {
        #expect(UsageStats.validTypingWPM(0) == nil)
        #expect(UsageStats.validTypingWPM(.nan) == nil)
        #expect(UsageStats.validTypingWPM(1000) == 400)
        #expect(UsageStats.validTypingWPM(2) == 5)
        let json = #"{"totalWords":10,"totalRecordingSeconds":5,"totalDictations":1,"measuredTypingWpm":1000}"#
        let usage = try JSONDecoder().decode(UsageStats.self, from: Data(json.utf8))
        #expect(usage.measuredTypingWpm == 400)
        let none = try JSONDecoder().decode(UsageStats.self, from: Data(#"{"totalWords":10}"#.utf8))
        #expect(none.measuredTypingWpm == nil)
        #expect(none.typingWPMInUse == UsageStats.typingWPM)
    }
}
