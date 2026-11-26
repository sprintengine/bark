import Foundation

/// One change the post-processing made to what was heard, in transcript order. Kept on each
/// history item (`TranscriptHistoryItem.cleanupEdits`) so the dictation view can list the changes
/// and dim the removed words.
public struct CleanupEdit: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// "um", "uh", and "you know" / "I mean" / "like" said as fillers.
        case filler
        /// Stutters and exact repeats ("the the").
        case repetition
        /// A clause abandoned and started again with the same words.
        case restart
        /// "Tuesday, no wait, Wednesday": the wrong part and the cue.
        case selfCorrection
        /// "new line", "full stop", "comma"…
        case spokenCommand
        /// Stray full stops, capitals and spacing.
        case punctuation
        /// A style's layout: greeting and sign-off lines, lists, headings, paragraphs.
        case formatting
        /// The user's vocabulary casing and corrections.
        case vocabulary
    }

    public var kind: Kind
    /// The text taken out (may be empty for a pure insertion, such as a line break).
    public var removed: String
    /// The text put in its place (empty for a pure removal).
    public var inserted: String

    public init(kind: Kind, removed: String, inserted: String = "") {
        self.kind = kind
        self.removed = removed
        self.inserted = inserted
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // An unknown kind (from a newer build) reads as formatting rather than dropping the edit.
        kind = c.lenient(Kind.self, .kind) ?? .formatting
        removed = c.lenient(String.self, .removed) ?? ""
        inserted = c.lenient(String.self, .inserted) ?? ""
    }
}

/// What post-processing hands the delivery step.
public struct PostProcessResult: Equatable, Sendable {
    /// The cleaned words, before a style's layout: what the dictation view diffs against
    /// `rawText`. Line breaks the speaker asked for ("new line") are kept.
    public var text: String
    /// What is pasted as plain text: `text` laid out by the style (greeting lines, lists…).
    public var plainText: String
    /// The same layout as minimal HTML, for apps that take rich text (email, notes, documents).
    public var html: String?
    public var edits: [CleanupEdit]
    public var style: DictationStyle.ID?
    public var styleReason: String?

    public init(text: String, plainText: String, html: String? = nil, edits: [CleanupEdit] = [],
                style: DictationStyle.ID? = nil, styleReason: String? = nil) {
        self.text = text
        self.plainText = plainText
        self.html = html
        self.edits = edits
        self.style = style
        self.styleReason = styleReason
    }
}

/// The user's cleanup switches (Settings › Transcription), stored flat in `AppSettings`.
public struct CleanupSettings: Equatable, Sendable {
    /// Fillers, stutters and exact repeats.
    public var removeFillers: Bool
    /// Restarts and cue corrections ("no wait", "sorry", "scratch that"…).
    public var fixSelfCorrections: Bool
    /// Spoken punctuation and layout commands, and the punctuation tidy.
    public var spokenCommands: Bool

    public init(removeFillers: Bool = true, fixSelfCorrections: Bool = true, spokenCommands: Bool = true) {
        self.removeFillers = removeFillers
        self.fixSelfCorrections = fixSelfCorrections
        self.spokenCommands = spokenCommands
    }

    public static let all = CleanupSettings()
}

/// Which cleanup stages run. A style picks a set (`DictationStyle.ID.cleanupOptions`) and the
/// user's switches turn stages off (`restricted(by:)`).
public struct CleanupOptions: Equatable, Sendable {
    public var fillers = true
    public var repeats = true
    public var restarts = true
    public var corrections = true
    public var spokenCommands = true
    /// Stray full stops and mid-sentence capitals, doubled punctuation.
    public var punctuationTidy = true
    /// Capitalise the first word of each sentence.
    public var sentenceCase = true
    /// Drop the full stop at the end of a single short message (casual).
    public var dropFinalFullStopWhenShort = false

    public init() {}

    public static let none: CleanupOptions = {
        var o = CleanupOptions()
        o.fillers = false
        o.repeats = false
        o.restarts = false
        o.corrections = false
        o.spokenCommands = false
        o.punctuationTidy = false
        o.sentenceCase = false
        return o
    }()

    public static let full = CleanupOptions()

    public var isEmpty: Bool { self == .none }

    public func restricted(by settings: CleanupSettings) -> CleanupOptions {
        var o = self
        if !settings.removeFillers { o.fillers = false; o.repeats = false }
        if !settings.fixSelfCorrections { o.restarts = false; o.corrections = false }
        if !settings.spokenCommands { o.spokenCommands = false; o.punctuationTidy = false }
        return o
    }
}
