import FairspokenCore
import Foundation
import Observation
import OSLog

/// The speed test's state: type a passage (timed from the first key), say it (a measured
/// recording: the real capture and transcription with the model in use, and nothing else), then
/// the two compared. The measurement itself is `SpeedTest` in FairspokenCore; this holds the run
/// and keeps the last and best results (`speed-test.json`, the desktop app's file).
@Observable
final class SpeedTestController {
    enum Step: Equatable { case typing, speaking, results }

    var isPresented = false {
        didSet { if !isPresented && oldValue { close() } }
    }
    private(set) var step: Step = .typing
    private(set) var passage: String
    /// What has been typed so far (never more than the passage).
    private(set) var typed = ""
    /// When the first key was typed (system uptime: a clock that never jumps).
    private(set) var typingStartedAt: TimeInterval?
    private(set) var typing: SpeedTest.TypingResult?
    /// Set when a paste was refused, to say why.
    private(set) var pasteRefused = false
    /// Why the last recording didn't produce a result.
    private(set) var speakingError: String?
    private(set) var outcome: SpeedTest.Outcome?
    /// The measured recording behind `outcome`.
    private(set) var measured: DictationController.Measured?
    /// A gated run whose times the user asked to see anyway (still not kept).
    private(set) var showsGatedTimes = false
    private(set) var isNewBest = false
    private(set) var summary: SpeedTest.Summary

    @ObservationIgnored private let dictation: DictationController
    @ObservationIgnored private let history: HistoryStore
    @ObservationIgnored private let url: URL
    @ObservationIgnored private let persists: Bool
    private static let log = Logger(subsystem: AppInfo.bundleID, category: "speed-test")

    init(dictation: DictationController, history: HistoryStore, directory: URL = AppInfo.supportDirectory,
         persists: Bool = !AppInfo.isDemo) {
        self.dictation = dictation
        self.history = history
        self.persists = persists
        url = directory.appendingPathComponent("speed-test.json")
        summary = persists ? Self.load(url) : Self.demoSummary
        passage = SpeedTest.pickPassage()
    }

    // MARK: Flow

    /// Opens the test on a fresh passage.
    func begin() {
        passage = SpeedTest.pickPassage(excluding: passage)
        resetTyping()
        step = .typing
        isPresented = true
    }

    /// The typing step again, on a new passage.
    func newPassage() {
        passage = SpeedTest.pickPassage(excluding: passage)
        restartTyping()
    }

    func restartTyping() {
        disarm()
        resetTyping()
        step = .typing
    }

    /// The typed text changed. The clock starts at the first key; covering the whole passage ends
    /// the typing leg.
    func typedChanged(_ text: String) {
        guard step == .typing, typing == nil else { return }
        let clipped = String(text.prefix(passage.count))
        typed = clipped
        if typingStartedAt == nil, !clipped.isEmpty { typingStartedAt = Self.now }
        if SpeedTest.analyzeTyping(clipped, passage: passage).reachedEnd {
            typing = SpeedTest.typingResult(typed: clipped, passage: passage, seconds: typingSeconds())
            goToSpeaking()
        }
    }

    func refusedPaste() { pasteRefused = true }

    /// Seconds since the first key (0 before it).
    func typingSeconds(at now: TimeInterval = SpeedTestController.now) -> Double {
        typingStartedAt.map { max(0, now - $0) } ?? 0
    }

    private func goToSpeaking() {
        speakingError = nil
        outcome = nil
        measured = nil
        showsGatedTimes = false
        step = .speaking
        // From here the dictation shortcut (and the button) records the passage, with this app in front.
        dictation.measure = { [weak self] in self?.received($0) }
    }

    /// The speaking step again (after a rough transcript or an error), with the same typing time.
    func speakAgain() {
        guard typing != nil else { return restartTyping() }
        goToSpeaking()
    }

    /// The button: start or stop the measured recording.
    func toggleRecording() {
        guard step == .speaking else { return }
        // A dictation into another app is still going: leave it alone.
        if dictation.phase.isActive && !dictation.isMeasuring {
            speakingError = "A dictation is still running. Try again when it has finished."
            return
        }
        speakingError = nil
        dictation.toggleFromUI()
    }

    var isRecording: Bool { dictation.isMeasuring && dictation.phase.isListening }
    var isTranscribing: Bool { dictation.isMeasuring && dictation.phase == .transcribing }

    private func received(_ result: DictationController.MeasuredOutcome) {
        guard step == .speaking, let typing else { return }
        switch result {
        case .cancelled:
            break
        case .failed(let message):
            speakingError = message
        case .captured(let capture):
            let outcome = SpeedTest.outcome(passage: passage, typing: typing, transcript: capture.text,
                                            speakingSeconds: capture.recordingSeconds)
            measured = capture
            self.outcome = outcome
            isNewBest = false
            if SpeedTest.isKeepable(outcome) { keep(outcome) }
            disarm()
            step = .results
        }
    }

    /// A gated run: show its times anyway, marked as not kept.
    func showGatedTimes() { showsGatedTimes = true }

    /// Ends the test (Done, Cancel, or the sheet closing): any recording for it is thrown away.
    private func close() {
        disarm()
        if dictation.isMeasuring { dictation.cancel() }
    }

    private func disarm() {
        dictation.measure = nil
    }

    private func resetTyping() {
        typed = ""
        typingStartedAt = nil
        typing = nil
        pasteRefused = false
        speakingError = nil
        outcome = nil
        measured = nil
        showsGatedTimes = false
        isNewBest = false
    }

    // MARK: Keeping results

    private func keep(_ outcome: SpeedTest.Outcome) {
        isNewBest = summary.record(SpeedTest.Record(outcome, at: Date()))
        // Time saved on Home is counted against this typing speed from now on.
        history.setMeasuredTypingWPM(outcome.typing.wpm)
        save()
    }

    private func save() {
        guard persists else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(summary).write(to: url, options: .atomic)
        } catch {
            Self.log.error("Saving the speed test failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func load(_ url: URL) -> SpeedTest.Summary {
        if let data = try? Data(contentsOf: url), let summary = try? JSONDecoder().decode(SpeedTest.Summary.self, from: data) {
            return summary
        }
        // Once: the desktop app's results, so a test taken there still shows.
        let tauri = AppInfo.tauriDirectory.appendingPathComponent("speed-test.json")
        guard let data = try? Data(contentsOf: tauri),
              let summary = try? JSONDecoder().decode(SpeedTest.Summary.self, from: data) else { return SpeedTest.Summary() }
        try? data.write(to: url, options: .atomic)
        return summary
    }

    static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: Demo and screenshots

    /// A sample result for demo runs: fictional numbers.
    static let demoRecord = SpeedTest.Record(typingWpm: 44, speakingWpm: 151, multiplier: 3.4, accuracy: 98,
                                             recordedAt: Int64(Date().addingTimeInterval(-3 * 86_400).timeIntervalSince1970),
                                             typingAccuracy: 96, typingSeconds: 110, speakingSeconds: 32.4, words: 82)
    static let demoSummary = SpeedTest.Summary(last: demoRecord, best: demoRecord)

    /// Screenshots: Home's card with a result, or none yet. Never saved.
    func showcaseSummary(_ summary: SpeedTest.Summary) {
        guard !persists else { return }
        self.summary = summary
    }

    /// Screenshots: the typing step part-way through `typed`, begun `seconds` ago.
    func showcaseTyping(passage: String, typed: String, seconds: Double) {
        guard !persists else { return }
        self.passage = passage
        resetTyping()
        self.typed = typed
        typingStartedAt = Self.now - seconds
        step = .typing
        isPresented = true
    }

    /// Screenshots: the speaking step after a typing leg of `typing`.
    func showcaseSpeaking(passage: String, typing: SpeedTest.TypingResult, error: String? = nil) {
        guard !persists else { return }
        self.passage = passage
        resetTyping()
        self.typed = passage
        self.typing = typing
        step = .speaking
        speakingError = error
        isPresented = true
    }

    /// Screenshots: the results of a run (kept or gated) from a sample transcript.
    func showcaseResults(passage: String, typing: SpeedTest.TypingResult, transcript: String, speakingSeconds: Double,
                         newBest: Bool = false, gatedTimes: Bool = false) {
        guard !persists else { return }
        self.passage = passage
        resetTyping()
        self.typed = passage
        self.typing = typing
        let outcome = SpeedTest.outcome(passage: passage, typing: typing, transcript: transcript, speakingSeconds: speakingSeconds)
        self.outcome = outcome
        measured = DictationController.Measured(text: transcript, recordingSeconds: speakingSeconds, transcribeMs: 212,
                                                model: SpeechModelCatalog.defaultModelID, placement: .neuralEngine)
        isNewBest = newBest
        showsGatedTimes = gatedTimes
        step = .results
        isPresented = true
    }
}
