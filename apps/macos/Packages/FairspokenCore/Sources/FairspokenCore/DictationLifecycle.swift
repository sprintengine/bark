import Foundation

/// What started a recording.
public enum DictationTrigger: String, Sendable, Equatable {
    /// The recording shortcut (⇧⌘1 unless changed), in toggle or hold-to-talk mode.
    case hotkey
    /// Holding Fn/Globe.
    case fn
    /// A button or menu item: Home, the setup guide, the menu bar, the speed test.
    case button
}

/// Something the user did that may start or end a recording.
public enum DictationTriggerEvent: String, Sendable, Equatable {
    case shortcutDown, shortcutUp, fnDown, fnUp, button
}

public enum DictationTriggerAction: Sendable, Equatable {
    case start(DictationTrigger)
    case stop
    case ignore
}

/// One dictation at a time, from the first key press to the transcript: which dictation is
/// current, what stage it is at, and the transcription session while it is listening.
///
/// Every dictation gets the next `id`. Work that finishes after the user has moved on (a
/// transcription that lands once the next recording has started, a cancelled one, a timer)
/// checks its id against the current one before it touches anything, so it can never end,
/// or take the session of, a newer dictation. The session is handed over when listening ends
/// and the lifecycle keeps no copy of it.
public struct DictationLifecycle<Session> {
    public enum Stage: Equatable, Sendable {
        case idle
        case listening(DictationTrigger)
        case transcribing

        public var label: String {
            switch self {
            case .idle: "idle"
            case .listening(let trigger): "listening (\(trigger.rawValue))"
            case .transcribing: "transcribing"
            }
        }
    }

    public private(set) var stage: Stage = .idle
    /// The current dictation's id, or the last one's once it is over. Zero before the first.
    public private(set) var id = 0
    private var session: Session?

    public init() {}

    public var isActive: Bool { stage != .idle }
    public var isListening: Bool { if case .listening = stage { true } else { false } }
    /// What started the recording that is listening now.
    public var listeningTrigger: DictationTrigger? { if case .listening(let trigger) = stage { trigger } else { nil } }

    /// What `event` does now. While listening, any trigger ends the recording, whichever started
    /// it: a press of Fn, the shortcut or a button always stops it (so a release that macOS lost
    /// can never leave the microphone on). Releasing a held key ends only a recording that key
    /// started. A held shortcut's own key-down ends nothing: its release does. While
    /// transcribing nothing starts or stops; Escape cancels.
    public func action(for event: DictationTriggerEvent, shortcutMode: RecordingShortcutMode) -> DictationTriggerAction {
        switch stage {
        case .transcribing:
            return .ignore
        case .listening(let trigger):
            switch event {
            case .shortcutDown:
                return shortcutMode == .pushToTalk && trigger == .hotkey ? .ignore : .stop
            case .fnDown, .button:
                return .stop
            case .shortcutUp:
                return shortcutMode == .pushToTalk && trigger == .hotkey ? .stop : .ignore
            case .fnUp:
                return trigger == .fn ? .stop : .ignore
            }
        case .idle:
            switch event {
            case .shortcutDown: return .start(.hotkey)
            case .fnDown: return .start(.fn)
            case .button: return .start(.button)
            case .shortcutUp, .fnUp: return .ignore
            }
        }
    }

    /// A recording has started: it is the current dictation from now on. Returns its id.
    @discardableResult
    public mutating func begin(_ trigger: DictationTrigger, session: Session) -> Int {
        id += 1
        stage = .listening(trigger)
        self.session = session
        return id
    }

    /// The recording ends and the dictation is transcribed. The session goes to the caller (nil
    /// only if it was somehow lost, which the caller treats as a fault and cancels). Nil when
    /// nothing is listening.
    public mutating func endListening() -> (id: Int, session: Session?)? {
        guard isListening else { return nil }
        stage = .transcribing
        defer { session = nil }
        return (id, session)
    }

    /// Whether dictation `id` is the current one and still being transcribed: the only time
    /// its transcription may deliver, or change what the user sees.
    public func isTranscribing(_ id: Int) -> Bool { stage == .transcribing && self.id == id }

    /// Dictation `id` is over (delivered, failed, kept to retry, timed out). False, changing
    /// nothing, when it is no longer the one being transcribed: cancelled, already finished, or
    /// a newer dictation has started.
    @discardableResult
    public mutating func finish(_ id: Int) -> Bool {
        guard isTranscribing(id) else { return false }
        stage = .idle
        return true
    }

    /// Abandons the current dictation at whatever stage it is (Escape, a fault). Returns its id,
    /// the stage it was at, and the session if it was still listening; nil when idle.
    public mutating func cancel() -> (id: Int, stage: Stage, session: Session?)? {
        guard isActive else { return nil }
        let was = stage
        let session = self.session
        self.session = nil
        stage = .idle
        return (id, was, session)
    }

    /// The longest a dictation may be transcribing before it is given up on and kept to retry:
    /// the decode on this Mac (generous for a long recording), the model still loading, and with
    /// a host the live answer's timeout plus the quick re-sends before this Mac takes over.
    public static func transcribingDeadline(recordingSeconds: Double, engineReady: Bool,
                                            remoteTimeoutSeconds: Int?) -> Duration {
        var seconds = 30 + recordingSeconds / 2
        if !engineReady { seconds += 180 }
        if let remoteTimeoutSeconds {
            seconds += Double(max(5, remoteTimeoutSeconds)) + Double(DictationRetryPolicy.live(timeoutSeconds: remoteTimeoutSeconds).budget.components.seconds)
        }
        return .milliseconds(Int(min(seconds, 900) * 1000))
    }
}
