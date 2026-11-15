import FairspokenCore
import FairspokenSpeech
import Foundation
import WhisperKit

/// One loaded Whisper model for the dictation client, through WhisperKit: the audio encoder and
/// text decoder on the Neural Engine, the mel spectrogram on the GPU (WhisperKit's defaults).
public actor WhisperKitEngine: LocalSpeechEngine {
    private var kit: WhisperKit?
    public private(set) var loadedModelID: String?

    public init() {}

    static func config(folder: URL, base: URL, prewarm: Bool) -> WhisperKitConfig {
        WhisperKitConfig(modelFolder: folder.path, tokenizerFolder: base, verbose: false, logLevel: .error,
                         prewarm: prewarm, load: !prewarm, download: false)
    }

    public func load(_ id: String, progress: @escaping @Sendable (ModelStage) -> Void) async throws {
        if loadedModelID == id, kit != nil { return }
        guard WhisperModels.isSupported(id), let folder = WhisperModels.directory(for: id) else { throw SpeechEngineError.unknownModel(id) }
        if !WhisperModels.isInstalled(id) {
            progress(.downloading(0))
            try await WhisperModels.download(id, progress: progress)
        }
        progress(.loading)
        let started = Date()
        let next = try await WhisperKit(Self.config(folder: folder, base: WhisperModels.root, prewarm: false))
        if let old = kit { await old.unloadModels() }
        kit = next
        loadedModelID = id
        whisperLog.info("Loaded \(id, privacy: .public) in \(Date().timeIntervalSince(started), format: .fixed(precision: 2)) s")
        progress(.warming)
        // One short, near-silent decode so the first dictation doesn't pay for specialisation.
        let probe = (0..<16_000).map { i in Float(sin(Double(i) * 0.05)) * 0.0008 }
        _ = try? await next.transcribe(audioArray: probe, decodeOptions: Self.options(language: "en", samples: probe.count, prompt: nil))
    }

    public func unload() async {
        if let kit { await kit.unloadModels() }
        kit = nil
        loadedModelID = nil
    }

    public func transcribe(_ samples16k: [Float], options: TranscriptionRequestOptions) async throws -> TranscriptionOutput {
        guard let kit, let id = loadedModelID else { throw SpeechEngineError.notLoaded }
        let english = SpeechModelCatalog.model(id: id)?.englishOnly ?? false
        let started = ContinuousClock.now
        let prompt = Self.promptTokens(options.vocabularyHints, tokenizer: kit.tokenizer)
        let decode = Self.options(language: english ? "en" : options.language, samples: samples16k.count, prompt: prompt)
        let results = try await kit.transcribe(audioArray: samples16k, decodeOptions: decode)
        let text = results.map(\.text).joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let ms = Int((ContinuousClock.now - started) / .milliseconds(1))
        return TranscriptionOutput(text: text, modelMs: ms, model: id, backend: "whisperkit", placement: .neuralEngine)
    }

    /// Greedy decoding without timestamps (dictation wants text, not subtitles), with Whisper's
    /// usual retries at higher temperatures when the text looks like a loop, in the chosen
    /// language ("auto" or empty detects it). Recordings longer than Whisper's 30 s window are
    /// cut at pauses first.
    static func options(language: String, samples: Int, prompt: [Int]?) -> DecodingOptions {
        let code = language.trimmingCharacters(in: .whitespaces).lowercased()
        let detect = code.isEmpty || code == "auto"
        return DecodingOptions(task: .transcribe, language: detect ? nil : code, temperature: 0,
                               usePrefillPrompt: !detect, detectLanguage: detect,
                               skipSpecialTokens: true, withoutTimestamps: true, promptTokens: prompt,
                               suppressBlank: true,
                               // The first-word check throws away good text that starts with an
                               // unusual word (an empty result on LibriSpeech with Tiny).
                               firstTokenLogProbThreshold: nil,
                               chunkingStrategy: samples > 30 * WhisperKit.sampleRate ? .vad : nil)
    }

    /// The user's vocabulary as Whisper's previous-text prompt, which nudges spelling. At most
    /// 100 tokens, without special tokens.
    static func promptTokens(_ hints: [String], tokenizer: WhisperTokenizer?) -> [Int]? {
        guard let tokenizer, !hints.isEmpty else { return nil }
        let begin = tokenizer.specialTokens.specialTokenBegin
        let tokens = tokenizer.encode(text: " " + hints.joined(separator: ", ")).filter { $0 < begin }
        return tokens.isEmpty ? nil : Array(tokens.prefix(100))
    }
}
