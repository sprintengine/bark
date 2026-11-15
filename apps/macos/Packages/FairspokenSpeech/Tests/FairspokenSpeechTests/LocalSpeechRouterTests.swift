import FairspokenCore
import FairspokenSpeech
import Foundation
import Synchronization
import Testing
@testable import FairspokenWhisper

/// What is in memory across both fake engines, and the most there ever was at once.
final class Residency: Sendable {
    private let state = Mutex<(loaded: Set<String>, peak: Int)>(([], 0))
    func loaded(_ id: String) { state.withLock { $0.loaded.insert(id); $0.peak = max($0.peak, $0.loaded.count) } }
    func unloaded(_ id: String) { state.withLock { _ = $0.loaded.remove(id) } }
    var current: Set<String> { state.withLock { $0.loaded } }
    var peak: Int { state.withLock { $0.peak } }
}

/// A stand-in engine: loads take `delay` (cancellable, like a download), and ids in `failing` fail.
actor FakeEngine: LocalSpeechEngine {
    let residency: Residency
    let delay: Duration
    /// Like a Core ML load, which runs to the end once started.
    let ignoresCancellation: Bool
    var failing: Set<String>
    private(set) var loadedModelID: String?

    init(residency: Residency, delay: Duration = .zero, ignoresCancellation: Bool = false, failing: Set<String> = []) {
        self.residency = residency
        self.delay = delay
        self.ignoresCancellation = ignoresCancellation
        self.failing = failing
    }

    func load(_ id: String, progress: @escaping @Sendable (ModelStage) -> Void) async throws {
        if loadedModelID == id { return }
        if ignoresCancellation {
            try? await Task.sleep(for: delay)
            let end = ContinuousClock.now + delay
            while ContinuousClock.now < end { await Task.yield() }
        } else {
            try await Task.sleep(for: delay)
        }
        if failing.contains(id) { throw SpeechEngineError.notInstalled(id) }
        if let old = loadedModelID { residency.unloaded(old) }
        residency.loaded(id)
        loadedModelID = id
    }

    func unload() async {
        if let old = loadedModelID { residency.unloaded(old) }
        loadedModelID = nil
    }

    func transcribe(_ samples16k: [Float], options: TranscriptionRequestOptions) async throws -> TranscriptionOutput {
        guard let id = loadedModelID else { throw SpeechEngineError.notLoaded }
        return TranscriptionOutput(text: id, modelMs: 1, model: id, placement: .neuralEngine)
    }
}

@Suite("Local speech router")
struct LocalSpeechRouterTests {
    static let parakeet = "parakeet-tdt-0.6b-v3"
    static let ultra = "parakeet-ultra"
    static let whisper = "large-v3"

    /// Start a slow Whisper load, then pick the Parakeet model that was loaded before: the late
    /// Whisper load must not end up in use.
    @Test func aNewerChoiceWinsOverASlowLoad() async throws {
        let residency = Residency()
        let router = LocalSpeechRouter(parakeet: FakeEngine(residency: residency),
                                       whisper: FakeEngine(residency: residency, delay: .milliseconds(300)))
        try await router.load(Self.parakeet) { _ in }
        let slow = Task { try await router.load(Self.whisper) { _ in } }
        try await Task.sleep(for: .milliseconds(50))
        try await router.load(Self.parakeet) { _ in }
        await #expect(throws: CancellationError.self) { try await slow.value }
        #expect(await router.loadedModelID == Self.parakeet)
        #expect(residency.current == [Self.parakeet])
        let out = try await router.transcribe([0], options: .init())
        #expect(out.model == Self.parakeet)
    }

    /// Whisper loads that are not cancellable still finish; the newer request then replaces them.
    @Test func aLoadThatFinishesAfterBeingSupersededIsReplaced() async throws {
        let residency = Residency()
        let router = LocalSpeechRouter(parakeet: FakeEngine(residency: residency, delay: .milliseconds(100), ignoresCancellation: true),
                                       whisper: FakeEngine(residency: residency, delay: .milliseconds(100), ignoresCancellation: true))
        async let first: Void = router.load(Self.whisper) { _ in }
        try await Task.sleep(for: .milliseconds(20))
        async let second: Void = router.load(Self.ultra) { _ in }
        // Started after `second`, so it is the newest request (async lets start in no set order).
        try await Task.sleep(for: .milliseconds(10))
        async let third: Void = router.load(Self.parakeet) { _ in }
        _ = try? await first
        _ = try? await second
        try await third
        #expect(await router.loadedModelID == Self.parakeet)
        #expect(residency.current == [Self.parakeet])
        #expect(residency.peak == 1)
    }

    /// A superseded load that still finishes is never handed to a transcription (live text keeps
    /// asking while the switch runs).
    @Test func aSupersededModelIsNeverUsedForTranscription() async throws {
        let residency = Residency()
        let router = LocalSpeechRouter(parakeet: FakeEngine(residency: residency, delay: .milliseconds(100)),
                                       whisper: FakeEngine(residency: residency, delay: .milliseconds(150), ignoresCancellation: true))
        let first = Task { try await router.load(Self.whisper) { _ in } }
        try await Task.sleep(for: .milliseconds(20))
        let second = Task { try await router.load(Self.parakeet) { _ in } }
        var used: Set<String> = []
        let end = ContinuousClock.now + .milliseconds(400)
        while ContinuousClock.now < end {
            if let out = try? await router.transcribe([0], options: .init()) { used.insert(out.model) }
            try await Task.sleep(for: .milliseconds(5))
        }
        _ = try? await first.value
        try await second.value
        #expect(!used.contains(Self.whisper))
        #expect(try await router.transcribe([0], options: .init()).model == Self.parakeet)
    }

    /// Never two models in memory, across engines or within one.
    @Test func thePreviousModelIsReleasedBeforeTheNextLoads() async throws {
        let residency = Residency()
        let router = LocalSpeechRouter(parakeet: FakeEngine(residency: residency), whisper: FakeEngine(residency: residency))
        for id in [Self.parakeet, Self.whisper, Self.ultra, Self.parakeet, "tiny"] {
            try await router.load(id) { _ in }
            #expect(residency.current == [id])
        }
        #expect(residency.peak == 1)
    }

    /// A model that fails to load leaves the previous one in use, and the error reaches the caller.
    @Test func aFailedLoadPutsThePreviousModelBack() async throws {
        let residency = Residency()
        let router = LocalSpeechRouter(parakeet: FakeEngine(residency: residency),
                                       whisper: FakeEngine(residency: residency, failing: [Self.whisper]))
        try await router.load(Self.parakeet) { _ in }
        await #expect(throws: SpeechEngineError.self) { try await router.load(Self.whisper) { _ in } }
        #expect(await router.loadedModelID == Self.parakeet)
        #expect(residency.current == [Self.parakeet])
        #expect(try await router.transcribe([0], options: .init()).model == Self.parakeet)
    }

    @Test func unknownIdsAreRefusedWithoutTouchingTheLoadedModel() async throws {
        let residency = Residency()
        let router = LocalSpeechRouter(parakeet: FakeEngine(residency: residency), whisper: FakeEngine(residency: residency))
        try await router.load(Self.parakeet) { _ in }
        await #expect(throws: SpeechEngineError.self) { try await router.load("no-such-model") { _ in } }
        #expect(await router.loadedModelID == Self.parakeet)
    }
}
