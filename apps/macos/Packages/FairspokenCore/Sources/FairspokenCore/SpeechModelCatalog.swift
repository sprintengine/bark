import Foundation

public enum ComputePlacement: String, Sendable, Codable {
    case neuralEngine
    case gpu
    case cpu
    case remoteHost

    public var label: String {
        switch self {
        case .neuralEngine: "Neural Engine"
        case .gpu: "GPU"
        case .cpu: "CPU"
        case .remoteHost: "Your host"
        }
    }

    public var symbol: String {
        switch self {
        case .neuralEngine: "brain"
        case .gpu: "cpu"
        case .cpu: "memorychip"
        case .remoteHost: "server.rack"
        }
    }
}

/// The engine that runs a model on this Mac.
public enum SpeechEngineKind: String, Sendable, Codable, CaseIterable, Identifiable {
    /// NVIDIA Parakeet through FluidAudio (Core ML).
    case parakeet
    /// OpenAI Whisper through WhisperKit (Core ML).
    case whisper

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .parakeet: "Parakeet"
        case .whisper: "Whisper"
        }
    }

    /// The library that runs it.
    public var runtime: String {
        switch self {
        case .parakeet: "FluidAudio"
        case .whisper: "WhisperKit"
        }
    }

    public var symbol: String {
        switch self {
        case .parakeet: "bird"
        case .whisper: "waveform"
        }
    }
}

/// What a catalogue row is. Only speech models exist today; cleanup (polish) models and remote
/// endpoints will be rows of the same library.
public enum CatalogueKind: String, Sendable, Codable, CaseIterable {
    case speech
    case cleanup
    case remoteEndpoint

    public var label: String {
        switch self {
        case .speech: "Speech"
        case .cleanup: "Cleanup"
        case .remoteEndpoint: "Remote endpoint"
        }
    }
}

/// Where the speed and accuracy figures of a model come from.
public enum ScoreSource: String, Sendable, Codable {
    /// Measured on an M4 Mac: 20 LibriSpeech test-clean utterances (147 s), median of warm
    /// runs (`apps/macos/docs/model-benchmarks.md`).
    case measured
    /// Published by the model's authors or converters; not measured here.
    case published
    /// No figures yet.
    case none
}

/// 1…5 bars from measured figures, so every row is scored the same way.
public enum ScoreScale {
    /// Word error rate (%, lower is better). On the 20-clip check one word is about 0.3 points,
    /// so the top step is wide enough that a word either way doesn't change it.
    public static func accuracy(wer: Double) -> Int {
        switch wer {
        case ..<2.75: 5
        case ..<3.5: 4
        case ..<5: 3
        case ..<8: 2
        default: 1
        }
    }

    /// Real-time factor (seconds of audio per second of compute, higher is better).
    public static func speed(rtfx: Double) -> Int {
        switch rtfx {
        case 100...: 5
        case 40...: 4
        case 15...: 3
        case 5...: 2
        default: 1
        }
    }
}

/// One model in the library: a local speech model the Mac app can run (Parakeet through
/// FluidAudio, Whisper through WhisperKit), with what the table and the detail sheet show.
public struct SpeechModelInfo: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var shortName: String
    /// Model family ("Parakeet", "Whisper").
    public var family: String
    /// Who made the model (vendor).
    public var publisher: String
    public var engine: SpeechEngineKind
    public var kind: CatalogueKind
    /// The Hugging Face repository the files come from.
    public var repository: String
    /// The folder inside `repository` (WhisperKit variants); nil when the repository is the model.
    public var variant: String?
    public var license: String
    /// Download size.
    public var approxBytes: Int64
    /// Memory while loaded. For Parakeet the encoder weights live in Neural Engine (kernel
    /// wired) memory, measured by the FluidAudio spike on an M4; Whisper figures are measured
    /// the same way where `scoreSource == .measured` and approximate otherwise.
    public var memoryBytes: Int64
    public var languages: String
    public var englishOnly: Bool
    public var summary: String
    /// A longer description for the detail sheet.
    public var details: String
    /// Runs on this Mac (false for remote endpoints).
    public var isLocal: Bool
    /// 1…5 bars.
    public var accuracy: Int
    public var speed: Int
    /// Word error rate (%) and real-time factor behind the bars, from `scoreSource`.
    public var wer: Double?
    public var rtfx: Double?
    public var scoreSource: ScoreSource
    /// Full LibriSpeech test-clean / test-other error rates (%) and real-time factor, as
    /// published (FluidAudio's benchmarks for Parakeet).
    public var werClean: Double?
    public var werOther: Double?
    public var realTimeFactor: Double?
    public var placement: ComputePlacement
    public var badge: String?
    public var isRecommended: Bool
    /// New in this version of the library.
    public var isNew: Bool
    public var isExperimental: Bool

    public init(id: String, name: String, shortName: String, family: String, publisher: String,
                engine: SpeechEngineKind, kind: CatalogueKind = .speech, repository: String, variant: String? = nil,
                license: String, approxBytes: Int64, memoryBytes: Int64, languages: String, englishOnly: Bool,
                summary: String, details: String, isLocal: Bool = true,
                wer: Double? = nil, rtfx: Double? = nil, scoreSource: ScoreSource,
                accuracy: Int? = nil, speed: Int? = nil,
                werClean: Double? = nil, werOther: Double? = nil, realTimeFactor: Double? = nil,
                placement: ComputePlacement = .neuralEngine, badge: String? = nil, isRecommended: Bool = false,
                isNew: Bool = false, isExperimental: Bool = false) {
        self.id = id
        self.name = name
        self.shortName = shortName
        self.family = family
        self.publisher = publisher
        self.engine = engine
        self.kind = kind
        self.repository = repository
        self.variant = variant
        self.license = license
        self.approxBytes = approxBytes
        self.memoryBytes = memoryBytes
        self.languages = languages
        self.englishOnly = englishOnly
        self.summary = summary
        self.details = details
        self.isLocal = isLocal
        self.wer = wer
        self.rtfx = rtfx
        self.scoreSource = scoreSource
        self.accuracy = accuracy ?? wer.map(ScoreScale.accuracy(wer:)) ?? 3
        self.speed = speed ?? rtfx.map(ScoreScale.speed(rtfx:)) ?? 3
        self.werClean = werClean
        self.werOther = werOther
        self.realTimeFactor = realTimeFactor
        self.placement = placement
        self.badge = badge
        self.isRecommended = isRecommended
        self.isNew = isNew
        self.isExperimental = isExperimental
    }

    /// The model's page on Hugging Face.
    public var sourceURL: URL? {
        var path = "https://huggingface.co/\(repository)"
        if let variant { path += "/tree/main/\(variant)" }
        return URL(string: path)
    }
}

public enum SpeechModelCatalog {
    public static let defaultModelID = "parakeet-tdt-0.6b-v3"

    /// Every model, in the library's default order. Whisper ids are the Tauri app's
    /// (`WhisperModel::model_id` in src-tauri/src/models.rs) where it has the model, so one
    /// settings.json means the same model in both apps.
    public static let all: [SpeechModelInfo] = parakeet + whisper

    public static let parakeet: [SpeechModelInfo] = [
        SpeechModelInfo(
            id: "parakeet-tdt-0.6b-v3", name: "Parakeet TDT 0.6B v3", shortName: "Parakeet v3", family: "Parakeet",
            publisher: "NVIDIA", engine: .parakeet, repository: "FluidInference/parakeet-tdt-0.6b-v3-coreml",
            license: "CC BY 4.0", approxBytes: 470_000_000, memoryBytes: 450_000_000,
            languages: "25 European languages", englishOnly: false,
            summary: "The default. Fast, accurate dictation in English and 24 other European languages.",
            details: "NVIDIA's 600M-parameter TDT model, converted to Core ML by FluidInference. It runs on the Neural Engine and turns a dictation into text in well under a tenth of a second. It detects the language by itself.",
            wer: 2.07, rtfx: 129, scoreSource: .measured,
            werClean: 2.27, werOther: 4.12, realTimeFactor: 128.6,
            badge: "Default", isRecommended: true),
        SpeechModelInfo(
            id: "parakeet-ultra", name: "Parakeet Ultra", shortName: "Parakeet Ultra", family: "Parakeet",
            publisher: "Moondream", engine: .parakeet, repository: "FluidInference/parakeet-ultra-coreml",
            license: "CC BY 4.0", approxBytes: 613_000_000, memoryBytes: 600_000_000,
            languages: "25 European languages", englishOnly: false,
            summary: "Post-trained v3. Lowest published error rate in every language at the same speed; a larger download.",
            details: "Moondream's post-trained Parakeet TDT 0.6B v3. FluidAudio's published benchmarks put it ahead of v3 in every language at the same speed; on the 20-utterance check here the two are within a word of each other.",
            wer: 2.33, rtfx: 120, scoreSource: .measured,
            werClean: 2.13, werOther: 3.81, realTimeFactor: 126.7,
            badge: "Most accurate"),
        SpeechModelInfo(
            id: "parakeet-tdt-0.6b-v2", name: "Parakeet TDT 0.6B v2", shortName: "Parakeet v2", family: "Parakeet",
            publisher: "NVIDIA", engine: .parakeet, repository: "FluidInference/parakeet-tdt-0.6b-v2-coreml",
            license: "CC BY 4.0", approxBytes: 470_000_000, memoryBytes: 450_000_000,
            languages: "English", englishOnly: true,
            summary: "The English-only predecessor. Kept for parity with the Windows and Linux app.",
            details: "NVIDIA's English-only Parakeet TDT 0.6B v2, converted to Core ML by FluidInference. Same size and speed as v3.",
            scoreSource: .none, accuracy: 4, speed: 5),
    ]

    private static let whisperRepo = "argmaxinc/whisperkit-coreml"
    private static let whisperDetails = "OpenAI's Whisper, converted to Core ML by Argmax and run on the Neural Engine by WhisperKit. Whisper decodes word by word, so it is slower than Parakeet for dictation, and it can make up words on silence or noise."

    /// Measured with this engine code on an M4 (docs/model-benchmarks.md); memory is the rise in
    /// wired plus app memory while loaded.
    public static let whisper: [SpeechModelInfo] = [
        whisperModel("tiny", "Whisper Tiny", variant: "openai_whisper-tiny", bytes: 76_600_000, memory: 190_000_000,
                     englishOnly: false, summary: "The smallest Whisper. Quick, but makes many mistakes.",
                     wer: 7.77, rtfx: 105),
        whisperModel("tiny.en", "Whisper Tiny (English)", variant: "openai_whisper-tiny.en", bytes: 153_000_000, memory: 160_000_000,
                     englishOnly: true, summary: "The smallest Whisper, trained on English only.",
                     wer: 5.70, rtfx: 108),
        whisperModel("base", "Whisper Base", variant: "openai_whisper-base", bytes: 146_700_000, memory: 220_000_000,
                     englishOnly: false, summary: "Small and quick; fine for short, clear dictation.",
                     wer: 6.22, rtfx: 57),
        whisperModel("base.en", "Whisper Base (English)", variant: "openai_whisper-base.en", bytes: 146_700_000, memory: 240_000_000,
                     englishOnly: true, summary: "Base, trained on English only.",
                     wer: 5.44, rtfx: 65),
        whisperModel("small", "Whisper Small", variant: "openai_whisper-small_216MB", bytes: 217_400_000, memory: 480_000_000,
                     englishOnly: false, summary: "A compressed Small: a balance of size and accuracy in 99 languages.",
                     wer: 4.40, rtfx: 15.7),
        whisperModel("small.en", "Whisper Small (English)", variant: "openai_whisper-small.en_217MB", bytes: 217_900_000, memory: 480_000_000,
                     englishOnly: true, summary: "A compressed Small, trained on English only. Accurate for its size.",
                     wer: 2.33, rtfx: 16),
        whisperModel("medium", "Whisper Medium", variant: "openai_whisper-medium", bytes: 1_529_700_000, memory: 2_000_000_000,
                     englishOnly: false, summary: "Accurate, but slow on the Neural Engine and a 1.5 GB download.",
                     wer: 2.33, rtfx: 5.1),
        whisperModel("medium.en", "Whisper Medium (English)", variant: "openai_whisper-medium.en", bytes: 1_529_700_000, memory: 1_760_000_000,
                     englishOnly: true, summary: "Medium, trained on English only. Slow on the Neural Engine.",
                     wer: 2.33, rtfx: 5.7),
        whisperModel("large-v2", "Whisper Large v2", variant: "openai_whisper-large-v2_949MB", bytes: 952_200_000, memory: 1_340_000_000,
                     englishOnly: false, summary: "The previous Large, compressed. Accurate and slow.",
                     wer: 2.33, rtfx: 3.3),
        whisperModel("large-v3", "Whisper Large v3", variant: "openai_whisper-large-v3_947MB", bytes: 948_100_000, memory: 1_260_000_000,
                     englishOnly: false, summary: "Whisper's largest model, compressed to under 1 GB. For re-transcribing recordings rather than live dictation.",
                     wer: 2.59, rtfx: 3.5),
        whisperModel("large-v3-turbo", "Whisper Large v3 Turbo", variant: "openai_whisper-large-v3-v20240930_626MB", bytes: 626_700_000, memory: 990_000_000,
                     englishOnly: false, summary: "Large v3 with a 4-layer decoder: over twice as fast, in 99 languages.",
                     wer: 3.11, rtfx: 8, recommended: true),
        whisperModel("distil-large-v3", "Distil-Whisper Large v3", publisher: "Hugging Face",
                     variant: "distil-whisper_distil-large-v3_594MB", bytes: 594_500_000, memory: 950_000_000,
                     englishOnly: true, summary: "Hugging Face's distilled Large v3: English only, fast for its size.",
                     wer: 3.11, rtfx: 9.2, family: "Distil-Whisper"),
    ]

    private static func whisperModel(_ id: String, _ name: String, publisher: String = "OpenAI", variant: String,
                                     bytes: Int64, memory: Int64, englishOnly: Bool, summary: String,
                                     wer: Double, rtfx: Double, badge: String? = nil,
                                     recommended: Bool = false, experimental: Bool = false,
                                     family: String = "Whisper") -> SpeechModelInfo {
        SpeechModelInfo(
            id: id, name: name, shortName: name, family: family, publisher: publisher, engine: .whisper,
            repository: whisperRepo, variant: variant, license: "MIT (weights), Apache 2.0 (tokenizer)", approxBytes: bytes, memoryBytes: memory,
            languages: englishOnly ? "English" : "99 languages", englishOnly: englishOnly,
            summary: summary, details: whisperDetails, wer: wer, rtfx: rtfx, scoreSource: .measured,
            badge: badge, isRecommended: recommended, isNew: true, isExperimental: experimental)
    }

    public static func model(id: String) -> SpeechModelInfo? {
        all.first { $0.id == id }
    }

    /// `id` if the catalogue has it, otherwise the default model (settings from another app or
    /// an older build).
    public static func resolve(_ id: String) -> SpeechModelInfo {
        model(id: id) ?? model(id: defaultModelID)!
    }
}
