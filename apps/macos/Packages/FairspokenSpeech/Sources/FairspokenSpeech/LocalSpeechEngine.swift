import FairspokenCore
import Foundation

/// Where a model is on its way to being usable: downloaded, unpacked (a model from a link),
/// compiled for this Mac's Neural Engine, loaded and warmed up.
public enum ModelStage: Sendable, Equatable {
    case downloading(Double)
    /// Unpacking and installing a model downloaded from a link.
    case unpacking
    case compiling
    case loading
    case warming
}

/// A speech engine that runs one local model at a time (Parakeet through FluidAudio, Whisper
/// through WhisperKit). The dictation client loads the model the user picked and transcribes
/// through `SpeechEngine`, whichever engine runs it.
public protocol LocalSpeechEngine: SpeechEngine, Actor {
    var loadedModelID: String? { get }
    /// Download if missing, load and warm up. Cheap when `id` is already loaded.
    func load(_ id: String, progress: @escaping @Sendable (ModelStage) -> Void) async throws
    func unload() async
}
