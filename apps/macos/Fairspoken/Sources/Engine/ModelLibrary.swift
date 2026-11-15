import FairspokenSpeech
import FairspokenWhisper
import Foundation
import FairspokenCore
import Observation
import OSLog

/// State of the local speech engine and the Models library: which models are on this Mac,
/// downloads in flight, and the model loaded for dictation (Parakeet or Whisper).
@Observable
final class ModelLibrary {
    enum EngineState: Equatable {
        case idle
        case downloading(Double)
        case unpacking
        case compiling
        case loading
        case warming
        case ready
        case failed(String)

        var isReady: Bool { self == .ready }
        var isBusy: Bool {
            switch self {
            case .downloading, .unpacking, .compiling, .loading, .warming: true
            default: false
            }
        }

        var label: String {
            switch self {
            case .idle: "Not loaded"
            case .downloading(let f): "Downloading \(Int(f * 100))%"
            case .unpacking: "Unpacking…"
            case .compiling: "Optimising for this device…"
            case .loading: "Loading onto the Neural Engine…"
            case .warming: "Warming up…"
            case .ready: "Ready"
            case .failed(let m): m
            }
        }
    }

    enum ItemState: Equatable {
        case available
        case downloading(Double)
        case unpacking
        case compiling
        case installed

        var isBusy: Bool {
            switch self {
            case .downloading, .unpacking, .compiling: true
            default: false
            }
        }
    }

    private(set) var engineState: EngineState = .idle
    private(set) var activeModelID: String = SpeechModelCatalog.defaultModelID
    private(set) var items: [String: ItemState] = [:]
    private(set) var diskBytes: [String: Int64] = [:]
    private(set) var lastLoadSeconds: Double?
    /// Why the last download of a model failed (says what and where), until the next try.
    private(set) var downloadErrors: [String: String] = [:]

    /// Runs whichever engine the active model needs; dictation transcribes through it.
    let engine = LocalSpeechRouter()
    /// Called when a model failed to load and the previous one was put back (its id), so the
    /// saved choice can follow what is really in use.
    @ObservationIgnored var onFallback: ((String) -> Void)?
    /// True while a dictation is recording or transcribing (set by the app); a model chosen then
    /// is loaded when it ends.
    @ObservationIgnored var isDictating: () -> Bool = { false }
    @ObservationIgnored private var activation = ModelActivation()
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var downloads: [String: Task<Void, Never>] = [:]
    private static let log = Logger(subsystem: AppInfo.bundleID, category: "models")

    var activeModel: SpeechModelInfo { SpeechModelCatalog.resolve(activeModelID) }

    /// Models on this Mac (what the "Downloaded" filter keeps).
    var installedIDs: Set<String> { Set(items.filter { $0.value == .installed }.map(\.key)) }

    init() {
        refresh()
    }

    func state(of id: String) -> ItemState { items[id] ?? .available }

    func refresh() {
        for model in SpeechModelCatalog.all {
            if items[model.id]?.isBusy == true { continue }
            items[model.id] = SpeechModels.isInstalled(model.id) && !presentedAsAvailable.contains(model.id) ? .installed : .available
        }
        let hidden = presentedAsAvailable
        Task.detached(priority: .utility) {
            var sizes: [String: Int64] = [:]
            for model in SpeechModelCatalog.all where !hidden.contains(model.id) {
                if let bytes = SpeechModels.installedBytes(model.id) { sizes[model.id] = bytes }
            }
            await MainActor.run { self.diskBytes = sizes }
        }
    }

    /// Download if needed, load and warm up. Safe to call repeatedly. An id the catalogue
    /// doesn't know loads the default model instead.
    func prepare(_ requested: String) {
        let id = SpeechModelCatalog.resolve(requested).id
        guard !(activeModelID == id && (engineState.isReady || engineState.isBusy)) else { return }
        activeModelID = id
        loadTask?.cancel()
        engineState = .loading
        downloadErrors[id] = nil
        let started = Date()
        let report: @Sendable (ModelStage) -> Void = { [weak self] stage in
            Task { @MainActor in self?.apply(stage, for: id) }
        }
        loadTask = Task { [weak self, engine] in
            do {
                try await engine.load(id, progress: report)
                await MainActor.run {
                    guard let self, self.activeModelID == id else { return }
                    self.engineState = .ready
                    self.lastLoadSeconds = Date().timeIntervalSince(started)
                    self.refresh()
                }
            } catch is CancellationError {
                // A newer choice replaced this one; it reports for itself.
            } catch {
                // The router puts the previous model back when it can.
                let fallback = await engine.loadedModelID
                await MainActor.run {
                    guard let self, self.activeModelID == id else { return }
                    Self.log.error("Model load failed: \(error.localizedDescription, privacy: .public)")
                    let message = "Couldn't load the model: \(error.localizedDescription)"
                    // The model's row says why, whether or not it arrived.
                    self.downloadErrors[id] = message
                    if let fallback, fallback != id {
                        self.activeModelID = fallback
                        self.engineState = .ready
                        self.onFallback?(fallback)
                    } else {
                        self.engineState = .failed(message)
                    }
                    if self.items[id] != .installed { self.items[id] = nil }
                    self.refresh()
                }
            }
        }
    }

    /// Transcribes on this Mac with `requested`, an installed model: the fallback for a dictation
    /// the host couldn't transcribe, and for retrying a kept one. The model is chosen through
    /// `use`, so it never replaces one a dictation is using; if it can't be loaded now this
    /// throws at once, and the dictation stays kept.
    func transcribeOnThisMac(_ samples16k: [Float], model requested: String, options: TranscriptionRequestOptions) async throws -> TranscriptionOutput {
        let id = SpeechModelCatalog.resolve(requested).id
        if !(activeModelID == id && engineState.isReady) {
            use(id)
            guard activeModelID == id else {
                throw NSError(domain: "engine", code: 3, userInfo: [NSLocalizedDescriptionKey: "\(SpeechModelCatalog.resolve(id).shortName) isn't loaded yet"])
            }
        }
        let deadline = ContinuousClock.now + .seconds(120)
        while !(activeModelID == id && engineState.isReady) {
            if activeModelID != id { throw NSError(domain: "engine", code: 3, userInfo: [NSLocalizedDescriptionKey: "Another speech model was chosen"]) }
            if case .failed(let message) = engineState { throw NSError(domain: "engine", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
            if ContinuousClock.now > deadline { throw NSError(domain: "engine", code: 2, userInfo: [NSLocalizedDescriptionKey: "The speech model is still loading"]) }
            try await Task.sleep(for: .milliseconds(50))
        }
        return try await engine.transcribe(samples16k, options: options)
    }

    private func apply(_ stage: ModelStage, for id: String) {
        guard activeModelID == id, engineState != .ready else { return }
        // A late report after the load failed would leave the row looking busy.
        if case .failed = engineState { return }
        switch stage {
        case .downloading(let f):
            engineState = .downloading(f)
            items[id] = .downloading(f)
        case .unpacking:
            engineState = .unpacking
            items[id] = .unpacking
        case .compiling:
            engineState = .compiling
            items[id] = .compiling
        case .loading:
            engineState = .loading
            items[id] = .installed
        case .warming:
            engineState = .warming
        }
    }

    /// Makes `id` the model dictation uses: downloaded first as a library download (shown on its
    /// row, cancellable) if it is missing, and loaded only between dictations. Every way of
    /// choosing a model goes through here. An id the catalogue doesn't know means the default.
    func use(_ requested: String) {
        let id = SpeechModelCatalog.resolve(requested).id
        perform(activation.request(id, installed: SpeechModels.isInstalled(id), downloading: isDownloading(id),
                                   dictationActive: switchMustWait))
    }

    private var switchMustWait: Bool {
        ModelActivation.mustWait(dictating: isDictating(), engineReady: engineState.isReady)
    }

    /// The dictation in progress ended: load a model chosen during it.
    func dictationEnded() { perform(activation.dictationEnded()) }

    private func perform(_ step: ModelActivation.Step) {
        switch step {
        case .none: break
        case .download(let id): download(id)
        case .load(let id): prepare(id)
        }
    }

    /// Library download (not activated unless `use` asked for it).
    func download(_ id: String) {
        guard state(of: id) == .available, SpeechModelCatalog.model(id: id) != nil else { return }
        items[id] = .downloading(0)
        downloadErrors[id] = nil
        let report: @Sendable (ModelStage) -> Void = { [weak self] stage in
            Task { @MainActor in
                guard let self, self.items[id]?.isBusy == true else { return }
                switch stage {
                case .downloading(let f): self.items[id] = .downloading(f)
                case .unpacking: self.items[id] = .unpacking
                case .compiling: self.items[id] = .compiling
                default: break
                }
            }
        }
        downloads[id] = Task { [weak self] in
            var failure: String?
            do {
                try await SpeechModels.download(id, progress: report)
            } catch is CancellationError {
            } catch {
                Self.log.error("Download failed: \(error.localizedDescription, privacy: .public)")
                failure = Task.isCancelled ? nil : error.localizedDescription
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.downloads[id] = nil
                self.items[id] = nil
                self.downloadErrors[id] = failure
                self.refresh()
                // A model chosen before it was downloaded is used now (or after the dictation).
                self.perform(self.activation.downloadFinished(id, success: SpeechModels.isInstalled(id),
                                                              dictationActive: self.switchMustWait))
            }
        }
    }

    /// Stops a library download. Files already fetched stay, so the next try resumes.
    func cancelDownload(_ id: String) {
        downloads[id]?.cancel()
    }

    func isDownloading(_ id: String) -> Bool { downloads[id] != nil }

    func clearDownloadError(_ id: String) { downloadErrors[id] = nil }

    /// Screenshot mode: shows `id` in `state` (a download in progress, say) without doing it.
    func showcase(_ id: String, _ state: ItemState) { items[id] = state }

    /// Screenshot mode: shows a model as not downloaded, whatever is on disk.
    @ObservationIgnored var presentedAsAvailable: Set<String> = []

    /// Removes a model's files, only ever inside its engine's model folder. The active model is
    /// never deleted.
    func delete(_ id: String) {
        guard id != activeModelID, state(of: id) == .installed else { return }
        do {
            try SpeechModels.delete(id)
        } catch {
            Self.log.error("Delete failed: \(error.localizedDescription, privacy: .public)")
            downloadErrors[id] = "Couldn't delete the model: \(error.localizedDescription)"
        }
        items[id] = .available
        diskBytes[id] = nil
        refresh()
    }
}
