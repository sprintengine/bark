import Foundation

/// The decisions behind the setup guide (onboarding), Home's first-use card and the recording
/// pill's key hints, kept free of UI so they can be tested.
public enum SetupGuide {
    // MARK: Steps

    /// The guide's screens, in order. Saving recordings for post-training is a setting, not a step.
    public enum Step: Int, CaseIterable, Sendable {
        case welcome, permissions, microphone, model, shortcut, tryIt, finish

        /// Shown in the progress line ("Microphone", "Model", …).
        public var title: String {
            switch self {
            case .welcome: "Welcome"
            case .permissions: "Permissions"
            case .microphone: "Microphone"
            case .model: "Model"
            case .shortcut: "Shortcut"
            case .tryIt: "Try it"
            case .finish: "Done"
            }
        }
    }

    /// The step after `step`. "Try it" needs a working engine, so it is passed over while the
    /// model is unusable (its download failed, or was skipped); the finish checklist then says what
    /// is left.
    public static func step(after step: Step, engineUsable: Bool) -> Step {
        guard let next = Step(rawValue: step.rawValue + 1) else { return .finish }
        if next == .tryIt && !engineUsable { return .finish }
        return next
    }

    /// The step before `step`, passing over "Try it" the same way.
    public static func step(before step: Step, engineUsable: Bool) -> Step {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return .welcome }
        if previous == .tryIt && !engineUsable { return .shortcut }
        return previous
    }

    // MARK: Model step

    /// Where the chosen speech model is, as the model step shows it.
    public enum ModelProgress: Equatable, Sendable {
        case notStarted
        /// Downloading, unpacking, compiling or loading; `fraction` while it downloads.
        case preparing(fraction: Double?)
        case ready
        case failed(String)
        /// The chosen model failed to download, but dictation still works with the model already
        /// loaded (`using`, its short name).
        case fallback(failed: String, using: String)
        /// Transcribing on a network device: no local model is needed.
        case remote

        /// The model step may move on: the download carries on in the background. A failure keeps
        /// the person on the step with Retry and "Skip for now", unless another model still works.
        public var canContinue: Bool {
            if case .failed = self { return false }
            return true
        }

        /// "Try it" can run (now, or once loading finishes while the person sets the shortcut).
        public var engineUsable: Bool {
            switch self {
            case .failed, .notStarted: false
            default: true
            }
        }
    }

    /// The model step's short list from the catalogue: the default first, then the other
    /// recommended models, then the best of the rest (accuracy plus speed, then the smaller
    /// download). Only speech models that run on this Mac and aren't slow; `including` (the model
    /// already chosen) is always listed.
    public static func modelChoices(from catalogue: [SpeechModelInfo], defaultID: String, including chosen: String? = nil,
                                    limit: Int = 4) -> [SpeechModelInfo] {
        let usable = catalogue.filter { $0.isLocal && $0.kind == .speech && !$0.isExperimental }
        let ranked = usable.sorted { a, b in
            if (a.id == defaultID) != (b.id == defaultID) { return a.id == defaultID }
            if a.isRecommended != b.isRecommended { return a.isRecommended }
            if a.accuracy + a.speed != b.accuracy + b.speed { return a.accuracy + a.speed > b.accuracy + b.speed }
            return a.approxBytes < b.approxBytes
        }
        var list = Array(ranked.prefix(limit))
        if let chosen, !list.contains(where: { $0.id == chosen }), let model = usable.first(where: { $0.id == chosen }) {
            list.append(model)
        }
        return list
    }

    /// The speech engine, as `modelProgress` needs it.
    public enum EngineStatus: Equatable, Sendable {
        case idle
        case downloading(Double)
        /// Unpacking, compiling, loading or warming.
        case busy
        case ready
        case failed(String)
    }

    /// The chosen model in the library.
    public enum ItemStatus: Equatable, Sendable {
        case available
        case downloading(Double)
        /// Unpacking or compiling.
        case preparing
        case installed
    }

    /// Where the chosen model (`chosenID`) is: its tracked download, then loading on the engine.
    /// The engine holds `activeID` (`activeName` is its short name); a chosen model that failed
    /// while another one works is `.fallback`, not a dead end.
    public static func modelProgress(remote: Bool, chosenID: String, activeID: String, activeName: String,
                                     engine: EngineStatus, chosenItem: ItemStatus, downloadError: String?) -> ModelProgress {
        if remote { return .remote }
        let chosenIsActive = chosenID == activeID
        if let downloadError {
            return !chosenIsActive && engine == .ready ? .fallback(failed: downloadError, using: activeName) : .failed(downloadError)
        }
        switch chosenItem {
        case .downloading(let f): return .preparing(fraction: f)
        case .preparing: return .preparing(fraction: nil)
        case .available:
            guard chosenIsActive else { return .notStarted }
            switch engine {
            case .downloading(let f): return .preparing(fraction: f)
            case .busy: return .preparing(fraction: nil)
            case .failed(let message): return .failed(message)
            case .idle, .ready: return .notStarted
            }
        case .installed:
            // Installed but not loaded yet (it loads between dictations).
            guard chosenIsActive else { return .preparing(fraction: nil) }
            switch engine {
            case .ready: return .ready
            case .failed(let message): return .failed(message)
            default: return .preparing(fraction: nil)
            }
        }
    }

    // MARK: Microphone check

    /// What the microphone test found, each with its own fix.
    public enum MicCheck: Equatable, Sendable {
        /// Not started yet.
        case idle
        /// The system hasn't asked yet: Allow.
        case needsPermission
        /// Turned off in System Settings: Open Privacy & Security.
        case denied
        /// No input device: connect a microphone.
        case noDevice
        /// The device wouldn't start: choose another.
        case failed(String)
        /// Listening, nothing heard yet.
        case listening
        /// Listening for a while and nothing above the noise floor: check the level or device.
        case silent
        /// Speech heard.
        case hearing
    }

    /// The level (0…1, the meter's display scale: about -40 dBFS) that counts as someone speaking.
    public static let speechLevel: Float = 0.3
    /// How long the test listens before calling it silence.
    public static let silenceSeconds: Double = 5

    public enum Permission: Sendable { case granted, denied, notDetermined }

    public static func micCheck(permission: Permission, deviceCount: Int, running: Bool, error: String?,
                                listenedSeconds: Double, peakLevel: Float) -> MicCheck {
        switch permission {
        case .notDetermined: return .needsPermission
        case .denied: return .denied
        case .granted: break
        }
        if deviceCount == 0 { return .noDevice }
        if let error { return .failed(error) }
        guard running else {
            // A finished test keeps what it found.
            if peakLevel >= speechLevel { return .hearing }
            return listenedSeconds >= silenceSeconds ? .silent : .idle
        }
        if peakLevel >= speechLevel { return .hearing }
        return listenedSeconds >= silenceSeconds ? .silent : .listening
    }

    // MARK: Checklist

    /// One line of the finish checklist and Home's first-use card.
    public struct ChecklistItem: Equatable, Sendable, Identifiable {
        public enum Kind: String, Sendable { case microphone, accessibility, model, micHeard }
        public enum State: Equatable, Sendable { case done, pending(String), problem(String) }
        public var kind: Kind
        public var state: State
        /// Dictation can't work without it.
        public var required: Bool
        public var id: String { kind.rawValue }
        public var isDone: Bool { state == .done }
    }

    /// What is set up, from live state. Nothing is claimed that isn't so.
    public static func checklist(microphone: Permission, accessibility: Bool, model: ModelProgress,
                                 micHeard: Bool?) -> [ChecklistItem] {
        var items: [ChecklistItem] = []
        items.append(.init(kind: .microphone, state: {
            switch microphone {
            case .granted: .done
            case .notDetermined: .pending("Not allowed yet")
            case .denied: .problem("Turned off in System Settings")
            }
        }(), required: true))
        items.append(.init(kind: .model, state: {
            switch model {
            case .ready, .remote, .fallback: .done
            case .preparing(let f): .pending(f.map { "Downloading, \(Int(($0 * 100).rounded()))%" } ?? "Getting ready")
            case .failed(let message): .problem(message)
            case .notStarted: .pending("Not downloaded")
            }
        }(), required: true))
        items.append(.init(kind: .accessibility, state: accessibility ? .done : .pending("Dictations are copied for you to paste"),
                           required: false))
        if let micHeard {
            items.append(.init(kind: .micHeard, state: micHeard ? .done : .pending("Nothing heard"), required: false))
        }
        return items
    }

    /// Every required item is done.
    public static func isReady(_ items: [ChecklistItem]) -> Bool {
        items.allSatisfy { !$0.required || $0.isDone }
    }

    // MARK: Key hints

    /// One hint in the recording pill: "Stop ⇧⌘1", "Cancel esc", "Release to finish".
    public struct KeyHint: Equatable, Sendable {
        public var action: String
        public var keys: String?
        public init(action: String, keys: String?) {
            self.action = action
            self.keys = keys
        }
    }

    public enum Trigger: Sendable { case shortcut, fn, button }

    /// What ends the recording, then what cancels it, from the person's own keys.
    public static func listeningHints(mode: RecordingShortcutMode, trigger: Trigger, shortcut: String,
                                      cancel: String?) -> [KeyHint] {
        var hints: [KeyHint] = []
        switch (trigger, mode) {
        case (.fn, _): hints.append(.init(action: "Release fn to finish", keys: nil))
        case (.shortcut, .pushToTalk): hints.append(.init(action: "Release to finish", keys: nil))
        case (.shortcut, .toggle), (.button, .toggle):
            hints.append(.init(action: "Stop", keys: shortcut.isEmpty ? nil : shortcut))
        case (.button, .pushToTalk): hints.append(.init(action: "Click stop to finish", keys: nil))
        }
        if let cancel, !cancel.isEmpty { hints.append(.init(action: "Cancel", keys: keyLabel(cancel))) }
        return hints
    }

    /// Spells a key the way a keycap shows it: "⎋" and "Escape" become "esc".
    public static func keyLabel(_ key: String) -> String {
        switch key {
        case "⎋", "Escape", "escape", "Esc": "esc"
        case "␣", "Space": "space"
        default: key
        }
    }
}

/// Who owns a shared microphone capture: each start takes a new token, and only the holder of
/// the latest token may stop it. A test that was overtaken by a dictation then never stops the
/// dictation's recording.
public struct CaptureOwnership: Sendable {
    public private(set) var current = 0
    public init() {}

    /// A new owner; earlier tokens lose the capture.
    public mutating func begin() -> Int {
        current += 1
        return current
    }

    public func owns(_ token: Int) -> Bool { token == current }
}

extension Array where Element == TranscriptHistoryItem {
    /// How many different apps these dictations went into (by bundle id, else name). Dictations
    /// kept in Bark's own window count as no app.
    public var appsUsed: Int {
        Set(compactMap { item -> String? in
            if let id = item.appBundleId, !id.isEmpty { return id.lowercased() }
            if let name = item.appName, !name.isEmpty { return name.lowercased() }
            return nil
        }).count
    }
}
