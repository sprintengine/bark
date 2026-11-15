import Foundation
import FairspokenCore
import Observation
import OSLog

/// What the app learned from the user's fixes (`learned.json`, the Tauri app's format) and the
/// Suggestions waiting for the user. Promotions go straight into settings as learned vocabulary
/// terms and corrections (`LearnedStore`); the file is written off the main thread.
@Observable
final class LearnedLibrary {
    private(set) var suggestions: [LearnedItem] = []
    /// The last thing learned, for the Vocabulary screen ("Learned from your edit: …").
    private(set) var lastChange: String?

    @ObservationIgnored private var store: LearnedStore
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let url: URL
    @ObservationIgnored private let persists: Bool
    @ObservationIgnored private let queue = DispatchQueue(label: "learned", qos: .utility)
    private static let log = Logger(subsystem: AppInfo.bundleID, category: "learned")

    /// Every medicine in the bundled Irish general practice pack (the same file the Tauri app
    /// bundles), so a mapping between two of them is only ever suggested. Read once, on first use.
    nonisolated static let drugs: DrugLexicon = {
        guard let url = Bundle.main.url(forResource: "ie-general-practice", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return .empty }
        return DrugLexicon(packs: [data])
    }()

    init(settings: SettingsStore, directory: URL = AppInfo.supportDirectory, persists: Bool = !AppInfo.isDemo) {
        self.settings = settings
        self.persists = persists
        url = directory.appendingPathComponent("learned.json")
        // Until this app has its own, the Tauri app's (as settings are imported once): its
        // learned entries came over with its settings, and what was dismissed or deleted there
        // must stay that way.
        let tauri = AppInfo.tauriDirectory.appendingPathComponent("learned.json")
        store = persists ? LearnedStore.load((try? Data(contentsOf: url)) ?? (try? Data(contentsOf: tauri))) : Self.demo()
        suggestions = store.suggestions
        // Off the main thread, well before the first fix needs it.
        DispatchQueue.global(qos: .utility).async { _ = Self.drugs }
    }

    /// Records one fix the edit watcher saw, scoped to `model` ("" for every model), and applies
    /// whatever it earns.
    func learn(_ fix: Mishearing, model: String) {
        store.drugs = Self.drugs
        let promotions = store.observe(fix, model: model, now: Int64(Date().timeIntervalSince1970))
        save()
        apply(promotions)
    }

    /// Accepts a suggestion: its correction joins the dictionary, marked learned.
    func accept(_ id: String) {
        let promotion = store.accept(id)
        save()
        if let promotion { apply([promotion]) }
    }

    /// Dismisses a suggestion for good.
    func dismiss(_ id: String) {
        store.dismiss(id)
        save()
    }

    private func apply(_ promotions: [Promotion]) {
        guard !promotions.isEmpty else { return }
        var changes: [String] = []
        settings.update { changes = LearnedStore.apply(promotions, to: &$0) }
        guard !changes.isEmpty else { return }
        lastChange = changes.joined(separator: "; ")
        Self.log.info("Learned from an edit: \(changes.count) change(s)")
    }

    private func save() {
        suggestions = store.suggestions
        guard persists else { return }
        let data: Data
        do { data = try store.encoded() } catch { return }
        let url = url
        queue.async {
            do {
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                Self.log.error("Saving learned words failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Screenshots and `--demo`: one suggestion of each kind.
    private static func demo() -> LearnedStore {
        LearnedStore(items: [
            LearnedItem(heard: "hydroxyzine", intended: "hydralazine", firstSeen: 0, lastSeen: 0,
                        models: ["parakeet-tdt-0.6b-v3"], status: .suggested, reason: LearnedStore.medicineReason),
            LearnedItem(heard: "an", intended: "and", count: 2, firstSeen: 0, lastSeen: 0,
                        models: ["parakeet-tdt-0.6b-v3"], status: .suggested, reason: LearnedStore.shortWordReason),
        ])
    }
}
