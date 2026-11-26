import AppKit
import FairspokenCore
import FairspokenWhisper
import Observation
import OSLog
import UniformTypeIdentifiers

/// Dictations not transcribed yet. Every recording is written to `Pending Dictations/` in
/// Application Support as it is captured (`PendingDictationStore`) and deleted once its
/// transcript is delivered. One that every attempt failed on stays there: it is retried on its
/// own (at launch, when the host answers again, then at growing intervals) and from Home, where
/// it can also be exported or moved to the Trash. With "Save recordings to improve models" on, a
/// delivered dictation's audio moves on to the post-training folder instead of being written
/// there a second time.
@Observable
final class PendingDictations {
    /// Dictations whose every attempt failed, newest first.
    private(set) var items: [PendingDictation] = []
    /// Ids being retried right now.
    private(set) var retrying: Set<String> = []
    /// A recording the Trash couldn't take (a volume without one), waiting for the user to
    /// confirm deleting it permanently. Nothing has been deleted yet.
    private(set) var needsPermanentDeletion: String?

    /// A kept dictation was transcribed: its word count, and whether it went to the clipboard.
    @ObservationIgnored var onRecovered: ((_ words: Int, _ copied: Bool, _ placement: ComputePlacement) -> Void)?

    @ObservationIgnored let store: PendingDictationStore
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let models: ModelLibrary
    @ObservationIgnored private let history: HistoryStore
    @ObservationIgnored private let training: TrainingLibrary?
    @ObservationIgnored private var loop: Task<Void, Never>?
    private static let log = Logger(subsystem: AppInfo.bundleID, category: "pending")

    init(settings: SettingsStore, models: ModelLibrary, history: HistoryStore, training: TrainingLibrary? = nil,
         directory: URL = AppInfo.isDemo ? FileManager.default.temporaryDirectory.appendingPathComponent("fairspoken-demo-pending")
             : AppInfo.supportDirectory.appendingPathComponent("Pending Dictations", isDirectory: true)) {
        self.settings = settings
        self.models = models
        self.history = history
        self.training = training
        store = PendingDictationStore(directory: directory)
    }

    var recovery: DictationRecovery { DictationRecovery(store: store) }

    /// At launch: what the last run left unfinished joins the list, and the retry loop starts.
    func start() {
        store.clearHandOffs()
        let recovered = store.recoverInterrupted()
        if !recovered.isEmpty { Self.log.info("\(recovered.count) dictation(s) waiting to be transcribed") }
        reload()
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.retryDue()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func reload() {
        items = store.all().filter { $0.state == .failed }.reversed()
    }

    // MARK: Recording

    /// Starts keeping a recording; nil (logged) if the disk refuses, and `keep` then writes it whole.
    func begin(_ item: PendingDictation) -> PendingAudioWriter? {
        do { return try store.begin(item) } catch {
            Self.log.error("Couldn't start keeping the recording: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The recording ended and will be transcribed: make sure all of it is on disk.
    func keep(_ item: PendingDictation, writer: PendingAudioWriter?, samples: [Float], durationSeconds: Double) {
        var item = item
        item.durationSeconds = durationSeconds
        item.state = .transcribing
        do {
            guard let writer else { throw CocoaError(.fileWriteUnknown) }
            try writer.finish()
            try store.save(item)
        } catch {
            do { try store.write(item, samples16k: samples) } catch {
                Self.log.error("Couldn't keep the recording: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// A recording that is not a dictation (cancelled, too short, silent).
    func drop(_ id: String, writer: PendingAudioWriter?) {
        writer?.discard()
        store.remove(id)
    }

    /// A dictation was delivered: with post-training capture on, its recording moves from here to
    /// the post-training folder (or, if it never reached the disk, `samples` are written there).
    /// Call before the pending entry is removed.
    /// Returns the kept recording's id, for the edit watcher to attach the user's edit to.
    @discardableResult
    func keepForTraining(_ id: String, samples: [Float]?, rawText: String, finalText: String, model: String, appBundleID: String?) -> String? {
        guard let training, training.isCapturing else { return nil }
        let duration = WAVFile.durationSeconds(store.audioURL(id))
        if let duration, let file = store.handOff(id) {
            return training.keep(.file(file, durationSeconds: duration), rawText: rawText, finalText: finalText, model: model, appBundleID: appBundleID)
        } else if let samples {
            return training.keep(.samples(samples), rawText: rawText, finalText: finalText, model: model, appBundleID: appBundleID)
        }
        return nil
    }

    // MARK: Retrying

    /// Where a kept dictation can be transcribed now: the host (when one is in use), then this
    /// Mac (when the model is installed).
    func routes(for s: AppSettings) -> TranscriptionRoutes {
        let hints = VocabularyPacks.hints(userTerms: s.vocabularyHints, enabledPacks: s.enabledPacks)
        var routes = TranscriptionRoutes()
        if s.transcriptionLocation == .remoteHost, let base = try? RemoteURLPolicy.validateBaseURL(s.remoteUrl) {
            let client = RemoteBatchClient(baseURL: base, options: .init(token: settings.remoteToken, model: s.model,
                                                                         language: s.language, vocabularyHints: hints))
            routes.remote = { wav, timeout in try await client.transcribe(wav: wav, timeout: timeout) }
        }
        if SpeechModels.isInstalled(s.model) {
            let options = TranscriptionRequestOptions(language: s.language, vocabularyHints: hints)
            routes.local = { [models] samples in try await models.transcribeOnThisMac(samples, model: s.model, options: options) }
        }
        return routes
    }

    /// Every failed dictation whose pause is over (`DictationRetryPolicy.backoff`).
    func retryDue() async {
        for item in store.all() where DictationRetryPolicy.isDue(item) {
            await retry(item.id, manual: false)
        }
    }

    /// Every failed dictation, now (the Retry All button, the host answering again).
    func retryAll(manual: Bool) async {
        for item in store.all() where item.state == .failed {
            await retry(item.id, manual: manual)
        }
    }

    /// One attempt (host, then this Mac). A transcript goes into Recent, and onto the clipboard
    /// when the user asked; never typed into whatever is focused now, as the place it was
    /// dictated into is long gone.
    func retry(_ id: String, manual: Bool) async {
        guard !retrying.contains(id), let item = store.item(id), item.state == .failed else { return }
        let s = settings.settings
        let routes = routes(for: s)
        // Nothing to try with (no host set, no model on this Mac): wait without counting a failure.
        guard routes.remote != nil || routes.local != nil else { return }
        retrying.insert(id)
        defer {
            retrying.remove(id)
            reload()
        }
        let outcome = await recovery.run(id, live: nil, routes: routes, policy: .later(timeoutSeconds: s.remoteTimeoutSeconds)) { [weak self] output in
            await self?.deliver(output, for: item, copy: manual) ?? false
        }
        switch outcome {
        case .delivered(let output):
            Self.log.info("Transcribed a kept dictation (\(item.durationSeconds, format: .fixed(precision: 1)) s) \(output.placement == .remoteHost ? "on the host" : "on this Mac", privacy: .public)")
        case .noSpeech:
            Self.log.info("A kept dictation had no speech; moved to the Trash")
        case .kept(let kept):
            Self.log.error("A kept dictation failed again (\(kept.attempts) tries): \(kept.lastError ?? "", privacy: .public)")
        }
    }

    /// False when post-processing left no words, so nothing was delivered.
    private func deliver(_ output: TranscriptionOutput, for item: PendingDictation, copy: Bool) async -> Bool {
        let s = settings.settings
        // Only the app is known by now: its rule (or Bark's default for it) picks the style.
        let destination = DictationDestination(bundleID: item.appBundleId, appName: item.appName)
        let resolution = s.styleRules.resolve(destination)
        let started = ContinuousClock.now
        let processed = DictationPipeline.process(output.text, context: PostProcessContext(settings: s, appBundleID: item.appBundleId,
                                                                                            resolution: resolution))
        let cleanupMs = Int((ContinuousClock.now - started) / .milliseconds(1))
        let text = processed.plainText
        guard !text.isEmpty else { return false }
        if copy { TextInserter.copy(text, html: processed.html) }
        let recordingID = keepForTraining(item.id, samples: nil, rawText: output.text, finalText: text, model: output.model,
                                          appBundleID: item.appBundleId)
        history.add(TranscriptHistoryItem(
            id: "transcript-\(item.createdAt)", createdAt: item.createdAt, text: text, backend: output.backend,
            location: output.placement == .remoteHost ? "remote-host" : "local", durationSeconds: item.durationSeconds,
            timings: DictationTimings(transcribeMs: output.modelMs, speechModelMs: output.modelMs, totalMs: 0),
            model: output.model, appName: item.appName, appBundleId: item.appBundleId, rawText: output.text,
            cleanupEdits: processed.edits, style: resolution.style.rawValue, styleReason: resolution.reason, cleanupMs: cleanupMs,
            recordingID: recordingID))
        onRecovered?(WordCounter.count(text), copy, output.placement)
        return true
    }

    // MARK: Export and delete

    /// Saves a copy of the recording (WAV) where the user chooses.
    func export(_ id: String) {
        guard let item = store.item(id) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm"
        panel.nameFieldStringValue = "Dictation \(stamp.string(from: item.date)).wav"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            try FileManager.default.copyItem(at: store.audioURL(id), to: url)
        } catch {
            Self.log.error("Exporting a recording failed: \(error.localizedDescription, privacy: .public)")
            NSAlert(error: error).runModal()
        }
    }

    /// Moves the recording to the Trash. When that fails nothing is deleted, and
    /// `needsPermanentDeletion` asks the user first.
    func delete(_ id: String) {
        guard !retrying.contains(id) else { return }
        do {
            try store.trash(id)
        } catch {
            Self.log.error("Moving a recording to the Trash failed: \(error.localizedDescription, privacy: .public)")
            needsPermanentDeletion = id
        }
        reload()
    }

    /// Only after the user confirmed it, when moving to the Trash failed.
    func deletePermanently(_ id: String) {
        needsPermanentDeletion = nil
        guard !retrying.contains(id) else { return }
        store.remove(id)
        reload()
    }

    func keepAfterTrashFailed() {
        needsPermanentDeletion = nil
    }
}
