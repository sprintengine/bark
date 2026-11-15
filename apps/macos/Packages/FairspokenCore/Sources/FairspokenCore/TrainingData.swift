import Foundation

/// The kind of app a dictation went into: `AppCategory` in `src-tauri/src/app_categories.rs`
/// (same bundle-id prefixes, same ids). Only the category is kept with a recording, never the
/// app's name or window contents.
public enum AppCategory: String, Sendable, CaseIterable {
    case messaging, email, docs, code, terminal, other

    /// Bundle-id prefixes, as in the Rust table (JetBrains ships many ids under `com.jetbrains.`).
    static let table: [(String, AppCategory)] = [
        ("com.tinyspeck.slackmacgap", .messaging), ("com.apple.MobileSMS", .messaging),
        ("net.whatsapp.WhatsApp", .messaging), ("com.hnc.Discord", .messaging),
        ("org.telegram.desktop", .messaging), ("ru.keepcoder.Telegram", .messaging),
        ("com.microsoft.teams2", .messaging), ("us.zoom.xos", .messaging),
        ("com.apple.mail", .email), ("com.microsoft.Outlook", .email), ("com.superhuman.electron", .email),
        ("com.readdle.SparkDesktop", .email), ("com.mimestream.Mimestream", .email),
        ("com.apple.iWork.Pages", .docs), ("com.microsoft.Word", .docs), ("com.apple.Notes", .docs),
        ("md.obsidian", .docs), ("notion.id", .docs), ("com.literatureandlatte.scrivener3", .docs),
        ("com.microsoft.VSCode", .code), ("com.todesktop.230313mzl4w4u92", .code), ("com.jetbrains.", .code),
        ("dev.zed.Zed", .code), ("com.sublimetext.4", .code), ("com.apple.dt.Xcode", .code),
        ("com.apple.Terminal", .terminal), ("com.googlecode.iterm2", .terminal), ("dev.warp.Warp-Stable", .terminal),
        ("com.github.wez.wezterm", .terminal), ("net.kovidgoyal.kitty", .terminal),
        ("com.mitchellh.ghostty", .terminal), ("co.zeit.hyper", .terminal),
    ]

    public static func of(bundleID: String?) -> AppCategory {
        guard let bundleID, !bundleID.isEmpty else { return .other }
        return table.first { bundleID.hasPrefix($0.0) }?.1 ?? .other
    }
}

/// One kept dictation: `CaptureEntry` in `src-tauri/src/training_capture.rs`, field for field
/// (camelCase, absent optionals omitted), so both apps' folders read the same way and
/// `training/` tools take either.
public struct TrainingEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    /// Epoch seconds.
    public var createdAt: Int64
    public var durationSeconds: Double
    /// The model that heard it (`parakeet-ultra`…), or what the host reported.
    public var speechModel: String
    /// `AppCategory` id of the app dictated into.
    public var appCategory: String
    /// The speech model's text, before corrections.
    public var rawText: String
    /// The polish model's text, when polish changed anything (never set by the Mac app yet).
    public var polishedText: String?
    /// What was inserted.
    public var finalText: String
    /// The dictation as the user left it, when an edit was seen.
    public var editedText: String?

    public init(id: String = UUID().uuidString.lowercased(), createdAt: Int64, durationSeconds: Double, speechModel: String,
                appCategory: String, rawText: String, polishedText: String? = nil, finalText: String, editedText: String? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.durationSeconds = durationSeconds
        self.speechModel = speechModel
        self.appCategory = appCategory
        self.rawText = rawText
        self.polishedText = polishedText
        self.finalText = finalText
        self.editedText = editedText
    }

    public var date: Date { Date(timeIntervalSince1970: TimeInterval(createdAt)) }
}

/// Totals for the Post-training screen.
public struct TrainingSummary: Equatable, Sendable {
    public var count = 0
    public var seconds: Double = 0
    public var bytes: Int64 = 0

    public init() {}

    public init(_ entries: [TrainingEntry]) {
        count = entries.count
        seconds = entries.reduce(0) { $0 + $1.durationSeconds }
        // A WAV is a 44-byte header and 2 bytes a sample: exact without walking the folder.
        bytes = entries.reduce(0) { $0 + 44 + Int64(($1.durationSeconds * TrainingDataStore.sampleRate).rounded()) * 2 }
    }

    /// How far toward `TrainingReadiness.recommendedSeconds`, 0…1.
    public var progress: Double { min(1, seconds / TrainingReadiness.recommendedSeconds) }
    public var isEnoughToTrain: Bool { seconds >= TrainingReadiness.minimumSeconds }
}

/// How much speech post-training wants. Single-speaker adaptation papers report most of the
/// gain from tens of minutes of transcribed speech; labels from a stronger model are noisier
/// than hand transcripts, so we ask for more.
public enum TrainingReadiness {
    public static let minimumSeconds: Double = 60 * 60
    public static let recommendedSeconds: Double = 10 * 60 * 60
}

/// The training-data folder, in the Rust layout:
///
/// ```text
/// <root>/
///   index.jsonl          one TrainingEntry per line
///   <id>/audio.wav       16 kHz mono 16-bit PCM
///   <id>/meta.json       the same TrainingEntry
/// ```
///
/// Never creates `root` itself: on an external drive that isn't mounted, creating it would
/// quietly fill the startup disk under `/Volumes`. The app creates it when the folder is chosen.
/// Not thread-safe; the app calls it from one serial queue.
///
/// Recordings are hard to replace, so nothing here removes more than it must: deletions move
/// folders to the Trash unless the caller asks for `.permanent` (the app only does after the user
/// confirms it), only folders the index names are touched, ids are checked before they become
/// paths, an index that can't be read is never rewritten, and a rewrite keeps every line it
/// couldn't decode, byte for byte.
///
/// The desktop app can share the folder, so both hold an advisory `flock` on `.index.lock` around
/// anything that reads and then writes the index. The index itself is never locked: rewrites
/// replace it.
public struct TrainingDataStore: Sendable {
    public static let sampleRate: Double = 16_000
    public static let indexFile = "index.jsonl"
    public static let audioFile = "audio.wav"
    public static let metaFile = "meta.json"
    /// Advisory lock shared with the desktop app (`LOCK_FILE` in training_capture.rs).
    public static let lockFile = ".index.lock"
    /// How long to wait for the other app to finish with the index.
    static let lockWait: TimeInterval = 2

    public enum StoreError: LocalizedError, Equatable {
        case folderUnavailable(String)
        case indexUnreadable(String)
        /// Moving to the Trash failed, e.g. on a volume without one. Nothing was deleted.
        case couldNotTrash(String)
        /// The other app held the index lock too long. Nothing was changed.
        case busy(String)

        public var errorDescription: String? {
            switch self {
            case .folderUnavailable(let path): "The recordings folder isn't available (\(path)). Is the drive connected?"
            case .indexUnreadable(let path): "Couldn't read the recordings index in \(path), so it was left as it is."
            case .couldNotTrash(let path): "Couldn't move recordings in \(path) to the Trash."
            case .busy(let path): "The recordings in \(path) are busy in another app. Try again."
            }
        }
    }

    /// How a deletion removes a recording's folder.
    public enum Removal: Sendable {
        /// To the Trash, so a mistake can be undone.
        case trash
        /// For good: only after the user confirms it, when the Trash can't be used.
        case permanent
    }

    /// One line of index.jsonl: an entry, or a line this build can't decode (damaged, a newer
    /// format, an unsafe id), which is written back exactly as it was.
    enum IndexLine {
        case entry(TrainingEntry)
        case unreadable(Data)
    }

    public let root: URL

    public init(root: URL) { self.root = root }

    public var isAvailable: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private var indexURL: URL { root.appendingPathComponent(Self.indexFile) }

    /// An id names a folder under `root`, so it must be one plain path component: not empty,
    /// no separators, no `..`, not absolute.
    public static func isSafeID(_ id: String) -> Bool {
        !id.isEmpty && id != "." && !id.contains("..") && !id.contains("/") && !id.contains("\\")
            && !id.contains(":") && !id.contains("\0")
    }

    public func audioURL(for id: String) -> URL {
        root.appendingPathComponent(id, isDirectory: true).appendingPathComponent(Self.audioFile)
    }

    /// Writes the dictation's folder, then appends it to the index.
    public func record(_ entry: TrainingEntry, samples: [Float]) throws {
        guard isAvailable else { throw StoreError.folderUnavailable(root.path) }
        guard Self.isSafeID(entry.id) else { throw CocoaError(.fileWriteInvalidFileName) }
        let folder = root.appendingPathComponent(entry.id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        Self.restrict(folder, to: 0o700)
        try Self.private(Self.wav(samples), at: folder.appendingPathComponent(Self.audioFile))
        try Self.private(Self.metaEncoder.encode(entry), at: folder.appendingPathComponent(Self.metaFile))
        try appendToIndex(entry)
    }

    /// Every readable entry, oldest first; a damaged line is skipped, not fatal.
    public func entries() -> [TrainingEntry] {
        ((try? readIndex()) ?? []).compactMap {
            if case .entry(let entry) = $0 { entry } else { nil }
        }
    }

    /// Moves one recording to the Trash (or deletes it, with `.permanent`), then drops its line
    /// from the index. Throws `couldNotTrash` with nothing changed when the Trash can't be used.
    public func delete(_ id: String, removal: Removal = .trash) throws {
        guard isAvailable else { throw StoreError.folderUnavailable(root.path) }
        guard Self.isSafeID(id) else { return }
        guard let lock = lockIndex() else { throw StoreError.busy(root.path) }
        defer { close(lock) }
        var lines = try readIndex()
        try removeFolder(id, removal)
        let before = lines.count
        lines.removeAll { if case .entry(let entry) = $0 { entry.id == id } else { false } }
        if lines.count != before { try writeIndex(lines) }
    }

    /// Removes every kept dictation, and only those: the folders the index names, then their
    /// lines. Anything else in the folder, and lines this build can't decode, stay. Stops at the
    /// first folder it can't remove, keeping the index lines of everything not yet removed.
    public func deleteAll(removal: Removal = .trash) throws {
        guard isAvailable else { throw StoreError.folderUnavailable(root.path) }
        guard let lock = lockIndex() else { throw StoreError.busy(root.path) }
        defer { close(lock) }
        var remaining: [IndexLine] = []
        var failure: Error?
        for line in try readIndex() {
            if failure == nil, case .entry(let entry) = line {
                do {
                    try removeFolder(entry.id, removal)
                    continue
                } catch {
                    failure = error
                }
            }
            remaining.append(line)
        }
        if remaining.isEmpty {
            // Every entry's text is also in its meta.json, which went with its folder.
            if FileManager.default.fileExists(atPath: indexURL.path) { try FileManager.default.removeItem(at: indexURL) }
        } else {
            try writeIndex(remaining)
        }
        if let failure { throw failure }
    }

    /// Rebuilds index.jsonl from each `<id>/meta.json`, e.g. after recordings were put back from
    /// the Trash or copied in by hand. Folders whose meta.json is missing, unreadable or names
    /// another id are left out. The old index is copied beside it first
    /// (`index.jsonl.<epoch>-<suffix>.bak`) and its undecodable lines are carried over.
    /// Returns how many entries the new index lists.
    @discardableResult
    public func rebuildIndex() throws -> Int {
        guard isAvailable else { throw StoreError.folderUnavailable(root.path) }
        guard let lock = lockIndex() else { throw StoreError.busy(root.path) }
        defer { close(lock) }
        let fm = FileManager.default
        let decoder = JSONDecoder()
        var rebuilt: [TrainingEntry] = []
        for folder in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            let id = folder.lastPathComponent
            guard Self.isSafeID(id), (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let data = try? Data(contentsOf: folder.appendingPathComponent(Self.metaFile)),
                  let entry = try? decoder.decode(TrainingEntry.self, from: data), entry.id == id
            else { continue }
            rebuilt.append(entry)
        }
        rebuilt.sort { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        var lines = rebuilt.map(IndexLine.entry)
        if fm.fileExists(atPath: indexURL.path) {
            let old = try readIndex()
            let suffix = UUID().uuidString.prefix(8).lowercased()
            let backup = root.appendingPathComponent("\(Self.indexFile).\(Int(Date().timeIntervalSince1970))-\(suffix).bak")
            try fm.copyItem(at: indexURL, to: backup)
            lines += old.filter { if case .unreadable = $0 { true } else { false } }
        }
        try writeIndex(lines)
        return rebuilt.count
    }

    // MARK: Files

    private static let metaEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    /// Every line of the index. A missing index is empty; one that exists but can't be read
    /// throws, so it is never rewritten from nothing.
    func readIndex() throws -> [IndexLine] {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return [] }
        let data: Data
        do { data = try Data(contentsOf: indexURL) } catch { throw StoreError.indexUnreadable(root.path) }
        let decoder = JSONDecoder()
        return data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true).compactMap { slice in
            let line = Data(slice)
            if line.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) { return nil }
            if let entry = try? decoder.decode(TrainingEntry.self, from: line), Self.isSafeID(entry.id) { return .entry(entry) }
            return .unreadable(line)
        }
    }

    private func removeFolder(_ id: String, _ removal: Removal) throws {
        guard Self.isSafeID(id) else { return }
        let folder = root.appendingPathComponent(id, isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        switch removal {
        case .trash:
            do {
                try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
            } catch {
                throw StoreError.couldNotTrash(root.path)
            }
        case .permanent:
            try FileManager.default.removeItem(at: folder)
        }
    }

    /// Waits for as long as the other app holds the index: appending without the lock could be
    /// undone by its rewrite. Callers are off the main thread, the audio and meta.json are already
    /// on disk, and the lock goes when the other app's process does.
    private func appendToIndex(_ entry: TrainingEntry) throws {
        let lock = try lockIndexWaiting()
        defer { close(lock) }
        var line = try JSONEncoder().encode(entry)
        line.append(UInt8(ascii: "\n"))
        if !FileManager.default.fileExists(atPath: indexURL.path) {
            try Self.private(line, at: indexURL)
            return
        }
        let handle = try FileHandle(forUpdating: indexURL)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        if end > 0 {
            // A last line without its newline would swallow this one.
            try handle.seek(toOffset: end - 1)
            if try handle.read(upToCount: 1) != Data([UInt8(ascii: "\n")]) { line.insert(UInt8(ascii: "\n"), at: 0) }
            try handle.seekToEnd()
        }
        try handle.write(contentsOf: line)
    }

    /// Takes the `flock` shared with the desktop app, however long that takes.
    func lockIndexWaiting() throws -> Int32 {
        let fd = open(root.appendingPathComponent(Self.lockFile).path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else {
                close(fd)
                throw CocoaError(.fileWriteUnknown)
            }
        }
        return fd
    }

    /// Takes the `flock` shared with the desktop app, waiting up to `lockWait`. Returns the open
    /// descriptor (closing it releases the lock), or nil if the lock is still held.
    func lockIndex() -> Int32? {
        let fd = open(root.appendingPathComponent(Self.lockFile).path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        let deadline = Date().addingTimeInterval(Self.lockWait)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK, Date() < deadline else {
                close(fd)
                return nil
            }
            usleep(25_000)
        }
        return fd
    }

    /// Replaces the index atomically (`Data.write(options: .atomic)`).
    private func writeIndex(_ lines: [IndexLine]) throws {
        let encoder = JSONEncoder()
        var payload = Data()
        for line in lines {
            switch line {
            case .entry(let entry): payload.append(try encoder.encode(entry))
            case .unreadable(let bytes): payload.append(bytes)
            }
            payload.append(UInt8(ascii: "\n"))
        }
        try Self.private(payload, at: indexURL)
    }

    /// Atomic, owner-only: kept dictations can hold anything the user said.
    private static func `private`(_ data: Data, at url: URL) throws {
        try data.write(to: url, options: .atomic)
        restrict(url, to: 0o600)
    }

    /// Best effort: exFAT and network volumes don't keep POSIX modes.
    private static func restrict(_ url: URL, to mode: Int) {
        try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    /// 16 kHz mono 16-bit PCM WAV.
    public static func wav(_ samples: [Float]) -> Data {
        let pcm = PCM.int16(from: samples)
        let dataBytes = UInt32(pcm.count * 2)
        let rate = UInt32(sampleRate)
        var out = Data(capacity: 44 + Int(dataBytes))
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) } }
        out.append(contentsOf: Array("RIFF".utf8)); append(36 + dataBytes)
        out.append(contentsOf: Array("WAVE".utf8))
        out.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1))  // PCM, mono
        append(rate); append(rate * 2)       // sample rate, byte rate
        append(UInt16(2)); append(UInt16(16)) // block align, bits per sample
        out.append(contentsOf: Array("data".utf8)); append(dataBytes)
        // Apple silicon is little-endian, as WAV is: the samples go in as they are.
        pcm.withUnsafeBytes { out.append(contentsOf: $0) }
        return out
    }
}
