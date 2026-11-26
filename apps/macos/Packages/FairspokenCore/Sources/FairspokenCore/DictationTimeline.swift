import Foundation

/// Where the time went between letting go of the shortcut and the text landing, step by step,
/// from a dictation's recorded timings. What the dictation view draws as one bar under the
/// message, so a slow dictation shows which step was slow (the speech model, a server's
/// network, the paste), not just how long cleanup took.
public struct DictationTimeline: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        /// The speech model's last pass over the recording.
        case speechModel
        /// The rest of transcribing: waiting for the model to be ready, or a server's network.
        case handover
        /// Learning which app and field the text is going to.
        case destination
        /// Fillers, corrections, formatting and the style.
        case cleanup
        /// Waiting for the keys to come up, checking the field, pasting.
        case paste
        /// Time the recorded steps don't account for (older dictations record fewer steps).
        case other
    }

    public struct Step: Equatable, Sendable {
        public var kind: Kind
        public var title: String
        public var ms: Int
    }

    /// Letting go to pasted.
    public var totalMs: Int
    /// The steps in order, each at least 1 ms; empty steps are left out.
    public var steps: [Step]

    /// Nil for a dictation without timings (a typed note, or one from before timings were kept).
    public init?(_ item: TranscriptHistoryItem) {
        guard let t = item.timings, t.totalMs > 0, !item.isBarkNote else { return nil }
        let remote = item.location == "remote-host"
        let total = t.totalMs
        let transcribe = min(max(t.transcribeMs, 0), total)
        let model = min(max(t.speechModelMs, 0), transcribe)
        var steps: [Step] = []
        func add(_ kind: Kind, _ title: String, _ ms: Int) {
            if ms > 0 { steps.append(Step(kind: kind, title: title, ms: ms)) }
        }
        add(.speechModel, remote ? "Speech model on Bark Server" : "Speech model", model)
        add(.handover, remote ? "Network" : "Getting the model ready", transcribe - model)
        let destination = max(item.destinationMs ?? 0, 0)
        let cleanup = max(item.cleanupMs ?? 0, 0) + max(t.polishMs, 0)
        let paste = max(item.pasteMs ?? 0, 0)
        add(.destination, "Finding the app", destination)
        add(.cleanup, "Cleanup", cleanup)
        add(.paste, item.clipboardOnly == true ? "Copying" : "Pasting", paste)
        let accounted = steps.reduce(0) { $0 + $1.ms }
        // Older dictations didn't record finding the app or pasting: the rest is those.
        let otherTitle = item.pasteMs == nil ? "Finding the app and pasting" : "Other"
        add(.other, otherTitle, total - accounted)
        totalMs = max(total, accounted)
        self.steps = steps
    }

    /// The slowest step, when it is most of the wait: the one to name in a headline.
    public var dominant: Step? {
        guard let top = steps.max(by: { $0.ms < $1.ms }), totalMs > 0, Double(top.ms) / Double(totalMs) >= 0.5 else { return nil }
        return top
    }

    /// "23 ms", "470 ms", "1.2 s", "6.9 s".
    public static func format(_ ms: Int) -> String {
        ms < 1000 ? "\(ms) ms" : String(format: "%.1f s", Double(ms) / 1000)
    }
}
