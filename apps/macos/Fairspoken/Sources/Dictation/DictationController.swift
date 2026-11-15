import AppKit
import AVFoundation
import FairspokenCore
import Observation
import OSLog

/// The dictation state machine: hotkey/button → capture → (gate) → transcribe → post-process
/// → deliver (paste into the frontmost app, or show in our own window) → history
/// (→ kept for post-training, when that is on).
@Observable
final class DictationController {
    enum Trigger { case hotkey, fn, button }

    enum Delivery: Equatable {
        case pasted(app: String?)
        case copied(String)
        case shownInApp
    }

    struct Result: Equatable {
        var text: String
        var words: Int
        var delivery: Delivery
        var latencyMs: Int
        var placement: ComputePlacement
    }

    enum Phase: Equatable {
        case idle
        case listening(since: Date)
        case transcribing
        case done(Result)
        case failed(String)

        var isListening: Bool { if case .listening = self { true } else { false } }
        var isActive: Bool {
            switch self {
            case .listening, .transcribing: true
            default: false
            }
        }
    }

    private(set) var phase: Phase = .idle {
        didSet {
            guard phase != oldValue else { return }
            if !phase.isActive { liveText = "" }
            onPhaseChange?(phase)
        }
    }
    /// The words so far while listening (local transcription with "Show text while speaking").
    private(set) var liveText = ""
    /// Latest transcript produced while our own window was frontmost ("Try dictation").
    private(set) var lastInAppResult: Result?

    @ObservationIgnored var onPhaseChange: ((Phase) -> Void)?
    @ObservationIgnored var onNeedsOnboarding: (() -> Void)?
    /// Called as any recording starts (shortcut, fn, the menu bar, a button), before it takes the
    /// microphone: the setup guide's test steps aside.
    @ObservationIgnored var onWillStart: (() -> Void)?
    @ObservationIgnored let capture = AudioCapture()
    @ObservationIgnored private var session: (any TranscriptionSession)?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var resetTask: Task<Void, Never>?
    /// Which of this app's windows the recording is for (Home, the setup guide), or nil when it
    /// is for another app.
    @ObservationIgnored private(set) var startedInWindow: NSUserInterfaceItemIdentifier?
    /// What started the current recording (the pill says how to end it).
    private(set) var trigger: Trigger = .button
    @ObservationIgnored private var targetApp: NSRunningApplication?
    @ObservationIgnored private var placement: ComputePlacement = .neuralEngine
    @ObservationIgnored private var liveGeneration = 0
    @ObservationIgnored private let postProcessor: any TranscriptPostProcessor = BasicPostProcessor()

    private let settings: SettingsStore
    private let models: ModelLibrary
    private let history: HistoryStore
    private let training: TrainingLibrary?
    private let permissions: Permissions
    @ObservationIgnored var hotkeys: HotkeyController?
    /// Learns from the user fixing a dictation in place (`learnFromEdits`).
    @ObservationIgnored var editWatcher: EditWatcher?
    private static let log = Logger(subsystem: AppInfo.bundleID, category: "dictation")

    var meter: LevelMeter { capture.meter }
    /// Hold or toggle, for the pill's key hints.
    var shortcutMode: RecordingShortcutMode { settings.settings.recordingShortcutMode }

    init(settings: SettingsStore, models: ModelLibrary, history: HistoryStore, permissions: Permissions, training: TrainingLibrary? = nil) {
        self.settings = settings
        self.models = models
        self.history = history
        self.permissions = permissions
        self.training = training
    }

    // MARK: Triggers

    /// Combo key-down. Toggle mode toggles; push-to-talk starts.
    func hotkeyPressed() {
        if settings.settings.recordingShortcutMode == .toggle {
            phase.isListening ? stop() : start(.hotkey)
        } else if !phase.isListening {
            start(.hotkey)
        }
    }

    func hotkeyReleased() {
        if settings.settings.recordingShortcutMode == .pushToTalk, phase.isListening, trigger == .hotkey { stop() }
    }

    func fnPressed() { if !phase.isActive { start(.fn) } }
    func fnReleased() { if phase.isListening, trigger == .fn { stop() } }

    func toggleFromUI() { phase.isListening ? stop() : start(.button) }

    // MARK: Lifecycle

    func start(_ trigger: Trigger) {
        guard !phase.isActive else { return }
        // The next dictation may land in the field the last one is being watched in.
        editWatcher?.flush()
        onWillStart?()
        permissions.refresh()
        switch permissions.microphone {
        case .granted: break
        case .notDetermined:
            permissions.request(.microphone)
            return
        case .denied:
            fail("Microphone access is off")
            onNeedsOnboarding?()
            return
        }

        let s = settings.settings
        let hints = VocabularyPacks.hints(userTerms: s.vocabularyHints, enabledPacks: s.enabledPacks)
        let options = TranscriptionRequestOptions(language: s.language, vocabularyHints: hints)
        let newSession: any TranscriptionSession
        if s.transcriptionLocation == .remoteHost {
            do {
                let base = try RemoteURLPolicy.validateBaseURL(s.remoteUrl)
                newSession = RemoteStreamSession(
                    baseURL: base,
                    options: .init(token: settings.remoteToken, model: s.model, language: s.language, vocabularyHints: hints),
                    timeoutSeconds: s.remoteTimeoutSeconds)
                placement = .remoteHost
            } catch {
                fail(error.localizedDescription)
                return
            }
        } else {
            if !models.engineState.isReady && !models.engineState.isBusy { models.use(s.model) }
            newSession = s.showTextWhileSpeaking ? liveSession(options: options) : LocalBatchSession(engine: models.engine, options: options)
            placement = .neuralEngine
        }

        let front = NSWorkspace.shared.frontmostApplication
        targetApp = front?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : front
        startedInWindow = targetApp == nil ? NSApp.keyWindow?.identifier : nil
        editWatcher?.prime(targetApp)
        do {
            try capture.start(deviceName: s.audioDevice, maxSeconds: s.maxRecordingSeconds) { [newSession] chunk in
                newSession.append(chunk)
            }
        } catch {
            newSession.cancel()
            fail("Couldn't start the microphone: \(error.localizedDescription)")
            return
        }
        session = newSession
        self.trigger = trigger
        resetTask?.cancel()
        phase = .listening(since: Date())
        hotkeys?.setCancelEnabled(true)
        Sounds.play(.start, enabled: s.interactionSounds)
        let limit = s.maxRecordingSeconds
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(limit))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    func cancel() {
        guard phase.isActive else { return }
        watchdog?.cancel()
        if capture.isRunning { capture.stop() }
        session?.cancel()
        session = nil
        hotkeys?.setCancelEnabled(false)
        phase = .idle
    }

    func stop() {
        guard phase.isListening, let session else { return }
        watchdog?.cancel()
        hotkeys?.setCancelEnabled(false)
        let released = ContinuousClock.now
        let samples = capture.stop()
        let s = settings.settings
        Sounds.play(.stop, enabled: s.interactionSounds)
        let stats = AudioStats(samples: samples, sampleRate: AudioCapture.sampleRate)
        switch RecordingGate.evaluate(stats) {
        case .tooShort:
            session.cancel()
            self.session = nil
            fail("Too short — hold the shortcut while you speak", quiet: true)
            return
        case .silent:
            session.cancel()
            self.session = nil
            fail("No speech detected")
            return
        case .accept:
            break
        }
        phase = .transcribing
        let target = targetApp
        let placement = self.placement
        // The field the dictation goes into, read while the speech is transcribed.
        let fieldRead = editWatcher?.prepare(for: target)
        Task { [weak self] in
            guard let self else { return }
            do {
                if placement == .neuralEngine { try await self.waitForEngine() }
                let output = try await session.finish(allSamples: samples)
                let transcribed = ContinuousClock.now
                let text = await self.postProcessor.process(
                    output.text, context: PostProcessContext(appBundleID: target?.bundleIdentifier, vocabulary: s.vocabularyHints,
                                                             corrections: s.transcriptCorrections, speechModel: s.speechModelID))
                guard !text.isEmpty else {
                    fieldRead?.cancel()
                    self.fail("No speech detected")
                    return
                }
                let pasteStarted = ContinuousClock.now
                let delivery = await self.deliver(text, settings: s, target: target)
                let total = Int((ContinuousClock.now - released) / .milliseconds(1))
                let transcribeMs = Int((transcribed - released) / .milliseconds(1))
                let now = Date()
                let item = TranscriptHistoryItem(
                    id: "transcript-\(Int64(now.timeIntervalSince1970 * 1000))",
                    createdAt: Int64(now.timeIntervalSince1970 * 1000), text: text, backend: output.backend,
                    location: placement == .remoteHost ? "remote-host" : "local", durationSeconds: stats.durationSeconds,
                    timings: DictationTimings(transcribeMs: transcribeMs, speechModelMs: output.modelMs, totalMs: total),
                    model: output.model, appName: target?.localizedName, appBundleId: target?.bundleIdentifier)
                self.history.add(item)
                let captureID = self.training?.keep(samples: samples, rawText: output.text, finalText: text, model: output.model,
                                                    appBundleID: target?.bundleIdentifier)
                if case .pasted = delivery, let fieldRead {
                    self.editWatcher?.arm(await fieldRead.value, insertedAfter: pasteStarted,
                                          dictation: .init(inserted: text, raw: output.text, speechModel: s.speechModelID,
                                                           captureID: captureID))
                }
                let result = Result(text: text, words: WordCounter.count(text), delivery: delivery, latencyMs: total, placement: placement)
                if delivery == .shownInApp { self.lastInAppResult = result }
                self.session = nil
                self.phase = .done(result)
                Self.log.info("Dictation \(stats.durationSeconds, format: .fixed(precision: 1)) s → \(total) ms (model \(output.modelMs) ms)")
                // "It's on the clipboard, press ⌘V" needs time to read; "Inserted" does not.
                if case .copied = delivery {
                    self.scheduleReset(after: .seconds(4))
                } else {
                    self.scheduleReset(after: .milliseconds(1600))
                }
            } catch {
                // The engine never became ready: stop the session's live decoding too.
                session.cancel()
                self.session = nil
                Self.log.error("Transcription failed: \(error.localizedDescription, privacy: .public)")
                self.fail(error.localizedDescription)
            }
        }
    }

    // MARK: Helpers

    private func liveSession(options: TranscriptionRequestOptions) -> any TranscriptionSession {
        liveGeneration += 1
        let generation = liveGeneration
        return LiveTranscriptionSession(engine: models.engine, options: options) { [weak self] text in
            Task { @MainActor in
                guard let self, self.liveGeneration == generation, self.phase.isActive else { return }
                self.liveText = text
            }
        }
    }

    private func deliver(_ text: String, settings s: AppSettings, target: NSRunningApplication?) async -> Delivery {
        // Our own window is frontmost (dashboard "Try dictation", onboarding): show it there.
        if target == nil || (NSApp.isActive && NSApp.keyWindow != nil) {
            TextInserter.copy(text)
            return .shownInApp
        }
        switch await TextInserter.deliver(text, paste: s.insertAtCursor, restoreClipboard: s.restoreClipboard,
                                          expectedApp: target?.processIdentifier) {
        case .pasted: return .pasted(app: target?.localizedName)
        case .copied(let reason): return .copied(reason)
        }
    }

    private func waitForEngine() async throws {
        let deadline = ContinuousClock.now + .seconds(180)
        while !models.engineState.isReady {
            if case .failed(let message) = models.engineState { throw NSError(domain: "engine", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
            if ContinuousClock.now > deadline { throw NSError(domain: "engine", code: 2, userInfo: [NSLocalizedDescriptionKey: "The speech model is still loading"]) }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func fail(_ message: String, quiet: Bool = false) {
        phase = .failed(message)
        if !quiet { Sounds.play(.error, enabled: settings.settings.interactionSounds) }
        scheduleReset(after: .milliseconds(quiet ? 1300 : 2600))
    }

    private func scheduleReset(after delay: Duration) {
        resetTask?.cancel()
        let snapshot = phase
        resetTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.phase == snapshot else { return }
            self.phase = .idle
        }
    }

    // MARK: Demo/screenshot support

    /// Screenshots: forgets the in-app result (a first use).
    func showcaseClearResult() { lastInAppResult = nil }

    func showcase(_ phase: Phase, inAppResult: Result? = nil, liveText: String = "", trigger: Trigger = .hotkey) {
        resetTask?.cancel()
        self.trigger = trigger
        self.phase = phase
        self.liveText = liveText
        if let inAppResult { lastInAppResult = inAppResult }
    }
}
