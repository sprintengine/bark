import Foundation
import Synchronization
import Testing
@testable import FairspokenCore

@Suite("Live text")
struct LiveTranscriptTests {
    // MARK: Joining pieces

    @Test func joinsPiecesWithSingleSpaces() {
        #expect(LiveTranscript.join(["Please send", "  the letter\ntoday. "]) == "Please send the letter today.")
        #expect(LiveTranscript.join(["", "  ", "Hello."]) == "Hello.")
        #expect(LiveTranscript.join([]) == "")
    }

    @Test func dropsTheFullStopOfAPieceCutMidSentence() {
        #expect(LiveTranscript.join(["mild shortness.", "of breath when climbing stairs."])
            == "mild shortness of breath when climbing stairs.")
    }

    @Test func keepsRealSentenceEnds() {
        #expect(LiveTranscript.join(["Book it.", "Then call Anna."]) == "Book it. Then call Anna.")
        #expect(LiveTranscript.join(["Wait for it...", "now go"]) == "Wait for it... now go")
        #expect(LiveTranscript.join(["Is it ready?", "yes"]) == "Is it ready? yes")
        #expect(LiveTranscript.join(["in.", "10 days"]) == "in. 10 days")
    }

    // MARK: Fitting the pill

    @Test func shortTextIsShownWhole() {
        #expect(LiveTranscript.displayTail("  hello   world ", maxCharacters: 40) == "hello world")
        #expect(LiveTranscript.displayTail("hello", maxCharacters: 5) == "hello")
    }

    @Test func longTextKeepsTheNewestWholeWords() {
        let text = "The patient reports a dry cough for two weeks with no fever"
        #expect(LiveTranscript.displayTail(text, maxCharacters: 22) == "…weeks with no fever")
        let tail = LiveTranscript.displayTail(text, maxCharacters: 24)
        #expect(tail == "…two weeks with no fever")
        #expect(tail.count <= 24)
        #expect(text.hasSuffix(tail.dropFirst()))
    }

    @Test func aCutOnASpaceKeepsTheWholeNextWord() {
        // "abc def ghi" with 8 characters: the 7 kept are "def ghi", already a word boundary.
        #expect(LiveTranscript.displayTail("abc def ghi", maxCharacters: 8) == "…def ghi")
    }

    @Test func oneLongWordIsCutMidWord() {
        let tail = LiveTranscript.displayTail("supercalifragilistic", maxCharacters: 8)
        #expect(tail == "…ilistic")
        #expect(tail.count == 8)
    }

    @Test func tinyBudgetsShowNothing() {
        #expect(LiveTranscript.displayTail("hello", maxCharacters: 1) == "")
        #expect(LiveTranscript.displayTail("hello", maxCharacters: 0) == "")
    }

    @Test func quietDetection() {
        #expect(LiveTranscript.isQuiet([]))
        #expect(LiveTranscript.isQuiet([Float](repeating: 0.0005, count: 1600)[...]))
        #expect(!LiveTranscript.isQuiet(tone(seconds: 0.1)[...]))
    }

    // MARK: Segmenting

    @Test func segmenterWaitsFor12Seconds() {
        #expect(LiveSegmenter().cutPoint(tone(seconds: 11.9)[...], sampleRate: 16_000) == nil)
    }

    @Test func segmenterCutsAtThePause() {
        var audio = tone(seconds: 13)
        let pause = Int(9.5 * 16_000)
        for i in pause..<(pause + 1600) { audio[i] = 0 }
        let cut = LiveSegmenter().cutPoint(audio[...], sampleRate: 16_000)
        #expect(cut.map { (pause..<(pause + 1600)).contains($0) } == true)
    }

    @Test func segmenterWorksOnSlices() {
        var audio = tone(seconds: 20)
        let pause = Int(16 * 16_000)
        for i in pause..<(pause + 800) { audio[i] = 0 }
        let slice = audio[(8 * 16_000)...]  // starts mid-array, as the live tail does
        let cut = LiveSegmenter().cutPoint(slice, sampleRate: 16_000)
        #expect(cut.map { (8 * 16_000 + $0) >= pause && (8 * 16_000 + $0) < pause + 800 } == true)
    }

    // MARK: Session

    @Test func sessionShowsGrowingTextAndFinishesWithTheWholeRecording() async throws {
        let engine = CountingEngine()
        let seen = Mutex<[String]>([])
        let session = LiveTranscriptionSession(engine: engine, options: .init(), timing: fastTiming) { text in
            seen.withLock { $0.append(text) }
        }
        for _ in 0..<10 {
            session.append(tone(seconds: 0.3))
            try await Task.sleep(for: .milliseconds(30))
        }
        try await waitUntil { seen.withLock { $0.last } == "w3000" }
        engine.finalPass()
        let output = try await session.finish(allSamples: tone(seconds: 3))
        #expect(output.text == "final 48000")
        let texts = seen.withLock { $0 }
        #expect(texts.count >= 2)
        #expect(texts == texts.sorted { Int($0.dropFirst())! < Int($1.dropFirst())! })
        #expect(session.statistics.decodes >= 2)
        #expect(session.statistics.firstTextMs != nil)
    }

    @Test func longSpeechIsCutIntoSegmentsDecodedOnce() async throws {
        let engine = CountingEngine()
        let seen = Mutex<String>("")
        let session = LiveTranscriptionSession(engine: engine, options: .init(), timing: fastTiming) { text in
            seen.withLock { $0 = text }
        }
        session.append(tone(seconds: 13))
        try await waitUntil { seen.withLock { $0.contains(" ") } }
        let text = seen.withLock { $0 }
        let parts = text.split(separator: " ")
        #expect(parts.count == 2)
        #expect(parts.map { Int($0.dropFirst())! }.reduce(0, +) == 13_000)
        #expect(session.statistics.segments == 1)
        session.cancel()
    }

    @Test func silenceAfterTheLastDecodeIsSkipped() async throws {
        let engine = CountingEngine()
        let seen = Mutex<[String]>([])
        let session = LiveTranscriptionSession(engine: engine, options: .init(), timing: fastTiming) { text in
            seen.withLock { $0.append(text) }
        }
        session.append(tone(seconds: 1) + [Float](repeating: 0, count: 8000))
        try await waitUntil { !seen.withLock { $0 }.isEmpty }
        let decodes = session.statistics.decodes
        for _ in 0..<5 {
            session.append([Float](repeating: 0, count: 8000))
            try await Task.sleep(for: .milliseconds(40))
        }
        #expect(session.statistics.decodes == decodes)
        #expect(session.statistics.skippedQuiet > 0)
        session.cancel()
    }

    @Test func nothingIsShownAfterCancel() async throws {
        let engine = CountingEngine()
        let seen = Mutex<Int>(0)
        let session = LiveTranscriptionSession(engine: engine, options: .init(), timing: fastTiming) { _ in
            seen.withLock { $0 += 1 }
        }
        session.cancel()
        session.append(tone(seconds: 2))
        try await Task.sleep(for: .milliseconds(150))
        #expect(seen.withLock { $0 } == 0)
        #expect(session.statistics.decodes == 0)
    }

    @Test func anEngineThatIsNotReadyShowsNothingButStillFinishes() async throws {
        let engine = CountingEngine(failLive: true)
        let seen = Mutex<Int>(0)
        let session = LiveTranscriptionSession(engine: engine, options: .init(), timing: fastTiming) { _ in
            seen.withLock { $0 += 1 }
        }
        session.append(tone(seconds: 2))
        try await Task.sleep(for: .milliseconds(150))
        #expect(seen.withLock { $0 } == 0)
        engine.finalPass()
        let output = try await session.finish(allSamples: tone(seconds: 2))
        #expect(output.text == "final 32000")
    }

    // MARK: Helpers

    private var fastTiming: LiveTranscriptionSession.Timing {
        var t = LiveTranscriptionSession.Timing()
        t.interval = .milliseconds(10)
        return t
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            if ContinuousClock.now > deadline { Issue.record("timed out"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private func tone(seconds: Double) -> [Float] {
    (0..<Int(seconds * 16_000)).map { Float(sin(Double($0) / 8)) * 0.2 }
}

/// Answers "w<ms of audio>" for live decodes and "final <samples>" once the test has called
/// `finalPass()`, so tests can see exactly which audio each decode covered.
private final class CountingEngine: SpeechEngine, @unchecked Sendable {
    private enum Mode { case live, failingLive, final }
    private let mode: Mutex<Mode>

    init(failLive: Bool = false) { mode = Mutex(failLive ? .failingLive : .live) }

    func finalPass() { mode.withLock { $0 = .final } }

    func transcribe(_ samples16k: [Float], options: TranscriptionRequestOptions) async throws -> TranscriptionOutput {
        let text: String
        switch mode.withLock({ $0 }) {
        case .failingLive: throw SpeechTestError.notReady
        case .live: text = "w\(samples16k.count / 16)"
        case .final: text = "final \(samples16k.count)"
        }
        return TranscriptionOutput(text: text, modelMs: 1, model: "stub", placement: .cpu)
    }
}

private enum SpeechTestError: Error { case notReady }
