import Foundation
import FairspokenCore
import Observation
import OSLog

/// Dictations and notes (`transcript-history.json`, up to `TranscriptHistory.maxItems`, the Rust
/// schema plus optional fields) and lifetime usage (`usage-stats.json`). Both import once from the
/// Tauri app. History is the main window's thread list.
@Observable
final class HistoryStore {
    private(set) var items: [TranscriptHistoryItem] = []
    private(set) var usage = UsageStats()

    @ObservationIgnored private var usageRaw: [String: JSONValue] = [:]
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let persists: Bool
    private static let log = Logger(subsystem: AppInfo.bundleID, category: "history")

    init(directory: URL = AppInfo.supportDirectory, persists: Bool = !AppInfo.isDemo) {
        self.directory = directory
        self.persists = persists
        if persists {
            items = Self.load([TranscriptHistoryItem].self, "transcript-history.json", in: directory) ?? []
            if let data = Self.data("usage-stats.json", in: directory) {
                usage = (try? JSONDecoder().decode(UsageStats.self, from: data)) ?? UsageStats()
                usageRaw = (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue ?? [:]
            }
        } else {
            seedDemo()
        }
    }

    var historyURL: URL { directory.appendingPathComponent("transcript-history.json") }
    var usageURL: URL { directory.appendingPathComponent("usage-stats.json") }

    func add(_ item: TranscriptHistoryItem) {
        items = TranscriptHistory.adding(item, to: items)
        usage.record(words: item.wordCount, recordingSeconds: item.durationSeconds, at: item.date)
        save()
    }

    /// The speed test measured the user's typing: time saved is counted against it from now on
    /// (`measuredTypingWpm`, the key the desktop app uses).
    func setMeasuredTypingWPM(_ wpm: Int) {
        guard let valid = UsageStats.validTypingWPM(Double(wpm)) else { return }
        usage.measuredTypingWpm = valid
        save()
    }

    /// Back to the typical typing speed (`UsageStats.typingWPM`).
    func clearMeasuredTypingWPM() {
        usage.measuredTypingWpm = nil
        // Not modelled when nil, so the merge would otherwise keep the old value.
        usageRaw["measuredTypingWpm"] = nil
        save()
    }

    /// Screenshots: no measured typing speed (the assumed one), or a sample one. Never saved.
    func showcaseTypingWPM(_ wpm: Double?) {
        guard !persists else { return }
        usage.measuredTypingWpm = wpm
    }

    func delete(_ id: String) {
        items.removeAll { $0.id == id }
        save()
    }

    func item(_ id: String?) -> TranscriptHistoryItem? {
        guard let id else { return nil }
        return items.first { $0.id == id }
    }

    /// A note written (or dictated) in Bark itself: kept in history, never counted as dictated
    /// words. Returns its id.
    @discardableResult
    func addNote(_ text: String, at date: Date = Date()) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var note = TranscriptHistoryItem(id: "note-\(Int64(date.timeIntervalSince1970 * 1000))",
                                         createdAt: Int64(date.timeIntervalSince1970 * 1000), text: trimmed,
                                         backend: "typed", location: "local", durationSeconds: 0,
                                         appName: AppInfo.displayName, appBundleId: AppInfo.bundleID)
        note.isNote = true
        items = TranscriptHistory.adding(note, to: items)
        save()
        return note.id
    }

    /// Changes an item in place (a corrected text, a new transcription). Its place in the list stays.
    func update(_ id: String, _ change: (inout TranscriptHistoryItem) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
        save()
    }

    /// The thread list: newest first, narrowed by the search text and the filter.
    func visible(query: String, filter: AppModel.HistoryFilter) -> [TranscriptHistoryItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return items.filter { item in
            switch filter {
            case .all: break
            case .notes: if !item.isBarkNote { return false }
            case .clipboard: if item.clipboardOnly != true { return false }
            }
            guard !q.isEmpty else { return true }
            return item.text.localizedCaseInsensitiveContains(q) || (item.appName ?? "").localizedCaseInsensitiveContains(q)
                || (item.destinationHost ?? "").localizedCaseInsensitiveContains(q)
        }
    }

    /// Screenshots: a chosen set of dictations. Never saved.
    func showcase(_ demo: [TranscriptHistoryItem]) {
        guard !persists else { return }
        items = demo
    }

    /// Screenshots: shows no dictations (Home's first-use card), or the demo set again. Never saved.
    func showcaseEmpty(_ empty: Bool) {
        guard !persists else { return }
        if empty { items = []; usage = UsageStats() } else { seedDemo() }
    }

    /// Latency the user feels: release → text, median of recent dictations.
    var typicalLatencyMs: Int? {
        let values = items.prefix(20).compactMap { $0.timings?.totalMs }.filter { $0 > 0 }.sorted()
        guard !values.isEmpty else { return nil }
        return values[values.count / 2]
    }

    private func save() {
        guard persists else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            try encoder.encode(items).write(to: historyURL, options: .atomic)
            try JSONMerge.encode(usage, over: usageRaw).write(to: usageURL, options: .atomic)
        } catch {
            Self.log.error("Saving history failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func data(_ name: String, in dir: URL) -> Data? {
        if let d = try? Data(contentsOf: dir.appendingPathComponent(name)) { return d }
        // One-time import from the Tauri app; written to our directory on first save.
        guard let d = try? Data(contentsOf: AppInfo.tauriDirectory.appendingPathComponent(name)) else { return nil }
        try? d.write(to: dir.appendingPathComponent(name), options: .atomic)
        return d
    }

    private static func load<T: Decodable>(_ type: T.Type, _ name: String, in dir: URL) -> T? {
        guard let d = data(name, in: dir) else { return nil }
        return try? JSONDecoder().decode(type, from: d)
    }

    // MARK: Demo data (screenshots, `--demo`)

    private func seedDemo() {
        let now = Date()
        items = DemoHistory.items(now: now)
        var u = UsageStats()
        let perDay = [1_420, 2_310, 980, 2_760, 1_890, 260, 0, 1_640, 2_120, 1_310, 2_980, 2_240, 410, 1_186]
        for (ago, words) in perDay.enumerated() where words > 0 {
            let day = now.addingTimeInterval(-Double(perDay.count - 1 - ago) * 86_400)
            let n = max(1, words / 42)
            for _ in 0..<n { u.record(words: words / n, recordingSeconds: Double(words / n) / 2.4, at: day) }
        }
        u.totalWords += 418_000
        u.totalRecordingSeconds += 418_000 / 2.4
        u.totalDictations += 10_900
        usage = u
    }
}
