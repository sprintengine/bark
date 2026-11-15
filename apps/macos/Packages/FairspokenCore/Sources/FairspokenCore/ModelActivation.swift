import Foundation

/// When a chosen model may become the one dictation uses. Every way of choosing a model (the
/// library, its detail sheet, Settings, onboarding, launch) goes through this:
///
/// - a model that isn't downloaded is downloaded first, as a normal library download (shown,
///   cancellable), and used when that download finishes;
/// - while a dictation is recording or transcribing, the switch waits until it ends, so the
///   dictation (and its live text) never loses its engine or mixes two models.
///
/// Only the latest choice counts.
public struct ModelActivation: Equatable, Sendable {
    public enum Step: Equatable, Sendable {
        case none
        /// Start (or keep) a library download of the model.
        case download(String)
        /// Load the model for dictation now.
        case load(String)
    }

    /// Chosen, downloaded, and waiting for the dictation in progress to end.
    public private(set) var waitingForDictation: String?
    /// Chosen and waiting for its download.
    public private(set) var waitingForDownload: String?

    public init() {}

    /// Whether a choice made now has to wait for the dictation in progress. Only when a model is
    /// already loaded for it: with none loaded, that dictation is itself waiting for this model.
    public static func mustWait(dictating: Bool, engineReady: Bool) -> Bool { dictating && engineReady }

    /// The user (or launch) chose `id`.
    public mutating func request(_ id: String, installed: Bool, downloading: Bool, dictationActive: Bool) -> Step {
        waitingForDictation = nil
        waitingForDownload = nil
        if !installed {
            waitingForDownload = id
            return downloading ? .none : .download(id)
        }
        if dictationActive {
            waitingForDictation = id
            return .none
        }
        return .load(id)
    }

    /// A library download of `id` ended (`success` false when it failed or was cancelled).
    public mutating func downloadFinished(_ id: String, success: Bool, dictationActive: Bool) -> Step {
        guard waitingForDownload == id else { return .none }
        waitingForDownload = nil
        guard success else { return .none }
        if dictationActive {
            waitingForDictation = id
            return .none
        }
        return .load(id)
    }

    /// The dictation in progress ended.
    public mutating func dictationEnded() -> Step {
        guard let id = waitingForDictation else { return .none }
        waitingForDictation = nil
        return .load(id)
    }
}
