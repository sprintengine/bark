import AppKit
import AVFoundation
import FairspokenCore
import Observation
import OSLog
import Synchronization

/// The dictation state machine: hotkey/button → capture → (gate) → transcribe → post-process
/// → deliver (paste into the frontmost app, or show in our own window) → history
/// (→ kept for post-training, when that is on).
///
/// The recording is written to disk as it is captured and deleted only once its transcript is
/// delivered (`PendingDictations`). If the host fails, the whole recording is sent again, then
/// transcribed on this Mac; if that fails too it is kept, to be retried later.
@Observable
final class DictationController {
    enum Trigger { case hotkey, fn, button }

    enum Delivery: Equatable {
        case pasted(app: String?)
        case copied(String)
        case shownInApp
        /// A dictation kept after a failure, transcribed later: in Recent, and copied if asked.
        case recovered(copied: Bool)

        var isRecovered: Bool { if case .recovered = self { true } else { false } }
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

    /// A recording the speed test measures: transcribed with the model in use, then handed back
    /// and forgotten. Never inserted, copied, kept in history or lifetime stats, kept on disk to
    /// retry, or saved for post-training.
    struct Measured: Equatable {
        var text: String
        /// The recording's length, from its samples.
        var recordingSeconds: Double
        /// From release to transcript.
        var transcribeMs: Int
        var model: String
        var placement: ComputePlacement
    }

    enum MeasuredOutcome: Equatable {
        case captured(Measured)
        case failed(String)
        case cancelled
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
    /// The history entry of the last dictation shown in Bark's own window.
    private(set) var lastInAppHistoryID: String?
    /// What `.transcribing` is doing when it isn't the first attempt ("Retrying the host (1 of 2)").
    private(set) var transcribingNote: String?

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
    /// While set, a recording started in the speed test's own window (`measuredWindow`: the
    /// shortcut, Fn or its button) is measured rather than delivered, and its outcome comes here.
    /// A recording started anywhere else (another app, the setup guide) is an ordinary dictation.
    @ObservationIgnored var measure: ((MeasuredOutcome) -> Void)?
    static let measuredWindow = NSUserInterfaceItemIdentifier("speed-test")
    @ObservationIgnored private var measuredTask: Task<Void, Never>?
    /// The current recording is a measured one.
    private(set) var isMeasuring = false
    @ObservationIgnored private var measuredHandler: ((MeasuredOutcome) -> Void)?
    /// Bumped when a measured recording is cancelled, so its transcription, still running, is dropped.
    @ObservationIgnored private var measuredRun = 0
    /// What started the current recording (a held key's release ends only its own recording).
    @ObservationIgnored private(set) var trigger: Trigger = .button
    @ObservationIgnored private var targetApp: NSRunningApplication?
    @ObservationIgnored private var placement: ComputePlacement = .neuralEngine
    @ObservationIgnored private var liveGeneration = 0
    /// The recording being captured, and the writer putting it on disk.
    @ObservationIgnored private var kept: (item: PendingDictation, writer: PendingAudioWriter?)?
    @ObservationIgnored private let postProcessor: any TranscriptPostProcessor = BasicPostProcessor()

    private let settings: SettingsStore
    private let models: ModelLibrary
    private let history: HistoryStore
    private let permissions: Permissions
    private let pending: PendingDictations
    @ObservationIgnored var hotkeys: HotkeyController?
    /// Learns from the user fixing a dictation in place (`learnFromEdits`).
    @ObservationIgnored var editWatcher: EditWatcher?
    private static let log = Logger(subsystem: AppInfo.bundleID, category: "dictation")

    var meter: LevelMeter { capture.meter }

    init(settings: SettingsStore, models: ModelLibrary, history: HistoryStore, permissions: Permissions, pending: PendingDictations) {
        self.settings = settings
        self.models = models
        self.history = history
        self.permissions = permissions
        self.pending = pending
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
        if targetApp == nil, startedInWindow == Self.measuredWindow, let measure {
            startMeasured(session: newSession, settings: s, trigger: trigger, handler: measure)
            return
        }
        editWatcher?.prime(targetApp)
        let now = Date()
        let item = PendingDictation(id: "dictation-\(Int64(now.timeIntervalSince1970 * 1000))", createdAt: now,
                                    appName: targetApp?.localizedName, appBundleId: targetApp?.bundleIdentifier)
        let writer = pending.begin(item)
        do {
            try capture.start(deviceName: s.audioDevice, maxSeconds: s.maxRecordingSeconds) { [newSession, writer] chunk in
                newSession.append(chunk)
                writer?.append(chunk)
            }
        } catch {
            newSession.cancel()
            pending.drop(item.id, writer: writer)
            fail("Couldn't start the microphone: \(error.localizedDescription)")
            return
        }
        session = newSession
        kept = (item, writer)
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
        if let handler = measuredHandler {
            measuredHandler = nil
            measuredRun += 1
            measuredTask?.cancel()
            measuredTask = nil
            isMeasuring = false
            handler(.cancelled)
        }
        watchdog?.cancel()
        if capture.isRunning { capture.stop() }
        session?.cancel()
        session = nil
        if let kept { pending.drop(kept.item.id, writer: kept.writer) }
        kept = nil
        hotkeys?.setCancelEnabled(false)
        phase = .idle
    }

    func stop() {
        if measuredHandler != nil {
            stopMeasured()
            return
        }
        guard phase.isListening, let session, let kept else { return }
        watchdog?.cancel()
        hotkeys?.setCancelEnabled(false)
        self.kept = nil
        let released = ContinuousClock.now
        let samples = capture.stop()
        let s = settings.settings
        Sounds.play(.stop, enabled: s.interactionSounds)
        let stats = AudioStats(samples: samples, sampleRate: AudioCapture.sampleRate)
        switch RecordingGate.evaluate(stats) {
        case .tooShort:
            session.cancel()
            self.session = nil
            pending.drop(kept.item.id, writer: kept.writer)
            fail("Too short — hold the shortcut while you speak", quiet: true)
            return
        case .silent:
            session.cancel()
            self.session = nil
            pending.drop(kept.item.id, writer: kept.writer)
            fail("No speech detected")
            return
        case .accept:
            break
        }
        // All of it on disk before anything can fail; deleted once the transcript is delivered.
        pending.keep(kept.item, writer: kept.writer, samples: samples, durationSeconds: stats.durationSeconds)
        phase = .transcribing
        transcribingNote = nil
        let item = kept.item
        let target = targetApp
        let placement = self.placement
        // The field the dictation goes into, read while the speech is transcribed.
        let fieldRead = editWatcher?.prepare(for: target)
        // After the live attempt: the whole recording to the host again, then this Mac.
        let routes = placement == .remoteHost ? pending.routes(for: s) : TranscriptionRoutes()
        let recovery = pending.recovery
        // Set once the live attempt has failed: the transcript then comes from a retry, later.
        let retried = RetryFlag()
        let progress: @Sendable (DictationRecovery.Progress) -> Void = { [weak self] progress in
            retried.set()
            Task { @MainActor [weak self] in self?.show(progress) }
        }
        let deliver: @Sendable (TranscriptionOutput) async -> Bool = { [weak self] output in
            // A retry lands many seconds later, when the field read at release may be out of date.
            await self?.complete(output, item: item, target: target, samples: samples, settings: s,
                                 durationSeconds: stats.durationSeconds, released: released,
                                 retried: retried.isSet, fieldRead: retried.isSet ? nil : fieldRead) ?? false
        }
        let live: @Sendable () async throws -> TranscriptionOutput = { [weak self] in
            do {
                if placement == .neuralEngine { try await self?.waitForEngine() }
                return try await session.finish(allSamples: samples)
            } catch {
                // The engine never became ready: stop the session's live decoding too.
                session.cancel()
                throw error
            }
        }
        Task { [weak self] in
            let outcome = await recovery.run(item.id, live: live, routes: routes, policy: .live(timeoutSeconds: s.remoteTimeoutSeconds),
                                             progress: progress, deliver: deliver)
            guard let self else { return }
            self.session = nil
            self.transcribingNote = nil
            switch outcome {
            case .delivered:
                break
            case .noSpeech:
                self.fail("No speech detected")
            case .kept(let kept):
                Self.log.error("Transcription failed; recording kept to retry: \(kept.lastError ?? "", privacy: .public)")
                self.pending.reload()
                self.fail("Couldn't transcribe — saved to retry", hold: .seconds(5))
            }
        }
    }

    // MARK: Measured recordings (the speed test)

    /// The same capture and session as a dictation, with nothing kept: no file to retry from, no
    /// target app, no edit watching.
    private func startMeasured(session newSession: any TranscriptionSession, settings s: AppSettings, trigger: Trigger,
                               handler: @escaping (MeasuredOutcome) -> Void) {
        do {
            try capture.start(deviceName: s.audioDevice, maxSeconds: s.maxRecordingSeconds) { [newSession] chunk in
                newSession.append(chunk)
            }
        } catch {
            // The test says what went wrong; no pill as well.
            newSession.cancel()
            handler(.failed("Couldn't start the microphone: \(error.localizedDescription)"))
            return
        }
        session = newSession
        kept = nil
        measuredHandler = handler
        isMeasuring = true
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

    /// Ends a measured recording: the same gate and transcription as a dictation, then the
    /// transcript goes to the handler and nowhere else. No retries: a failure is reported.
    private func stopMeasured() {
        guard phase.isListening, let session, let handler = measuredHandler else { return }
        watchdog?.cancel()
        hotkeys?.setCancelEnabled(false)
        let released = ContinuousClock.now
        let samples = capture.stop()
        let s = settings.settings
        Sounds.play(.stop, enabled: s.interactionSounds)
        let stats = AudioStats(samples: samples, sampleRate: AudioCapture.sampleRate)
        let verdict = RecordingGate.evaluate(stats)
        guard verdict == .accept else {
            session.cancel()
            self.session = nil
            measuredHandler = nil
            isMeasuring = false
            phase = .idle
            handler(.failed(verdict == .tooShort ? "That was too short to measure." : "No speech was heard. Check the microphone."))
            return
        }
        phase = .transcribing
        transcribingNote = nil
        let placement = self.placement
        let run = measuredRun
        measuredTask = Task { [weak self] in
            let result: Swift.Result<TranscriptionOutput, Error>
            do {
                if placement == .neuralEngine { try await self?.waitForEngine() }
                // Cancelled while the model loaded: never start decoding.
                guard !Task.isCancelled, self?.measuredRun == run else { return }
                result = .success(try await session.finish(allSamples: samples))
            } catch {
                session.cancel()
                result = .failure(error)
            }
            // Cancelled while it was transcribing: the test has moved on.
            guard let self, self.measuredRun == run, self.measuredHandler != nil else { return }
            self.measuredTask = nil
            self.session = nil
            self.measuredHandler = nil
            self.isMeasuring = false
            self.phase = .idle
            switch result {
            case .success(let output):
                let ms = Int((ContinuousClock.now - released) / .milliseconds(1))
                handler(.captured(Measured(text: output.text, recordingSeconds: stats.durationSeconds, transcribeMs: ms,
                                           model: output.model, placement: output.placement)))
            case .failure(let error):
                handler(.failed(error.localizedDescription))
            }
        }
    }

    /// The transcript is in: post-process, deliver, record in history (and for post-training),
    /// show the result. False when post-processing left no words, so nothing was delivered.
    private func complete(_ output: TranscriptionOutput, item: PendingDictation, target: NSRunningApplication?, samples: [Float],
                          settings s: AppSettings, durationSeconds: Double, released: ContinuousClock.Instant, retried: Bool,
                          fieldRead: Task<EditWatcher.FieldRead?, Never>?) async -> Bool {
        let transcribed = ContinuousClock.now
        transcribingNote = nil
        let text = await postProcessor.process(
            output.text, context: PostProcessContext(appBundleID: item.appBundleId, vocabulary: s.vocabularyHints,
                                                     corrections: s.postProcess ? s.transcriptCorrections : [],
                                                     speechModel: s.speechModelID))
        guard !text.isEmpty else { return false }
        let pasteStarted = ContinuousClock.now
        let delivery = await deliver(text, settings: s, target: target, retried: retried)
        let total = Int((ContinuousClock.now - released) / .milliseconds(1))
        let transcribeMs = Int((transcribed - released) / .milliseconds(1))
        let now = Date()
        var entry = TranscriptHistoryItem(
            id: "transcript-\(Int64(now.timeIntervalSince1970 * 1000))",
            createdAt: Int64(now.timeIntervalSince1970 * 1000), text: text, backend: output.backend,
            location: output.placement == .remoteHost ? "remote-host" : "local", durationSeconds: durationSeconds,
            timings: DictationTimings(transcribeMs: transcribeMs, speechModelMs: output.modelMs, totalMs: total),
            model: output.model, appName: item.appName, appBundleId: item.appBundleId)
        // What the model heard, for the dictation view's bubble and diff.
        entry.rawText = output.text
        // Dictated into Bark's own window (Home's composer): a note.
        if delivery == .shownInApp { entry.isNote = true }
        if case .copied = delivery { entry.clipboardOnly = true }
        history.add(entry)
        if delivery == .shownInApp { lastInAppHistoryID = entry.id }
        // The recording already on disk moves to the post-training folder; nothing is written twice.
        let captureID = pending.keepForTraining(item.id, samples: samples, rawText: output.text, finalText: text, model: output.model,
                                                appBundleID: item.appBundleId)
        if case .pasted = delivery, let fieldRead, let editWatcher {
            let dictation = EditWatcher.Dictation(inserted: text, raw: output.text, speechModel: s.speechModelID, captureID: captureID)
            // Apart, so a read still running never holds up the result.
            Task { editWatcher.arm(await fieldRead.value, insertedAfter: pasteStarted, dictation: dictation) }
        }
        let result = Result(text: text, words: WordCounter.count(text), delivery: delivery, latencyMs: total, placement: output.placement)
        if delivery == .shownInApp { lastInAppResult = result }
        phase = .done(result)
        Self.log.info("Dictation \(durationSeconds, format: .fixed(precision: 1)) s → \(total) ms (model \(output.modelMs) ms)")
        // "It's on the clipboard, press ⌘V" needs time to read; "Inserted" does not.
        if case .copied = delivery {
            scheduleReset(after: .seconds(4))
        } else {
            scheduleReset(after: .milliseconds(1600))
        }
        return true
    }

    private func show(_ progress: DictationRecovery.Progress) {
        guard phase == .transcribing else { return }
        switch progress {
        case .retrying(let attempt, let count): transcribingNote = "Retrying the host (\(attempt) of \(count))"
        case .transcribingOnThisMac: transcribingNote = "Transcribing on this Mac"
        }
    }

    /// A dictation kept after a failure was transcribed later: say so when the pill is free.
    func announceRecovered(words: Int, copied: Bool, placement: ComputePlacement) {
        guard phase == .idle else { return }
        phase = .done(Result(text: "", words: words, delivery: .recovered(copied: copied), latencyMs: 0, placement: placement))
        scheduleReset(after: .milliseconds(3000))
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

    private func deliver(_ text: String, settings s: AppSettings, target: NSRunningApplication?, retried: Bool) async -> Delivery {
        // Our own window is frontmost (dashboard "Try dictation", onboarding): show it there.
        if target == nil || (NSApp.isActive && NSApp.keyWindow != nil) {
            TextInserter.copy(text)
            return .shownInApp
        }
        // A retry can take many seconds: if the user has moved on to another app by then, never
        // type into it. (A first attempt is pasted, keeping the text on the clipboard, as before.)
        if retried, NSWorkspace.shared.frontmostApplication?.processIdentifier != target?.processIdentifier {
            TextInserter.copy(text)
            return .copied("Copied — you'd switched apps")
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

    private func fail(_ message: String, quiet: Bool = false, hold: Duration? = nil) {
        phase = .failed(message)
        if !quiet { Sounds.play(.error, enabled: settings.settings.interactionSounds) }
        scheduleReset(after: hold ?? .milliseconds(quiet ? 1300 : 2600))
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

    func showcase(_ phase: Phase, inAppResult: Result? = nil, liveText: String = "", trigger: Trigger = .hotkey, measuring: Bool = false) {
        resetTask?.cancel()
        self.trigger = trigger
        isMeasuring = measuring
        self.phase = phase
        self.liveText = liveText
        if let inAppResult { lastInAppResult = inAppResult }
    }
}

/// Whether a dictation's transcript came from a retry rather than the live attempt.
nonisolated private final class RetryFlag: Sendable {
    private let value = Mutex(false)
    func set() { value.withLock { $0 = true } }
    var isSet: Bool { value.withLock { $0 } }
}
