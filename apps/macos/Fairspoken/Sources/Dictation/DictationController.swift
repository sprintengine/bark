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
    typealias Trigger = DictationTrigger

    enum Delivery: Equatable {
        case pasted(app: String?)
        case copied(String)
        case shownInApp
        /// A dictation kept after a failure, transcribed later: in Recent, and copied if asked.
        case recovered(copied: Bool)

        var isRecovered: Bool { if case .recovered = self { true } else { false } }

        var label: String {
            switch self {
            case .pasted: "pasted"
            case .copied: "copied"
            case .shownInApp: "shown in Bark"
            case .recovered: "recovered"
            }
        }
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

        /// For the log: the stage, never the words.
        var label: String {
            switch self {
            case .idle: "idle"
            case .listening: "listening"
            case .transcribing: "transcribing"
            case .done(let result): "done (\(result.delivery.label))"
            case .failed: "failed"
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
            if phase.isActive != oldValue.isActive, !showcasing {
                // Escape cancels while listening and while transcribing; never steal it otherwise.
                hotkeys?.setCancelEnabled(phase.isActive)
            }
            if oldValue.isListening, !phase.isListening { hotkeys?.stopWatchingShortcutHold() }
            if phase.isActive || oldValue.isActive, !showcasing {
                Self.log.notice("Dictation \(self.lifecycle.id): \(oldValue.label, privacy: .public) → \(self.phase.label, privacy: .public) (\(self.lifecycle.stage.label, privacy: .public), started by \(self.trigger.rawValue, privacy: .public))")
            }
            onPhaseChange?(phase)
        }
    }
    /// The words so far while listening (local transcription with "Show text while speaking").
    private(set) var liveText = ""
    /// Latest transcript produced while our own window was frontmost ("Try dictation").
    private(set) var lastInAppResult: Result?
    /// What `.transcribing` is doing when it isn't the first attempt ("Retrying the host (1 of 2)").
    private(set) var transcribingNote: String?

    @ObservationIgnored var onPhaseChange: ((Phase) -> Void)?
    @ObservationIgnored var onNeedsOnboarding: (() -> Void)?
    /// Called as any recording starts (shortcut, fn, the menu bar, a button), before it takes the
    /// microphone: the setup guide's test steps aside.
    @ObservationIgnored var onWillStart: (() -> Void)?
    @ObservationIgnored let capture = AudioCapture()
    /// Which dictation is current, its stage, and its session while it is listening. A late
    /// finish from an earlier dictation checks its id here and changes nothing.
    @ObservationIgnored private var lifecycle = DictationLifecycle<any TranscriptionSession>()
    /// The current dictation's transcription, and its id (cancelled by Escape or the deadline).
    @ObservationIgnored private var transcription: (id: Int, pendingID: String, task: Task<Void, Never>)?
    /// Gives up on a dictation that has been transcribing too long (`transcribingDeadline`).
    @ObservationIgnored private var deadline: Task<Void, Never>?
    /// The screen locked or the Mac went to sleep during this dictation: copy it, never paste.
    @ObservationIgnored private var copyOnly: (id: Int, reason: String)?
    @ObservationIgnored private var systemObservers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    /// Screenshots: phases are set for show, so Escape isn't registered and nothing is logged.
    @ObservationIgnored private var showcasing = false
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
        capture.onConfigurationChange = { [weak self] in
            Task { @MainActor [weak self] in self?.endForSystemEvent("the audio input changed", copyReason: nil) }
        }
        observeSystemEvents()
    }

    // MARK: Triggers

    /// Combo key-down. Toggle mode toggles; push-to-talk starts. Either way it stops a recording
    /// Fn or a button started.
    func hotkeyPressed() { handle(.shortcutDown) }
    func hotkeyReleased() { handle(.shortcutUp) }
    func fnPressed() { handle(.fnDown) }
    func fnReleased() { handle(.fnUp) }
    /// Home, the setup guide, the menu bar and the speed test's buttons.
    func toggleFromUI() { handle(.button) }

    /// While listening, any trigger stops the recording, whichever started it
    /// (`DictationLifecycle.action`).
    private func handle(_ event: DictationTriggerEvent) {
        switch lifecycle.action(for: event, shortcutMode: settings.settings.recordingShortcutMode) {
        case .start(let trigger):
            start(trigger)
        case .stop:
            if let started = lifecycle.listeningTrigger, event != Self.ownStop(for: started, mode: settings.settings.recordingShortcutMode) {
                Self.log.notice("Dictation \(self.lifecycle.id): \(event.rawValue, privacy: .public) stops a recording started by \(started.rawValue, privacy: .public)")
            }
            stop()
        case .ignore:
            break
        }
    }

    /// The event that ordinarily ends a recording `trigger` started (for the log).
    private static func ownStop(for trigger: Trigger, mode: RecordingShortcutMode) -> DictationTriggerEvent {
        switch trigger {
        case .hotkey: mode == .pushToTalk ? .shortcutUp : .shortcutDown
        case .fn: .fnUp
        case .button: .button
        }
    }

    /// Sleep, the screen locking, the session switching away, or the microphone going: a
    /// recording that is listening ends now and is transcribed. After sleep, a lock or a switch
    /// the dictation (listening or transcribing) is copied rather than pasted, as nothing should
    /// be typed into the lock screen or into whatever is in front on return.
    private func endForSystemEvent(_ what: String, copyReason: String?) {
        guard lifecycle.isActive else { return }
        // Still transcribing: it lands later, perhaps after unlocking, and is copied, not pasted.
        if let copyReason, !lifecycle.isDelivering { copyOnly = (lifecycle.id, copyReason) }
        guard lifecycle.isListening else { return }
        Self.log.notice("Dictation \(self.lifecycle.id): \(what, privacy: .public); ending the recording")
        stop()
    }

    private func observeSystemEvents() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let events: [(NotificationCenter, Notification.Name, String, String)] = [
            (workspace, NSWorkspace.willSleepNotification, "the Mac is going to sleep", "Copied — the Mac went to sleep"),
            (workspace, NSWorkspace.sessionDidResignActiveNotification, "the user session switched away", "Copied — you switched user"),
            (distributed, Notification.Name("com.apple.screenIsLocked"), "the screen locked", "Copied — the screen was locked"),
        ]
        for (center, name, what, reason) in events {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.endForSystemEvent(what, copyReason: reason) }
            }
            systemObservers.append((center, token))
        }
    }

    // MARK: Lifecycle

    func start(_ trigger: Trigger) {
        guard !lifecycle.isActive, !phase.isActive else { return }
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
        let id = lifecycle.begin(trigger, session: newSession)
        kept = (item, writer)
        copyOnly = nil
        self.trigger = trigger
        resetTask?.cancel()
        phase = .listening(since: Date())
        Sounds.play(.start, enabled: s.interactionSounds)
        startWatchdog(id, limit: s.maxRecordingSeconds)
        if trigger == .hotkey, s.recordingShortcutMode == .pushToTalk {
            hotkeys?.watchShortcutHold { [weak self] in self?.hotkeyReleased() }
        }
    }

    /// The recording's length limit: a hard end that stops dictation `id` if it is still
    /// listening, whatever state the rest of the controller is in.
    private func startWatchdog(_ id: Int, limit: Int) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(limit))
            guard !Task.isCancelled, let self, self.lifecycle.id == id, self.lifecycle.isListening else { return }
            Self.log.notice("Dictation \(id) reached the \(limit) s limit; stopping it")
            self.stop()
            if self.lifecycle.id == id, self.lifecycle.isListening {
                Self.log.fault("Dictation \(id) was still listening after the limit's stop; cancelling it")
                self.cancel()
            }
        }
    }

    /// Escape: ends the current dictation at any stage. While listening the recording is
    /// discarded. While transcribing the transcript is dropped when it lands, and the recording
    /// stays on disk to retry (Home lists it).
    func cancel() {
        if lifecycle.isDelivering {
            Self.log.notice("Dictation \(self.lifecycle.id): cancel while it was being pasted; too late")
            return
        }
        guard case let (id, stage, session)? = lifecycle.cancel() else {
            // Nothing is current; make sure nothing is left running either.
            if phase.isActive {
                Self.log.fault("Phase \(self.phase.label, privacy: .public) with no current dictation; resetting")
                if capture.isRunning { capture.stop() }
                phase = .idle
            }
            return
        }
        Self.log.notice("Dictation \(id) cancelled while \(stage.label, privacy: .public)")
        // Its recording is on disk and being transcribed (not a measured one, nor a stop that
        // went wrong before it got that far): it stays there to retry.
        let keptToRetry = stage == .transcribing && measuredHandler == nil && transcription?.id == id
        if let handler = measuredHandler {
            measuredHandler = nil
            measuredRun += 1
            measuredTask?.cancel()
            measuredTask = nil
            isMeasuring = false
            handler(.cancelled)
        }
        watchdog?.cancel()
        deadline?.cancel()
        if capture.isRunning { capture.stop() }
        session?.cancel()
        // Still listening: the recording is thrown away. Once transcribing it is on disk already.
        if let kept { pending.drop(kept.item.id, writer: kept.writer) }
        kept = nil
        if let transcription, transcription.id == id {
            transcription.task.cancel()
            if keptToRetry { keepToRetry(transcription.pendingID, because: "Cancelled while it was being transcribed") }
        }
        transcription = nil
        transcribingNote = nil
        if keptToRetry {
            fail("Cancelled — saved to retry", quiet: true)
        } else {
            phase = .idle
        }
    }

    func stop() {
        if measuredHandler != nil {
            stopMeasured()
            return
        }
        // Not listening: nothing to stop (transcribing ignores the triggers; Escape cancels).
        guard case let (id, session)? = lifecycle.endListening() else { return }
        watchdog?.cancel()
        let kept = self.kept
        self.kept = nil
        guard let session, let kept else {
            // Never a silent no-op while listening: end it as Escape would.
            Self.log.fault("Dictation \(id) had no \(session == nil ? "session" : "recording", privacy: .public) when it stopped; cancelling it")
            session?.cancel()
            self.kept = kept
            cancel()
            return
        }
        let released = ContinuousClock.now
        let samples = capture.stop()
        let s = settings.settings
        Sounds.play(.stop, enabled: s.interactionSounds)
        let stats = AudioStats(samples: samples, sampleRate: AudioCapture.sampleRate)
        switch RecordingGate.evaluate(stats) {
        case .tooShort:
            session.cancel()
            lifecycle.finish(id)
            pending.drop(kept.item.id, writer: kept.writer)
            fail("Too short — hold the shortcut while you speak", quiet: true)
            return
        case .silent:
            session.cancel()
            lifecycle.finish(id)
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
            Task { @MainActor [weak self] in self?.show(progress, for: id) }
        }
        let deliver: @Sendable (TranscriptionOutput) async -> Bool = { [weak self] output in
            // A retry lands many seconds later, when the field read at release may be out of date.
            await self?.complete(output, id: id, item: item, target: target, samples: samples, settings: s,
                                 durationSeconds: stats.durationSeconds, released: released,
                                 retried: retried.isSet, fieldRead: retried.isSet ? nil : fieldRead) ?? false
        }
        let live: @Sendable () async throws -> TranscriptionOutput = { [weak self] in
            do {
                if placement == .neuralEngine { try await self?.waitForEngine() }
                return try await session.finish(allSamples: samples)
            } catch {
                // The engine never became ready, or the dictation was cancelled: stop the
                // session's live decoding too.
                session.cancel()
                throw error
            }
        }
        let task = Task { [weak self] in
            let outcome = await recovery.run(item.id, live: live, routes: routes, policy: .live(timeoutSeconds: s.remoteTimeoutSeconds),
                                             progress: progress, deliver: deliver)
            guard let self else { return }
            if case .kept(let kept) = outcome {
                Self.log.error("Dictation \(id) not transcribed; recording kept to retry: \(kept.lastError ?? "", privacy: .public)")
                self.pending.reload()
            }
            // Delivered (complete() has finished it already), cancelled, timed out, or a newer
            // dictation is under way: this one must not touch anything now.
            guard self.lifecycle.finish(id) else {
                if case .delivered = outcome {} else {
                    Self.log.notice("Dictation \(id) finished after it was ended; nothing changed")
                }
                return
            }
            self.endTranscribing(id)
            switch outcome {
            case .delivered:
                break
            case .noSpeech:
                self.fail("No speech detected")
            case .kept:
                self.fail("Couldn't transcribe — saved to retry", hold: .seconds(5))
            }
        }
        transcription = (id, item.id, task)
        startDeadline(id, recordingSeconds: stats.durationSeconds)
    }

    /// Gives up on dictation `id` if it is still transcribing at the deadline: the recording is
    /// kept to retry, and the pill says so.
    private func startDeadline(_ id: Int, recordingSeconds: Double) {
        let s = settings.settings
        let limit = DictationLifecycle<any TranscriptionSession>.transcribingDeadline(
            recordingSeconds: recordingSeconds, engineReady: models.engineState.isReady,
            remoteTimeoutSeconds: placement == .remoteHost ? s.remoteTimeoutSeconds : nil)
        deadline?.cancel()
        deadline = Task { [weak self] in
            // Time asleep doesn't count: a dictation the Mac slept through isn't late.
            try? await Task.sleep(for: limit, clock: .suspending)
            guard !Task.isCancelled, let self, self.lifecycle.isTranscribing(id), self.lifecycle.finish(id) else { return }
            Self.log.error("Dictation \(id) was still transcribing after \(limit, privacy: .public); giving up")
            let measured = self.measuredHandler
            if let transcription = self.transcription, transcription.id == id {
                transcription.task.cancel()
                self.keepToRetry(transcription.pendingID, because: "Took too long to transcribe")
            }
            self.measuredTask?.cancel()
            self.endTranscribing(id)
            if let measured {
                self.measuredRun += 1
                self.measuredHandler = nil
                self.isMeasuring = false
                self.phase = .idle
                measured(.failed("Transcribing took too long."))
            } else {
                self.fail("Took too long — saved to retry", hold: .seconds(5))
            }
        }
    }

    /// A dictation given up on while transcribing goes to Home's list to retry now, rather than
    /// once its cancelled transcription returns (which an engine call may take a while to do).
    /// That run, when it does return, never delivers and only marks it failed again.
    private func keepToRetry(_ pendingID: String, because reason: String) {
        pending.store.update(pendingID) {
            $0.state = .failed
            $0.attempts += 1
            $0.lastError = reason
            $0.lastAttemptAt = Int64(Date().timeIntervalSince1970 * 1000)
        }
        pending.reload()
    }

    /// Dictation `id`, which has just been finished in `lifecycle`, lets go of what it held.
    private func endTranscribing(_ id: Int) {
        if transcription?.id == id { transcription = nil }
        deadline?.cancel()
        deadline = nil
        transcribingNote = nil
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
        let id = lifecycle.begin(trigger, session: newSession)
        kept = nil
        measuredHandler = handler
        isMeasuring = true
        self.trigger = trigger
        resetTask?.cancel()
        phase = .listening(since: Date())
        Sounds.play(.start, enabled: s.interactionSounds)
        startWatchdog(id, limit: s.maxRecordingSeconds)
    }

    /// Ends a measured recording: the same gate and transcription as a dictation, then the
    /// transcript goes to the handler and nowhere else. No retries: a failure is reported.
    private func stopMeasured() {
        guard let handler = measuredHandler, case let (id, session)? = lifecycle.endListening() else { return }
        watchdog?.cancel()
        guard let session else {
            Self.log.fault("Measured dictation \(id) had no session when it stopped; cancelling it")
            cancel()
            return
        }
        let released = ContinuousClock.now
        let samples = capture.stop()
        let s = settings.settings
        Sounds.play(.stop, enabled: s.interactionSounds)
        let stats = AudioStats(samples: samples, sampleRate: AudioCapture.sampleRate)
        let verdict = RecordingGate.evaluate(stats)
        guard verdict == .accept else {
            session.cancel()
            lifecycle.finish(id)
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
            // Cancelled while it was transcribing, or it took too long: the test has moved on.
            guard let self, self.measuredRun == run, self.measuredHandler != nil, self.lifecycle.finish(id) else { return }
            self.measuredTask = nil
            self.endTranscribing(id)
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
        startDeadline(id, recordingSeconds: stats.durationSeconds)
    }

    /// The transcript is in: post-process, deliver, record in history (and for post-training),
    /// show the result. False when post-processing left no words, so nothing was delivered.
    private func complete(_ output: TranscriptionOutput, id: Int, item: PendingDictation, target: NSRunningApplication?, samples: [Float],
                          settings s: AppSettings, durationSeconds: Double, released: ContinuousClock.Instant, retried: Bool,
                          fieldRead: Task<EditWatcher.FieldRead?, Never>?) async -> Bool {
        let transcribed = ContinuousClock.now
        // Cancelled or timed out (the recording is kept to retry), or long since replaced by a
        // newer dictation: a transcript that lands now is dropped.
        guard lifecycle.isTranscribing(id), !Task.isCancelled else {
            Self.log.notice("Dictation \(id)'s transcript arrived after it was ended; dropped")
            return false
        }
        transcribingNote = nil
        let text = await postProcessor.process(
            output.text, context: PostProcessContext(appBundleID: item.appBundleId, vocabulary: s.vocabularyHints,
                                                     corrections: s.postProcess ? s.transcriptCorrections : [],
                                                     speechModel: s.speechModelID))
        guard !text.isEmpty else { return false }
        guard lifecycle.isTranscribing(id), !Task.isCancelled else {
            Self.log.notice("Dictation \(id) was ended while its transcript was tidied; dropped")
            return false
        }
        let pasteStarted = ContinuousClock.now
        // The last moment Escape can stop it: from here on it is delivered (`beginDelivering`).
        // Whether it may still be pasted is read then too: the screen may have locked while
        // the keys or the focus were awaited.
        let commit: () -> TextInserter.Commit = { [weak self] in
            guard let self, !Task.isCancelled, self.lifecycle.beginDelivering(id) else { return .withdraw }
            if let copyOnly = self.copyOnly, copyOnly.id == id { return .copyOnly(copyOnly.reason) }
            return .deliver
        }
        guard let delivery = await deliver(text, settings: s, target: target, retried: retried,
                                           copyOnly: copyOnly?.id == id ? copyOnly?.reason : nil, commit: commit) else {
            Self.log.notice("Dictation \(id) was cancelled before it was pasted; nothing was pasted")
            return false
        }
        let total = Int((ContinuousClock.now - released) / .milliseconds(1))
        let transcribeMs = Int((transcribed - released) / .milliseconds(1))
        let now = Date()
        let entry = TranscriptHistoryItem(
            id: "transcript-\(Int64(now.timeIntervalSince1970 * 1000))",
            createdAt: Int64(now.timeIntervalSince1970 * 1000), text: text, backend: output.backend,
            location: output.placement == .remoteHost ? "remote-host" : "local", durationSeconds: durationSeconds,
            timings: DictationTimings(transcribeMs: transcribeMs, speechModelMs: output.modelMs, totalMs: total),
            model: output.model, appName: item.appName, appBundleId: item.appBundleId)
        history.add(entry)
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
        // Delivered either way; but if it was cancelled while pasting (or a newer dictation has
        // begun since), what the pill shows belongs to that now.
        guard lifecycle.finish(id) else {
            Self.log.notice("Dictation \(id) was delivered after it was ended; the pill is left alone")
            return true
        }
        endTranscribing(id)
        phase = .done(result)
        Self.log.notice("Dictation \(durationSeconds, format: .fixed(precision: 1)) s → \(total) ms (model \(output.modelMs) ms)")
        // "It's on the clipboard, press ⌘V" needs time to read; "Inserted" does not.
        if case .copied = delivery {
            scheduleReset(after: .seconds(4))
        } else {
            scheduleReset(after: .milliseconds(1600))
        }
        return true
    }

    private func show(_ progress: DictationRecovery.Progress, for id: Int) {
        guard lifecycle.isTranscribing(id), phase == .transcribing else { return }
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

    /// Nil when the dictation was cancelled before anything was written or pasted. `copyOnly`
    /// says why it must not be pasted, if it mustn't.
    private func deliver(_ text: String, settings s: AppSettings, target: NSRunningApplication?, retried: Bool, copyOnly: String?,
                         commit: () -> TextInserter.Commit) async -> Delivery? {
        // The screen locked, the Mac slept or the user switched: nothing is typed anywhere.
        if let copyOnly {
            guard case .withdraw = commit() else {
                TextInserter.copy(text)
                return .copied(copyOnly)
            }
            return nil
        }
        // Our own window is frontmost (dashboard "Try dictation", onboarding): show it there.
        if target == nil || (NSApp.isActive && NSApp.keyWindow != nil) {
            if case .withdraw = commit() { return nil }
            TextInserter.copy(text)
            return .shownInApp
        }
        // A retry can take many seconds: if the user has moved on to another app by then, never
        // type into it. (A first attempt is pasted, keeping the text on the clipboard, as before.)
        if retried, NSWorkspace.shared.frontmostApplication?.processIdentifier != target?.processIdentifier {
            if case .withdraw = commit() { return nil }
            TextInserter.copy(text)
            return .copied("Copied — you'd switched apps")
        }
        switch await TextInserter.deliver(text, paste: s.insertAtCursor, restoreClipboard: s.restoreClipboard,
                                          expectedApp: target?.processIdentifier, commit: commit) {
        case .pasted: return .pasted(app: target?.localizedName)
        case .copied(let reason): return .copied(reason)
        case .withdrawn: return nil
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
        showcasing = true
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
