import AppKit
import FairspokenCore
import OSLog

/// After a dictation lands in another app's text field, looks at that field again a little later
/// and learns from what the user fixed (`edit_watch.rs` in the Tauri app).
///
/// The field is read from the moment the recording ends, while the speech is transcribed (text
/// and selection), which gives the text either side of the dictation. It is read again when the
/// next dictation starts, when the frontmost app or focused element changes, or after
/// `watchFor`, whichever comes first. `EditDiff` finds the dictation by that surrounding text and
/// classifies the edits; fixes go to `LearnedLibrary`. When the dictation was kept for
/// post-training, the edited region is attached to it as its `editedText`.
///
/// Never watched: password managers, secure fields, terminals, fields without a plain-text
/// value, and very long values (`FieldReader`). Every AX read is time-limited and off the main
/// thread. The surrounding text stays in memory until the watch is evaluated and is never
/// persisted.
final class EditWatcher {
    /// The dictation whose field is being watched.
    struct Dictation {
        /// Exactly what was inserted.
        var inserted: String
        /// The speech model's text before casing and corrections.
        var raw: String
        /// `AppSettings.speechModelID` of the model that heard it.
        var speechModel: String
        /// The kept recording to attach the user's edit to.
        var captureID: String?
    }

    /// A field read that started at release, and when it finished.
    struct FieldRead: Sendable {
        var field: WatchedField
        var finishedAt: ContinuousClock.Instant
    }

    /// How long after insertion the field is read at the latest.
    static let watchFor: Duration = .seconds(60)
    /// The poll only asks NSWorkspace for the frontmost app, which is cheap.
    static let pollEvery: Duration = .seconds(1)
    /// Every this many polls, also ask Accessibility whether focus moved.
    static let focusCheckPolls = 2

    private struct Watch {
        var field: WatchedField
        var anchor: InsertionAnchor
        var dictation: Dictation
        var armedAt: ContinuousClock.Instant
    }

    private let settings: SettingsStore
    private var watch: Watch?
    private var poller: Task<Void, Never>?
    /// Apps already asked to build their accessibility tree, by process id.
    private var primed = Set<pid_t>()
    /// Fixes the user made, with the model they are scoped to ("" for every model).
    var onFix: ((Mishearing, String) -> Void)?
    /// The user's edit of a kept recording: its id and the dictation as the user left it.
    var onEdit: ((String, String) -> Void)?
    private static let log = Logger(subsystem: AppInfo.bundleID, category: "edit-watch")

    init(settings: SettingsStore) {
        self.settings = settings
    }

    /// Learning or post-training wants the user's edit.
    private var isWanted: Bool {
        let s = settings.settings
        return (s.learnFromEdits || s.trainingCapture) && !AppInfo.isDemo
    }

    /// A recording for `app` started: let a Chromium-based app build the accessibility tree its
    /// field will be read from (`FieldReader.enableManualAccessibility`).
    func prime(_ app: NSRunningApplication?) {
        guard isWanted, let app, !primed.contains(app.processIdentifier), AXIsProcessTrusted(),
              FieldReader.isChromiumBased(bundleURL: app.bundleURL, bundleID: app.bundleIdentifier) else { return }
        let pid = app.processIdentifier
        primed.insert(pid)
        let name = app.bundleIdentifier ?? "?"
        Task {
            let enabled = await FieldReader.withTimeout { FieldReader.enableManualAccessibility(pid: pid) }
            Self.log.debug("Accessibility tree for \(name, privacy: .public): \(enabled == true ? "enabled" : "not supported", privacy: .public)")
        }
    }

    /// Starts reading `app`'s focused field, off the main thread, as the recording ends. Nil
    /// when nothing wants the edit or the dictation is for this app.
    func prepare(for app: NSRunningApplication?) -> Task<FieldRead?, Never>? {
        guard isWanted, let app, let bundleID = app.bundleIdentifier, AXIsProcessTrusted() else { return nil }
        let pid = app.processIdentifier
        return Task {
            let read = await FieldReader.withTimeout { FieldReader.snapshot(pid: pid, bundleID: bundleID) }
            switch read {
            case .success(let field)?:
                return FieldRead(field: field, finishedAt: .now)
            case .failure(let skip)?:
                Self.log.debug("Not watching the field in \(bundleID, privacy: .public): \(skip.rawValue, privacy: .public)")
                return nil
            case nil:
                Self.log.debug("Not watching the field in \(bundleID, privacy: .public): the read timed out")
                return nil
            }
        }
    }

    /// Starts watching the field once the dictation was pasted into it. A read that was still
    /// running when the paste began may already include the dictation, so it is not used; nor is
    /// one of an app that is no longer in front (the user switched apps while speaking, and the
    /// paste went elsewhere).
    func arm(_ read: FieldRead?, insertedAfter pasteStarted: ContinuousClock.Instant, dictation: Dictation) {
        guard let read, read.finishedAt < pasteStarted,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == read.field.pid else { return }
        let field = read.field
        let anchor = InsertionAnchor(field: field.value, selectionStart: field.selectionStart,
                                     selectionLength: field.selectionLength, inserted: dictation.inserted)
        if let previous = watch { evaluate(previous) }
        watch = Watch(field: field, anchor: anchor, dictation: dictation, armedAt: .now)
        startPolling()
    }

    /// Evaluates the pending watch now, in the background: the user has started another
    /// dictation, which may land in the same field.
    func flush() {
        guard let pending = watch else { return }
        watch = nil
        evaluate(pending)
    }

    private func startPolling() {
        guard poller == nil else { return }
        poller = Task { [weak self] in
            var polls = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollEvery)
                guard let self, let pending = self.watch else { break }
                polls += 1
                var due = pending.armedAt.duration(to: .now) >= Self.watchFor
                    || NSWorkspace.shared.frontmostApplication?.processIdentifier != pending.field.pid
                if !due && polls % Self.focusCheckPolls == 0 {
                    let field = pending.field
                    let focused = await FieldReader.withTimeout { FieldReader.isFocused(field.element, in: field.pid) }
                    due = focused == .some(false)
                }
                // Still the same watch: a new dictation may have replaced it while AX answered.
                if due, let current = self.watch, current.armedAt == pending.armedAt {
                    self.watch = nil
                    self.evaluate(current)
                }
            }
            self?.poller = nil
        }
    }

    /// Reads the field again and diffs it against the dictation, off the main thread; then
    /// attaches the edit to a kept recording and passes fixes on, on the main thread.
    private func evaluate(_ watch: Watch) {
        Task {
            let field = watch.field
            let read: String?? = await FieldReader.withTimeout(.milliseconds(250)) { FieldReader.currentValue(of: field.element) }
            guard let value = read ?? nil else { return }
            let anchor = watch.anchor
            let result = await Task.detached(priority: .utility) { () -> (String, EditOutcome)? in
                guard let region = anchor.locate(in: value) else { return nil }
                return (region, EditDiff.classify(inserted: anchor.inserted, edited: region))
            }.value
            guard let (region, outcome) = result, outcome != .unchanged else { return }
            if let id = watch.dictation.captureID { onEdit?(id, region) }
            guard case .edited(let fixes) = outcome, !fixes.isEmpty, settings.settings.learnFromEdits else { return }
            for fix in fixes {
                // A word the speech model never wrote came from casing or a correction, so the
                // fix is not specific to the speech model.
                let model = EditDiff.containsWords(watch.dictation.raw, fix.heard) ? watch.dictation.speechModel : ""
                onFix?(fix, model)
            }
        }
    }
}
