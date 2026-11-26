import Foundation

public enum TranscriptionLocation: String, Codable, Sendable, CaseIterable {
    case local
    case remoteHost = "remote-host"
    case cloud
}

public enum RecordingShortcutMode: String, Codable, Sendable, CaseIterable {
    case toggle
    case pushToTalk = "push-to-talk"
}

/// Who wrote a dictionary entry (`EntryOrigin` in settings.rs). Learned entries come from the
/// edit watcher and carry a "Learned" marker on the Vocabulary screen.
public enum EntryOrigin: String, Codable, Sendable {
    case manual
    case learned
}

public struct TranscriptCorrection: Codable, Equatable, Sendable {
    public var enabled = true
    public var from = ""
    public var to = ""
    public var caseSensitive = false
    public var wholePhrase = true
    public var origin: EntryOrigin = .manual
    /// Speech models (`AppSettings.speechModelID`) the correction applies to; empty means every
    /// model. Learned mappings are scoped to the models that actually produced the mishearing.
    public var models: [String] = []

    public init() {}
    public init(from: String, to: String, origin: EntryOrigin = .manual, models: [String] = []) {
        self.from = from
        self.to = to
        self.origin = origin
        self.models = models
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.lenient(Bool.self, .enabled) ?? true
        from = c.lenient(String.self, .from) ?? ""
        to = c.lenient(String.self, .to) ?? ""
        caseSensitive = c.lenient(Bool.self, .caseSensitive) ?? false
        wholePhrase = c.lenient(Bool.self, .wholePhrase) ?? true
        origin = c.lenient(EntryOrigin.self, .origin) ?? .manual
        models = c.lenient([String].self, .models) ?? []
    }

    enum CodingKeys: String, CodingKey { case enabled, from, to, caseSensitive, wholePhrase, origin, models }

    /// As settings.rs writes it: an unscoped correction has no `models` key.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(from, forKey: .from)
        try c.encode(to, forKey: .to)
        try c.encode(caseSensitive, forKey: .caseSensitive)
        try c.encode(wholePhrase, forKey: .wholePhrase)
        try c.encode(origin, forKey: .origin)
        if !models.isEmpty { try c.encode(models, forKey: .models) }
    }
}

public struct Snippet: Codable, Equatable, Sendable {
    public var enabled = true
    public var trigger = ""
    public var expansion = ""
    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.lenient(Bool.self, .enabled) ?? true
        trigger = c.lenient(String.self, .trigger) ?? ""
        expansion = c.lenient(String.self, .expansion) ?? ""
    }
}

/// `settings.json`, field-for-field compatible with `Settings` in `src-tauri/src/settings.rs`
/// (same camelCase names, kebab-case enums, defaults and clamps). Mac-only additions are
/// extra keys the Rust app ignores. Secrets are kept out of the file (Keychain); the JSON
/// keeps empty strings exactly as the plan's §2.8 describes.
public struct AppSettings: Codable, Equatable, Sendable {
    public var transcriptionLocation: TranscriptionLocation = .local
    public var model = SpeechModelCatalog.defaultModelID
    public var remoteUrl = ""
    public var remoteAuthToken = ""
    public var remoteTimeoutSeconds = 60
    public var cloudAuthToken = ""
    public var language = "en"
    public var audioDevice = ""
    public var noiseSuppression = true
    public var echoCancellation = true
    public var inputGain = 2
    public var postProcess = true
    public var vocabularyHints: [String] = []
    /// Bundled vocabulary packs the user turned on, by id (`VocabularyPacks`).
    public var enabledPacks: [String] = []
    public var transcriptCorrections: [TranscriptCorrection] = []
    public var snippets: [Snippet] = []
    public var alwaysOnTop = true
    public var interactionSounds = true
    public var maxRecordingSeconds = 120
    public var noteRetentionMinutes = 0
    public var useGpu = true
    public var recordingShortcut = AcceleratorString.defaultRecording
    public var recordingShortcutMode: RecordingShortcutMode = .toggle
    public var transcriptStackShortcut = AcceleratorString.defaultTranscriptStack
    public var insertAtCursor = true
    public var accessibilityInsert = false
    public var fnPushToTalk = false
    public var polishEnabled = false
    public var polishProvider = "cloud"
    public var polishModel = "speakoflow-mini"
    public var polishTones: [String: String] = [:]
    public var contextAwareness = false
    /// Keep each dictation's audio and text for post-training (`training_capture` in Rust).
    public var trainingCapture = false
    /// Learn from the user fixing a dictated word in place: misheard names join the vocabulary
    /// and repeated mishearings become corrections. Only `heard → intended` word pairs are kept,
    /// never the sentence (`learn_from_edits` in Rust, on by default).
    public var learnFromEdits = true
    /// The subset of `vocabularyHints` the edit watcher added, shown with a "Learned" marker. A
    /// separate list keeps `vocabularyHints` a plain string array for every other reader.
    public var learnedVocabularyHints: [String] = []

    // Mac-only (ignored by the Rust app).
    /// Download links for models, by model id (`SpeechModelCatalog`): an archive of the model's
    /// Core ML files (`ModelLink`). A model without one uses the standard download. The Tauri app
    /// keeps ONNX links under the same key, so they are never imported (`importingTauri`).
    public var modelLinks: [String: String] = [:]
    /// Put the previous clipboard back after pasting the dictation.
    public var restoreClipboard = true
    /// Where kept dictations go (`TrainingDataStore`); empty for the app's own folder.
    public var trainingDataFolder = ""
    /// Starred models in the Models library, by catalogue id (listed first).
    public var favoriteModels: [String] = []
    /// Show the words in the recording pill while the user speaks (local transcription only;
    /// the host protocol has no partial results).
    public var showTextWhileSpeaking = true
    /// Which style each app and website gets, and the default (`clean`).
    public var styleRules = StyleRules()
    /// Cleanup switches (Settings › Transcription): fillers, stutters and repeats.
    public var cleanupFillers = true
    /// Restarts and cue corrections ("no wait", "sorry", "scratch that").
    public var cleanupSelfCorrections = true
    /// Spoken punctuation and layout commands ("comma", "new line"), and the punctuation tidy.
    public var cleanupSpokenCommands = true

    public init() {}

    public var cleanupSettings: CleanupSettings {
        get { CleanupSettings(removeFillers: cleanupFillers, fixSelfCorrections: cleanupSelfCorrections, spokenCommands: cleanupSpokenCommands) }
        set {
            cleanupFillers = newValue.removeFillers
            cleanupSelfCorrections = newValue.fixSelfCorrections
            cleanupSpokenCommands = newValue.spokenCommands
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        transcriptionLocation = c.lenient(TranscriptionLocation.self, .transcriptionLocation) ?? d.transcriptionLocation
        model = c.lenient(String.self, .model) ?? d.model
        remoteUrl = c.lenient(String.self, .remoteUrl) ?? d.remoteUrl
        remoteAuthToken = c.lenient(String.self, .remoteAuthToken) ?? d.remoteAuthToken
        remoteTimeoutSeconds = c.lenientInt(.remoteTimeoutSeconds) ?? d.remoteTimeoutSeconds
        cloudAuthToken = c.lenient(String.self, .cloudAuthToken) ?? d.cloudAuthToken
        language = c.lenient(String.self, .language) ?? d.language
        audioDevice = c.lenient(String.self, .audioDevice) ?? d.audioDevice
        noiseSuppression = c.lenient(Bool.self, .noiseSuppression) ?? d.noiseSuppression
        echoCancellation = c.lenient(Bool.self, .echoCancellation) ?? d.echoCancellation
        inputGain = c.lenientInt(.inputGain) ?? d.inputGain
        postProcess = c.lenient(Bool.self, .postProcess) ?? d.postProcess
        vocabularyHints = c.lenient([String].self, .vocabularyHints) ?? d.vocabularyHints
        enabledPacks = c.lenient([String].self, .enabledPacks) ?? d.enabledPacks
        transcriptCorrections = c.lenient([TranscriptCorrection].self, .transcriptCorrections) ?? d.transcriptCorrections
        snippets = c.lenient([Snippet].self, .snippets) ?? d.snippets
        alwaysOnTop = c.lenient(Bool.self, .alwaysOnTop) ?? d.alwaysOnTop
        interactionSounds = c.lenient(Bool.self, .interactionSounds) ?? d.interactionSounds
        maxRecordingSeconds = c.lenientInt(.maxRecordingSeconds) ?? d.maxRecordingSeconds
        noteRetentionMinutes = c.lenientInt(.noteRetentionMinutes) ?? d.noteRetentionMinutes
        useGpu = c.lenient(Bool.self, .useGpu) ?? d.useGpu
        recordingShortcut = c.lenient(String.self, .recordingShortcut) ?? d.recordingShortcut
        recordingShortcutMode = c.lenient(RecordingShortcutMode.self, .recordingShortcutMode) ?? d.recordingShortcutMode
        transcriptStackShortcut = c.lenient(String.self, .transcriptStackShortcut) ?? d.transcriptStackShortcut
        insertAtCursor = c.lenient(Bool.self, .insertAtCursor) ?? d.insertAtCursor
        accessibilityInsert = c.lenient(Bool.self, .accessibilityInsert) ?? d.accessibilityInsert
        fnPushToTalk = c.lenient(Bool.self, .fnPushToTalk) ?? d.fnPushToTalk
        polishEnabled = c.lenient(Bool.self, .polishEnabled) ?? d.polishEnabled
        polishProvider = c.lenient(String.self, .polishProvider) ?? d.polishProvider
        polishModel = c.lenient(String.self, .polishModel) ?? d.polishModel
        polishTones = c.lenient([String: String].self, .polishTones) ?? d.polishTones
        contextAwareness = c.lenient(Bool.self, .contextAwareness) ?? d.contextAwareness
        trainingCapture = c.lenient(Bool.self, .trainingCapture) ?? d.trainingCapture
        learnFromEdits = c.lenient(Bool.self, .learnFromEdits) ?? d.learnFromEdits
        learnedVocabularyHints = c.lenient([String].self, .learnedVocabularyHints) ?? d.learnedVocabularyHints
        modelLinks = c.lenient([String: String].self, .modelLinks) ?? d.modelLinks
        restoreClipboard = c.lenient(Bool.self, .restoreClipboard) ?? d.restoreClipboard
        trainingDataFolder = c.lenient(String.self, .trainingDataFolder) ?? d.trainingDataFolder
        favoriteModels = c.lenient([String].self, .favoriteModels) ?? d.favoriteModels
        showTextWhileSpeaking = c.lenient(Bool.self, .showTextWhileSpeaking) ?? d.showTextWhileSpeaking
        styleRules = c.lenient(StyleRules.self, .styleRules) ?? d.styleRules
        cleanupFillers = c.lenient(Bool.self, .cleanupFillers) ?? d.cleanupFillers
        cleanupSelfCorrections = c.lenient(Bool.self, .cleanupSelfCorrections) ?? d.cleanupSelfCorrections
        cleanupSpokenCommands = c.lenient(Bool.self, .cleanupSpokenCommands) ?? d.cleanupSpokenCommands
        self = normalized()
    }

    /// Same clamps and clean-ups as `normalize` in settings.rs.
    public func normalized() -> AppSettings {
        var s = self
        s.inputGain = min(max(s.inputGain, 1), 6)
        s.maxRecordingSeconds = min(max(s.maxRecordingSeconds, 10), 600)
        s.remoteTimeoutSeconds = min(max(s.remoteTimeoutSeconds, 5), 300)
        s.remoteUrl = s.remoteUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.remoteUrl.hasSuffix("/") { s.remoteUrl.removeLast() }
        s.cloudAuthToken = s.cloudAuthToken.trimmingCharacters(in: .whitespacesAndNewlines)
        s.trainingDataFolder = s.trainingDataFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        s.vocabularyHints = Self.normalizeVocabulary(s.vocabularyHints)
        s.learnedVocabularyHints = Self.normalizeLearnedVocabulary(s.learnedVocabularyHints, vocabulary: s.vocabularyHints)
        s.transcriptCorrections = Self.normalizeCorrections(s.transcriptCorrections)
        s.enabledPacks = VocabularyPacks.normalizeEnabled(s.enabledPacks)
        if s.recordingShortcut.trimmingCharacters(in: .whitespaces).isEmpty { s.recordingShortcut = AcceleratorString.defaultRecording }
        if s.transcriptStackShortcut.trimmingCharacters(in: .whitespaces).isEmpty { s.transcriptStackShortcut = AcceleratorString.defaultTranscriptStack }
        // Trimmed, blank ones dropped; a value that can't be a link is kept so the download says why.
        s.modelLinks = ModelLink.normalizeMap(s.modelLinks)
        // Unknown ids (e.g. Whisper models from the Tauri app) fall back to the default, as in Rust.
        if SpeechModelCatalog.model(id: s.model) == nil { s.model = SpeechModelCatalog.defaultModelID }
        var seen = Set<String>()
        s.favoriteModels = s.favoriteModels.filter { SpeechModelCatalog.model(id: $0) != nil && seen.insert($0).inserted }
        s.styleRules = s.styleRules.normalized()
        return s
    }

    /// Keys the Tauri app writes that mean something else here, left out of an import: its
    /// `modelLinks` point at ONNX models, and `modelSource` is a setting this app no longer has.
    public static let tauriKeysNotImported = ["modelLinks", "modelSource"]

    /// Reads the Tauri app's settings.json for the one-time import: the settings, and the raw
    /// keys to keep in this app's file, both without `tauriKeysNotImported`. Nil when it isn't
    /// a settings file.
    public static func importingTauri(_ data: Data) -> (settings: AppSettings, raw: [String: JSONValue])? {
        guard var settings = try? JSONDecoder().decode(AppSettings.self, from: data) else { return nil }
        var raw = (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue ?? [:]
        for key in tauriKeysNotImported { raw[key] = nil }
        settings.modelLinks = [:]
        return (settings, raw)
    }

    /// Most vocabulary terms kept (`normalize_vocabulary_hints`).
    public static let maxVocabularyHints = 50
    /// Most corrections kept (`normalize_transcript_corrections`).
    public static let maxCorrections = 100

    /// Trim, collapse whitespace, cap at 100 characters, de-duplicate, keep at most 50.
    public static func normalizeVocabulary(_ hints: [String]) -> [String] {
        var out: [String] = []
        for hint in hints {
            let clean = cleanText(hint, max: 100)
            guard !clean.isEmpty, !out.contains(clean) else { continue }
            out.append(clean)
            if out.count >= maxVocabularyHints { break }
        }
        return out
    }

    /// Learned markers only survive for terms still in the vocabulary, so removing a term also
    /// removes its marker (`normalize_learned_hints`).
    public static func normalizeLearnedVocabulary(_ learned: [String], vocabulary: [String]) -> [String] {
        var out: [String] = []
        for hint in learned {
            let clean = cleanText(hint, max: 100)
            if vocabulary.contains(clean) && !out.contains(clean) { out.append(clean) }
        }
        return out
    }

    /// Same as `normalize_transcript_corrections`: both sides trimmed and capped at 120
    /// characters, blank ones dropped, at most 8 distinct model scopes, at most 100 in all.
    public static func normalizeCorrections(_ corrections: [TranscriptCorrection]) -> [TranscriptCorrection] {
        var out: [TranscriptCorrection] = []
        for correction in corrections {
            var clean = correction
            clean.from = cleanText(correction.from, max: 120)
            clean.to = cleanText(correction.to, max: 120)
            guard !clean.from.isEmpty, !clean.to.isEmpty else { continue }
            var models: [String] = []
            for model in correction.models {
                let id = cleanText(model, max: 80)
                if !id.isEmpty && !models.contains(id) && models.count < 8 { models.append(id) }
            }
            clean.models = models
            out.append(clean)
            if out.count >= maxCorrections { break }
        }
        return out
    }

    /// Whitespace collapsed to single spaces, then cut to `max` characters (`clean_text_setting`).
    static func cleanText(_ value: String, max: Int) -> String {
        String(value.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(max))
    }

    /// The id a correction's `models` scope matches (`speech_model_id` in settings.rs): the local
    /// speech model, or the location for a remote host, which chooses its own model.
    public var speechModelID: String {
        switch transcriptionLocation {
        case .local: model
        case .remoteHost: "remote-host"
        case .cloud: "cloud"
        }
    }
}
