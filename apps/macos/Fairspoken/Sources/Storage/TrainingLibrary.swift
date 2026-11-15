import AppKit
import FairspokenCore
import Observation
import OSLog

/// Kept dictations for post-training (Settings key `trainingCapture`, off by default), in
/// `trainingDataFolder` or the app's own folder. Files are written off the main thread, on one
/// serial queue, in the Rust app's layout (`TrainingDataStore`).
@Observable
final class TrainingLibrary {
    /// Newest first.
    private(set) var entries: [TrainingEntry] = []
    private(set) var summary = TrainingSummary()
    /// False when a chosen folder is missing, e.g. its drive isn't connected.
    private(set) var isAvailable = true
    private(set) var lastError: String?
    /// A deletion that couldn't move its recordings to the Trash (a volume without one), waiting
    /// for the user to confirm deleting them permanently. Nothing has been deleted yet.
    private(set) var needsPermanentDeletion: PendingDeletion?

    /// What a delete removes.
    enum Deletion: Equatable, Sendable {
        case one(String)
        case all
    }

    /// A deletion bound to the folder it was asked of, so confirming it can never act on a folder
    /// chosen since.
    struct PendingDeletion: Equatable, Sendable {
        let deletion: Deletion
        let root: URL
    }

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let persists: Bool
    @ObservationIgnored private let queue = DispatchQueue(label: "training-data", qos: .utility)
    private static let log = Logger(subsystem: AppInfo.bundleID, category: "training")

    /// The folder used until the user chooses one.
    static let defaultFolder = AppInfo.supportDirectory.appendingPathComponent("training-data", isDirectory: true)
    /// The folder made inside the one the user picks.
    static let folderName = "Fairspoken Training Data"

    init(settings: SettingsStore, persists: Bool = !AppInfo.isDemo) {
        self.settings = settings
        self.persists = persists
        if persists { refresh() } else { seedDemo() }
    }

    var folder: URL {
        let chosen = settings.settings.trainingDataFolder
        return chosen.isEmpty ? Self.defaultFolder : URL(fileURLWithPath: chosen, isDirectory: true)
    }

    var usesDefaultFolder: Bool { settings.settings.trainingDataFolder.isEmpty }

    /// The store, creating the app's own folder; a chosen folder is never created here.
    private func store() -> TrainingDataStore {
        if usesDefaultFolder {
            try? FileManager.default.createDirectory(at: Self.defaultFolder, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
        }
        return TrainingDataStore(root: folder)
    }

    // MARK: Capture

    /// Whether a delivered dictation is kept now.
    var isCapturing: Bool { persists && settings.settings.trainingCapture }

    /// A dictation's audio: in memory, or a WAV file already on disk (16 kHz mono 16-bit) that is
    /// moved into the folder rather than written again.
    enum Audio: Sendable {
        case samples([Float])
        case file(URL, durationSeconds: Double)
    }

    /// Keeps one dictation when capture is on. Never delays delivery: the WAV is written (or
    /// moved) later. A file that can't be kept is deleted: it was only on its way here.
    func keep(_ audio: Audio, rawText: String, finalText: String, model: String, appBundleID: String?) {
        guard isCapturing else {
            if case .file(let url, _) = audio { try? FileManager.default.removeItem(at: url) }
            return
        }
        let duration: Double = switch audio {
        case .samples(let samples): Double(samples.count) / TrainingDataStore.sampleRate
        case .file(_, let seconds): seconds
        }
        let entry = TrainingEntry(
            createdAt: Int64(Date().timeIntervalSince1970),
            durationSeconds: duration,
            speechModel: model, appCategory: AppCategory.of(bundleID: appBundleID).rawValue,
            rawText: rawText, finalText: finalText)
        let store = store()
        queue.async { [weak self] in
            let result = Result {
                switch audio {
                case .samples(let samples): try store.record(entry, samples: samples)
                case .file(let url, _): try store.record(entry, movingAudioFrom: url)
                }
            }
            if case .failure = result, case .file(let url, _) = audio { try? FileManager.default.removeItem(at: url) }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success:
                    self.entries.insert(entry, at: 0)
                    self.summary = TrainingSummary(self.entries)
                    self.isAvailable = true
                    self.lastError = nil
                case .failure(let error):
                    Self.log.error("Keeping a dictation failed: \(error.localizedDescription, privacy: .public)")
                    self.isAvailable = store.isAvailable
                    self.lastError = error.localizedDescription
                }
            }
        }
    }

    // MARK: Library

    func refresh() {
        guard persists else { return }
        let store = store()
        queue.async { [weak self] in
            let available = store.isAvailable
            let loaded = available ? Array(store.entries().reversed()) : []
            DispatchQueue.main.async {
                guard let self, store.root == self.folder else { return }
                self.isAvailable = available
                self.entries = loaded
                self.summary = TrainingSummary(loaded)
                if available { self.lastError = nil }
            }
        }
    }

    /// Moves recordings to the Trash. When that fails, nothing is deleted and
    /// `needsPermanentDeletion` asks the user before anything is removed for good.
    func delete(_ deletion: Deletion) {
        guard persists else { return }
        run(deletion, removal: .trash, in: store())
    }

    /// Only after the user confirmed it, when moving to the Trash failed, and only in the folder
    /// it was asked of: a prompt left over from another folder is dropped.
    func deletePermanently(_ pending: PendingDeletion) {
        needsPermanentDeletion = nil
        guard persists, pending.root == folder else { return }
        run(pending.deletion, removal: .permanent, in: TrainingDataStore(root: pending.root))
    }

    func keepAfterTrashFailed() {
        needsPermanentDeletion = nil
    }

    private enum Outcome: Sendable {
        case done
        case trashUnavailable
        case failed(String)
    }

    private func run(_ deletion: Deletion, removal: TrainingDataStore.Removal, in store: TrainingDataStore) {
        queue.async { [weak self] in
            let outcome: Outcome
            do {
                switch deletion {
                case .one(let id): try store.delete(id, removal: removal)
                case .all: try store.deleteAll(removal: removal)
                }
                outcome = .done
            } catch TrainingDataStore.StoreError.couldNotTrash {
                outcome = .trashUnavailable
            } catch {
                outcome = .failed("Couldn't change the recordings in \(store.root.path): \(error.localizedDescription)")
            }
            DispatchQueue.main.async {
                guard let self else { return }
                switch outcome {
                case .done: self.lastError = nil
                case .trashUnavailable:
                    // Asked of a folder that is no longer the current one: don't offer it.
                    if store.root == self.folder {
                        self.needsPermanentDeletion = PendingDeletion(deletion: deletion, root: store.root)
                    }
                case .failed(let message): self.lastError = message
                }
                self.refresh()
            }
        }
    }

    func audioURL(for id: String) -> URL { TrainingDataStore(root: folder).audioURL(for: id) }

    // MARK: Folder

    /// Picks where recordings go. The data lives in a "Fairspoken Training Data" folder inside
    /// the one picked (or the picked one itself, if it already is such a folder).
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        panel.message = "Choose where to save recordings for post-training. A drive with plenty of space is best: about 2 MB per minute of speech."
        panel.directoryURL = usesDefaultFolder ? nil : folder.deletingLastPathComponent()
        guard panel.runModal() == .OK, let picked = panel.url else { return }
        let isDataFolder = picked.lastPathComponent == Self.folderName
            || FileManager.default.fileExists(atPath: picked.appendingPathComponent(TrainingDataStore.indexFile).path)
        let target = isDataFolder ? picked : picked.appendingPathComponent(Self.folderName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        } catch {
            lastError = "Couldn't create \(target.path): \(error.localizedDescription)"
            return
        }
        settings.update { $0.trainingDataFolder = target.path }
        needsPermanentDeletion = nil
        refresh()
    }

    func useDefaultFolder() {
        settings.update { $0.trainingDataFolder = "" }
        needsPermanentDeletion = nil
        refresh()
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    // MARK: Demo data (screenshots, `--demo`)

    private func seedDemo() {
        let now = Int64(Date().timeIntervalSince1970)
        let samples: [(String, Double, String)] = [
            ("Ask Claude Code to rebase the branch onto main and open a PR.", 6.1, "code"),
            ("Siobhán's HbA1c is down to 52, so continue metformin and recheck at her next CDM review.", 8.4, "docs"),
            ("Can we move the Thursday meeting to half ten?", 3.2, "messaging"),
        ]
        entries = samples.enumerated().map { i, s in
            TrainingEntry(id: "demo-\(i)", createdAt: now - Int64(i * 900), durationSeconds: s.1, speechModel: "parakeet-ultra",
                          appCategory: s.2, rawText: s.0, finalText: s.0)
        }
        summary = TrainingSummary(entries)
        summary.seconds = 2.6 * 3600
        summary.count = 1_184
        summary.bytes = Int64(summary.seconds * 32_000)
    }
}
