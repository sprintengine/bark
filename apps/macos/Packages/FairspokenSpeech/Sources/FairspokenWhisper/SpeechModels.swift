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
/// (Whisper), with one model loaded at a time.
public actor LocalSpeechRouter: SpeechEngine {
    private let parakeet = FluidAudioEngine()
    private let whisper = WhisperKitEngine()
    private var active: (any LocalSpeechEngine)?

    public init() {}

    public var loadedModelID: String? {
        get async { await active?.loadedModelID }
    }

    /// Download if missing, load and warm up `id` on its engine, then free the other engine's model.
    public func load(_ id: String, progress: @escaping @Sendable (ModelStage) -> Void) async throws {
        let (engine, other): (any LocalSpeechEngine, any LocalSpeechEngine) = switch SpeechModels.engine(of: id) {
        case .parakeet: (parakeet, whisper)
        case .whisper: (whisper, parakeet)
        case nil: throw SpeechEngineError.unknownModel(id)
        }
        try await engine.load(id, progress: progress)
        active = engine
        await other.unload()
    }

    public func unload() async {
        await parakeet.unload()
        await whisper.unload()
        active = nil
    }

    public func transcribe(_ samples16k: [Float], options: TranscriptionRequestOptions) async throws -> TranscriptionOutput {
        guard let active else { throw SpeechEngineError.notLoaded }
        return try await active.transcribe(samples16k, options: options)
    }
}
