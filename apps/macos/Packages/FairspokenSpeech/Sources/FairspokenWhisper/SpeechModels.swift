import FairspokenCore
import FairspokenSpeech
import Foundation

/// Every local model, whichever engine runs it: install state, download, delete and size, by
/// catalogue id. Parakeet lives in FluidAudio's shared cache, Whisper in `WhisperModels.root`.
public enum SpeechModels {
    public static func engine(of id: String) -> SpeechEngineKind? {
        SpeechModelCatalog.model(id: id)?.engine
    }

    public static func isInstalled(_ id: String) -> Bool {
        switch engine(of: id) {
        case .parakeet: ParakeetModels.isInstalled(id)
        case .whisper: WhisperModels.isInstalled(id)
        case nil: false
        }
    }

    public static func directory(for id: String) -> URL? {
        switch engine(of: id) {
        case .parakeet: ParakeetModels.directory(for: id)
        case .whisper: WhisperModels.directory(for: id)
        case nil: nil
        }
    }

    /// True when the model can be downloaded from a link (`modelLinks`): Parakeet archives today.
    public static func supportsLinks(_ id: String) -> Bool { engine(of: id) == .parakeet }

    public static func download(_ id: String, progress: @escaping @Sendable (ModelStage) -> Void) async throws {
        switch engine(of: id) {
        case .parakeet: try await ParakeetModels.download(id, progress: progress)
        case .whisper: try await WhisperModels.download(id, progress: progress)
        case nil: throw SpeechEngineError.unknownModel(id)
        }
    }

    /// Removes a model's files, only ever inside its engine's model folder.
    public static func delete(_ id: String) throws {
        switch engine(of: id) {
        case .parakeet: try ParakeetModels.delete(id)
        case .whisper: try WhisperModels.delete(id)
        case nil: throw SpeechEngineError.unknownModel(id)
        }
    }

    public static func installedBytes(_ id: String) -> Int64? {
        switch engine(of: id) {
        case .parakeet: ParakeetModels.installedBytes(id)
        case .whisper: WhisperModels.installedBytes(id)
        case nil: nil
        }
    }
}

/// The dictation client's engine: runs the chosen model on FluidAudio (Parakeet) or WhisperKit
/// (Whisper), with one model in memory at a time.
///
/// Replacing the model is serialised: one replacement runs at a time, and a newer request
/// cancels the one in flight and waits for it before starting, so a slow load that finishes late
/// can never take the place of a newer choice. The previous model is released before the new
/// weights load (a 16 GB Mac shouldn't hold two), and loaded again if the new one fails, so
/// dictation keeps working and the caller still gets the error.
public actor LocalSpeechRouter: SpeechEngine {
    private let parakeet: any LocalSpeechEngine
    private let whisper: any LocalSpeechEngine
    private var active: (any LocalSpeechEngine)?
    private var inFlight: Task<Void, Error>?
    private var generation = 0

    public init() {
        self.init(parakeet: FluidAudioEngine(), whisper: WhisperKitEngine())
    }

    /// Engines supplied by the caller (tests).
    public init(parakeet: any LocalSpeechEngine, whisper: any LocalSpeechEngine) {
        self.parakeet = parakeet
        self.whisper = whisper
    }

    public var loadedModelID: String? {
        get async { await active?.loadedModelID }
    }

    /// Makes `id` the loaded model (downloading it first if it is missing). Throws
    /// `CancellationError` when a newer `load` replaced this request before it finished.
    public func load(_ id: String, progress: @escaping @Sendable (ModelStage) -> Void) async throws {
        guard let engine = engine(for: id) else { throw SpeechEngineError.unknownModel(id) }
        generation += 1
        let ticket = generation
        if let previous = inFlight {
            previous.cancel()
            _ = try? await previous.value
        }
        // Another request arrived while this one waited.
        guard ticket == generation else { throw CancellationError() }
        let task = Task { try await self.replace(with: id, on: engine, ticket: ticket, progress: progress) }
        inFlight = task
        defer { if ticket == generation { inFlight = nil } }
        try await task.value
    }

    private func engine(for id: String) -> (any LocalSpeechEngine)? {
        switch SpeechModels.engine(of: id) {
        case .parakeet: parakeet
        case .whisper: whisper
        case nil: nil
        }
    }

    private func isCurrent(_ ticket: Int) -> Bool { ticket == generation && !Task.isCancelled }

    private func replace(with id: String, on engine: any LocalSpeechEngine, ticket: Int,
                         progress: @escaping @Sendable (ModelStage) -> Void) async throws {
        let previous = active
        let previousID = await previous?.loadedModelID
        if previous === engine, previousID == id { return }
        // Free the old weights first.
        if let previous { await previous.unload() }
        active = nil
        do {
            try await engine.load(id, progress: progress)
        } catch {
            guard isCurrent(ticket) else { throw CancellationError() }
            // Put the previous model back so dictation still works; the caller shows the error.
            if let previous, let previousID, (try? await previous.load(previousID, progress: { _ in })) != nil {
                active = previous
            }
            throw error
        }
        // What is in memory is what `active` says, even when a newer request is about to replace it.
        active = engine
        guard isCurrent(ticket) else { throw CancellationError() }
    }

    public func unload() async {
        generation += 1
        inFlight?.cancel()
        _ = try? await inFlight?.value
        await parakeet.unload()
        await whisper.unload()
        active = nil
    }

    public func transcribe(_ samples16k: [Float], options: TranscriptionRequestOptions) async throws -> TranscriptionOutput {
        guard let active else { throw SpeechEngineError.notLoaded }
        return try await active.transcribe(samples16k, options: options)
    }
}
