import FairspokenCore
import FairspokenSpeech
import Foundation
import OSLog
import Synchronization
import WhisperKit

let whisperLog = Logger(subsystem: "ie.fairspoken.speech", category: "whisper")

/// The Whisper models WhisperKit can run, where they live and how they are installed.
///
/// Files go under `root` (default `ModelStorage.defaultRoot/WhisperKit`) in the Hugging Face
/// layout WhisperKit uses: `models/argmaxinc/whisperkit-coreml/<variant>/` for the Core ML
/// bundles and `models/openai/whisper-<size>/` for the tokenizer. A finished download leaves a
/// marker in the variant folder, so an interrupted one never counts as installed.
public enum WhisperModels {
    static let marker = ".fairspoken-installed"
    static let modelRepo = "argmaxinc/whisperkit-coreml"
    static let bundles = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]

    private static let currentRoot = Mutex<URL>(ModelStorage.defaultRoot.appendingPathComponent("WhisperKit", isDirectory: true))

    /// The folder every Whisper model lives under.
    public static var root: URL { currentRoot.withLock { $0 } }

    /// Moves the store (tests and benchmarks; the app keeps the default).
    public static func setRoot(_ url: URL) { currentRoot.withLock { $0 = url } }

    public static func isSupported(_ id: String) -> Bool { info(id) != nil }

    static func info(_ id: String) -> SpeechModelInfo? {
        guard let m = SpeechModelCatalog.model(id: id), m.engine == .whisper, m.variant != nil else { return nil }
        return m
    }

    /// WhisperKit's name for the model size, which picks the tokenizer.
    static func modelVariant(_ id: String) -> ModelVariant? {
        switch id {
        case "tiny": .tiny
        case "tiny.en": .tinyEn
        case "base": .base
        case "base.en": .baseEn
        case "small": .small
        case "small.en": .smallEn
        case "medium": .medium
        case "medium.en": .mediumEn
        case "large-v2": .largev2
        case "large-v3", "large-v3-turbo", "distil-large-v3": .largev3
        default: nil
        }
    }

    static func tokenizerRepo(_ id: String) -> String? {
        switch modelVariant(id) {
        case .tiny: "openai/whisper-tiny"
        case .tinyEn: "openai/whisper-tiny.en"
        case .base: "openai/whisper-base"
        case .baseEn: "openai/whisper-base.en"
        case .small: "openai/whisper-small"
        case .smallEn: "openai/whisper-small.en"
        case .medium: "openai/whisper-medium"
        case .mediumEn: "openai/whisper-medium.en"
        case .large: "openai/whisper-large"
        case .largev2: "openai/whisper-large-v2"
        case .largev3: "openai/whisper-large-v3"
        case nil: nil
        }
    }

    static var repoDirectory: URL {
        root.appendingPathComponent("models", isDirectory: true).appendingPathComponent(modelRepo, isDirectory: true)
    }

    /// The model's Core ML folder.
    public static func directory(for id: String) -> URL? {
        info(id)?.variant.map { repoDirectory.appendingPathComponent($0, isDirectory: true) }
    }

    static func tokenizerDirectory(for id: String) -> URL? {
        tokenizerRepo(id).map { root.appendingPathComponent("models", isDirectory: true).appendingPathComponent($0, isDirectory: true) }
    }

    public static func isInstalled(_ id: String) -> Bool {
        guard let dir = directory(for: id), let tokenizer = tokenizerDirectory(for: id) else { return false }
        let fm = FileManager.default
        return fm.fileExists(atPath: dir.appendingPathComponent(marker).path)
            && bundles.allSatisfy { fm.fileExists(atPath: dir.appendingPathComponent("\($0).mlmodelc").path) }
            && fm.fileExists(atPath: tokenizer.appendingPathComponent("tokenizer.json").path)
    }

    /// Downloads the model and its tokenizer from Hugging Face, then compiles it for this Mac's
    /// Neural Engine once (`.compiling`), so the first load is quick. Cancellable while it
    /// downloads (the task's cancellation); the partial files stay for the next try to resume.
    public static func download(_ id: String, progress: @escaping @Sendable (ModelStage) -> Void) async throws {
        guard let m = info(id), let variant = m.variant, let size = modelVariant(id) else { throw SpeechEngineError.unknownModel(id) }
        if isInstalled(id) { return }
        let base = root
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        whisperLog.info("Downloading \(id, privacy: .public) (\(variant, privacy: .public))")
        progress(.downloading(0))
        let folder: URL
        do {
            folder = try await WhisperKit.download(variant: variant, downloadBase: base, from: modelRepo) { p in
                progress(.downloading(min(0.98, p.fractionCompleted * 0.98)))
            }
            try Task.checkCancellation()
            // The tokenizer is a separate, small repository; fetch it now so dictation works offline.
            _ = try await ModelUtilities.loadTokenizer(for: size, tokenizerFolder: base)
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw SpeechEngineError.downloadFailed(m.name, describe(error))
        }
        let expected = directory(for: id)
        guard folder.resolvingSymlinksInPath().path == expected?.resolvingSymlinksInPath().path else {
            throw SpeechEngineError.downloadFailed(m.name, "the files arrived in an unexpected folder")
        }
        progress(.compiling)
        do {
            // Compiles for the Neural Engine and drops the weights again (CoreML caches the result).
            let kit = try await WhisperKit(WhisperKitEngine.config(folder: folder, base: base, prewarm: true))
            await kit.unloadModels()
        } catch {
            throw SpeechEngineError.downloadFailed(m.name, "it downloaded but couldn't be prepared: \(describe(error))")
        }
        FileManager.default.createFile(atPath: folder.appendingPathComponent(marker).path, contents: Data())
        whisperLog.info("Installed \(id, privacy: .public)")
    }

    /// Removes a model's Core ML files (and their download records). Only ever deletes inside
    /// `root`; the tokenizer, shared by models of one size, is kept.
    public static func delete(_ id: String) throws {
        guard let m = info(id), let variant = m.variant, let dir = directory(for: id) else { throw SpeechEngineError.unknownModel(id) }
        guard try ModelStorage.removeItem(dir, inside: root) else { throw SpeechEngineError.unknownModel(id) }
        let records = repoDirectory.appendingPathComponent(".cache/huggingface/download", isDirectory: true)
            .appendingPathComponent(variant, isDirectory: true)
        _ = try? ModelStorage.removeItem(records, inside: root)
    }

    /// Allocated size of an installed model folder.
    public static func installedBytes(_ id: String) -> Int64? {
        guard let dir = directory(for: id), FileManager.default.fileExists(atPath: dir.path) else { return nil }
        return ModelStorage.allocatedSize(of: dir)
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? URLError {
            switch e.code {
            case .notConnectedToInternet: return "this Mac is offline"
            case .timedOut: return "huggingface.co didn't answer in time"
            case .cannotFindHost, .dnsLookupFailed: return "huggingface.co couldn't be found (check the network or proxy)"
            default: break
            }
        }
        return ModelLinkError.describe(error)
    }
}
