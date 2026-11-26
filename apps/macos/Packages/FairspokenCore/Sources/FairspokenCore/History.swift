import Foundation

/// Where the wait between releasing the key and seeing text went (`DictationTimings` in Rust).
public struct DictationTimings: Codable, Equatable, Sendable {
    public var transcribeMs: Int = 0
    public var speechModelMs: Int = 0
    public var polishMs: Int = 0
    public var totalMs: Int = 0
    public init(transcribeMs: Int, speechModelMs: Int, polishMs: Int = 0, totalMs: Int) {
        self.transcribeMs = transcribeMs
        self.speechModelMs = speechModelMs
        self.polishMs = polishMs
        self.totalMs = totalMs
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        transcribeMs = c.lenientInt(.transcribeMs) ?? 0
        speechModelMs = c.lenientInt(.speechModelMs) ?? 0
        polishMs = c.lenientInt(.polishMs) ?? 0
        totalMs = c.lenientInt(.totalMs) ?? 0
    }
}

/// One `transcript-history.json` entry, compatible with `TranscriptHistoryItem` in Rust.
/// `model`, `appName`, `appBundleId` and everything from `cleanupEdits` on are Mac-only
/// additions: optional, omitted when nil, and ignored by the Rust app.
public struct TranscriptHistoryItem: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var createdAt: Int64
    public var text: String
    public var backend: String
    public var location: String
    public var durationSeconds: Double
    public var polished = false
    public var rawText: String?
    public var timings: DictationTimings?
    public var model: String?
    public var appName: String?
    public var appBundleId: String?
    /// What cleanup and the style changed, in transcript order.
    public var cleanupEdits: [CleanupEdit]?
    /// `DictationStyle.ID` raw value ("clean", "email"…).
    public var style: String?
    /// Why that style: "Mail rule", "You chose this", "mail.google.com".
    public var styleReason: String?
    /// The website's host when the dictation went to a browser.
    public var destinationHost: String?
    /// A note written or dictated in Bark itself.
    public var isNote: Bool?
    /// Time post-processing took.
    public var cleanupMs: Int?
    /// True when nothing could take the paste and the text went to the clipboard instead.
    public var clipboardOnly: Bool?
    /// The post-training recording kept for it (`TrainingEntry.id`), so it can be transcribed again.
    public var recordingID: String?

    public init(id: String, createdAt: Int64, text: String, backend: String, location: String, durationSeconds: Double,
                timings: DictationTimings? = nil, model: String? = nil, appName: String? = nil, appBundleId: String? = nil,
                rawText: String? = nil, cleanupEdits: [CleanupEdit]? = nil, style: String? = nil, styleReason: String? = nil,
                destinationHost: String? = nil, isNote: Bool? = nil, cleanupMs: Int? = nil, clipboardOnly: Bool? = nil,
                recordingID: String? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.text = text
        self.backend = backend
        self.location = location
        self.durationSeconds = durationSeconds
        self.timings = timings
        self.model = model
        self.appName = appName
        self.appBundleId = appBundleId
        self.rawText = rawText
        self.cleanupEdits = cleanupEdits
        self.style = style
        self.styleReason = styleReason
        self.destinationHost = destinationHost
        self.isNote = isNote
        self.cleanupMs = cleanupMs
        self.clipboardOnly = clipboardOnly
        self.recordingID = recordingID
    }

    /// A note typed (or dictated) into Bark itself, in the notes style.
    public static func note(_ text: String, rawText: String? = nil, edits: [CleanupEdit]? = nil, durationSeconds: Double = 0,
                            at date: Date = Date(), cleanupMs: Int? = nil, appName: String? = nil,
                            appBundleId: String? = nil) -> TranscriptHistoryItem {
        let ms = Int64(date.timeIntervalSince1970 * 1000)
        return TranscriptHistoryItem(id: "note-\(ms)", createdAt: ms, text: text, backend: "typed", location: "local",
                                     durationSeconds: durationSeconds, appName: appName, appBundleId: appBundleId,
                                     rawText: rawText, cleanupEdits: edits,
                                     style: DictationStyle.ID.notes.rawValue, styleReason: "Note in Bark", isNote: true,
                                     cleanupMs: cleanupMs)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenientID(.id) ?? UUID().uuidString
        createdAt = Int64(c.lenientDouble(.createdAt) ?? 0)
        text = c.lenient(String.self, .text) ?? ""
        backend = c.lenient(String.self, .backend) ?? "parakeet"
        location = c.lenient(String.self, .location) ?? "local"
        durationSeconds = c.lenientDouble(.durationSeconds) ?? 0
        polished = c.lenient(Bool.self, .polished) ?? false
        rawText = c.lenient(String.self, .rawText)
        timings = c.lenient(DictationTimings.self, .timings)
        model = c.lenient(String.self, .model)
        appName = c.lenient(String.self, .appName)
        appBundleId = c.lenient(String.self, .appBundleId)
        cleanupEdits = c.lenient([LenientElement<CleanupEdit>].self, .cleanupEdits).map { $0.compactMap(\.value) }
        style = c.lenient(String.self, .style)
        styleReason = c.lenient(String.self, .styleReason)
        destinationHost = c.lenient(String.self, .destinationHost)
        isNote = c.lenient(Bool.self, .isNote)
        cleanupMs = c.lenientInt(.cleanupMs)
        clipboardOnly = c.lenient(Bool.self, .clipboardOnly)
        recordingID = c.lenient(String.self, .recordingID)
    }

    /// The style as a value, when it is one this build knows.
    public var styleID: DictationStyle.ID? { style.flatMap(DictationStyle.ID.init(rawValue:)) }

    public var date: Date { Date(timeIntervalSince1970: Double(createdAt) / 1000) }
    public var wordCount: Int { WordCounter.count(text) }
    /// A note written in Bark, not a dictation into another app.
    public var isBarkNote: Bool { isNote == true }
}

public enum TranscriptHistory {
    /// History is the app's main navigation now, so it keeps far more than the Rust app's 50.
    public static let maxItems = 1_000

    /// Inserts newest-first, de-duplicating on normalised text and capping like the Rust service.
    public static func adding(_ item: TranscriptHistoryItem, to items: [TranscriptHistoryItem]) -> [TranscriptHistoryItem] {
        let key = normalize(item.text)
        // A length far off can't normalise to the same text: skips the work for most of 1,000 items.
        let length = item.text.utf8.count
        var next = items.filter { abs($0.text.utf8.count - length) > 64 || normalize($0.text) != key }
        next.insert(item, at: 0)
        if next.count > maxItems { next.removeLast(next.count - maxItems) }
        return next
    }

    static func normalize(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

public enum WordCounter {
    public static func count(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }.count
    }
}

/// `usage-stats.json` (subset modelled; unknown keys such as the zero-edit ring are
/// preserved by the store). Day buckets are keyed by UTC day index, as in `usage_stats.rs`.
public struct UsageStats: Codable, Equatable, Sendable {
    public struct DayBucket: Codable, Equatable, Sendable {
        public var words: Int = 0
        public var recordingSeconds: Double = 0
        public var dictations: Int = 0
        public var completed: Int = 0
        public var edited: Int = 0
        public var polishedCompleted: Int = 0
        public var polishedEdited: Int = 0
        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            words = c.lenientInt(.words) ?? 0
            recordingSeconds = c.lenientDouble(.recordingSeconds) ?? 0
            dictations = c.lenientInt(.dictations) ?? 0
            completed = c.lenientInt(.completed) ?? 0
            edited = c.lenientInt(.edited) ?? 0
            polishedCompleted = c.lenientInt(.polishedCompleted) ?? 0
            polishedEdited = c.lenientInt(.polishedEdited) ?? 0
        }
    }

    /// The typing speed assumed when the speed test hasn't measured one.
    public static let typingWPM = 40.0
    /// The range a measured typing speed is kept within, as in `usage_stats.rs`.
    public static let measuredTypingRange = 5.0...400.0

    public var totalWords = 0
    public var totalRecordingSeconds: Double = 0
    public var totalDictations = 0
    public var days: [String: DayBucket] = [:]
    /// The user's own typing speed, from the speed test (shared with the desktop app's file).
    public var measuredTypingWpm: Double?

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalWords = c.lenientInt(.totalWords) ?? 0
        totalRecordingSeconds = c.lenientDouble(.totalRecordingSeconds) ?? 0
        totalDictations = c.lenientInt(.totalDictations) ?? 0
        days = c.lenient([String: DayBucket].self, .days) ?? [:]
        measuredTypingWpm = c.lenientDouble(.measuredTypingWpm).flatMap(Self.validTypingWPM)
    }

    /// A measured speed kept within `measuredTypingRange`, or nil when it isn't a speed at all.
    public static func validTypingWPM(_ wpm: Double) -> Double? {
        guard wpm.isFinite, wpm > 0 else { return nil }
        return min(max(wpm, measuredTypingRange.lowerBound), measuredTypingRange.upperBound)
    }

    /// The typing speed time saved is counted against: the measured one, else `typingWPM`.
    public var typingWPMInUse: Double { measuredTypingWpm ?? Self.typingWPM }

    /// How long typing every dictated word would have taken at `typingWPMInUse`.
    public var typingSeconds: Double { Double(totalWords) / typingWPMInUse * 60 }

    public static func dayIndex(_ date: Date) -> Int { Int((date.timeIntervalSince1970 / 86_400).rounded(.down)) }

    public mutating func record(words: Int, recordingSeconds: Double, at date: Date = Date()) {
        totalWords += words
        totalRecordingSeconds += recordingSeconds
        totalDictations += 1
        let key = String(Self.dayIndex(date))
        var bucket = days[key] ?? DayBucket()
        bucket.words += words
        bucket.recordingSeconds += recordingSeconds
        bucket.dictations += 1
        bucket.completed += 1
        days[key] = bucket
    }

    public func bucket(daysAgo: Int, from now: Date = Date()) -> DayBucket {
        days[String(Self.dayIndex(now) - daysAgo)] ?? DayBucket()
    }

    /// Oldest → newest, `count` days ending today.
    public func series(days count: Int, from now: Date = Date()) -> [(date: Date, bucket: DayBucket)] {
        (0..<count).reversed().map { ago in
            (now.addingTimeInterval(-Double(ago) * 86_400), bucket(daysAgo: ago, from: now))
        }
    }

    public func words(lastDays count: Int, from now: Date = Date()) -> Int {
        (0..<count).reduce(0) { $0 + bucket(daysAgo: $1, from: now).words }
    }

    /// Consecutive days with at least one dictation, ending today (or yesterday if none yet today).
    public func streak(from now: Date = Date()) -> Int {
        var ago = bucket(daysAgo: 0, from: now).dictations > 0 ? 0 : 1
        var n = 0
        while bucket(daysAgo: ago, from: now).dictations > 0 { n += 1; ago += 1 }
        return n
    }

    /// Time saved against typing the same words at `typingWPMInUse`, in seconds.
    public var timeSavedSeconds: Double {
        max(0, typingSeconds - totalRecordingSeconds)
    }

    public var speakingWPM: Double? {
        totalRecordingSeconds > 60 ? Double(totalWords) / (totalRecordingSeconds / 60) : nil
    }
}
