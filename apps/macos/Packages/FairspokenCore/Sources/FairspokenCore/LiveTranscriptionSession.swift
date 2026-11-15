import Foundation
import Synchronization

/// A local session that shows the text while the user speaks.
///
/// Every `interval` the audio not yet in a finished segment (the tail) is decoded again by
/// the same engine that makes the final transcript, and `onText` gets the running text.
/// Once the tail reaches 12 s it is cut at a pause (`LiveSegmenter`) and that segment is
/// decoded once, so a decode never exceeds Parakeet's 15 s window however long the dictation.
/// Only the latest audio is ever decoded: a decode that is still running when the next tick
/// comes simply delays it, so work never queues up. Silence after the last decode is skipped.
///
/// The transcript `finish` returns is the same whole-recording pass `LocalBatchSession`
/// makes, so the live text never costs accuracy.
public final class LiveTranscriptionSession: TranscriptionSession, @unchecked Sendable {
    public struct Timing: Sendable {
        /// Time between decodes; stretched to `dutyFactor` × the last decode when the
        /// engine is slower, so the Neural Engine is never busy more than 1/dutyFactor.
        public var interval: Duration = .milliseconds(450)
        public var dutyFactor = 5.0
        /// New audio needed before decoding again.
        public var minimumNewSeconds = 0.25
        /// Audio needed before the first decode (a fresh decoder needs a little context).
        public var minimumSeconds = 0.5
        public init() {}
    }

    /// What the live decoding cost, for logs and measurements.
    public struct Statistics: Sendable, Equatable {
        public var decodes = 0
        public var skippedQuiet = 0
        public var decodeMs = 0.0
        public var longestDecodeMs = 0.0
        public var segments = 0
        /// From the first audio to the first text shown.
        public var firstTextMs: Double?
        public var updates = 0
    }

    private struct State {
        var samples: [Float] = []
        var firstAudio: ContinuousClock.Instant?
        var finished = false
        var worker: Task<Void, Never>?
        var stats = Statistics()
    }

    public static let sampleRate = 16_000

    private let engine: any SpeechEngine
    private let options: TranscriptionRequestOptions
    private let timing: Timing
    private let segmenter: LiveSegmenter
    private let onText: @Sendable (String) -> Void
    private let state = Mutex(State())

    public init(engine: any SpeechEngine, options: TranscriptionRequestOptions, timing: Timing = Timing(),
                segmenter: LiveSegmenter = LiveSegmenter(), onText: @escaping @Sendable (String) -> Void) {
        self.engine = engine
        self.options = options
        self.timing = timing
        self.segmenter = segmenter
        self.onText = onText
        let worker = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.run()
        }
        state.withLock { $0.worker = worker }
    }

    deinit { state.withLock { $0.worker?.cancel() } }

    public var statistics: Statistics { state.withLock { $0.stats } }

    public func append(_ samples16k: [Float]) {
        guard !samples16k.isEmpty else { return }
        state.withLock {
            guard !$0.finished else { return }
            if $0.firstAudio == nil { $0.firstAudio = .now }
            $0.samples.append(contentsOf: samples16k)
        }
    }

    public func finish(allSamples: [Float]) async throws -> TranscriptionOutput {
        stopLive()
        return try await engine.transcribe(allSamples, options: options)
    }

    public func cancel() { stopLive() }

    private func stopLive() {
        let worker = state.withLock { s -> Task<Void, Never>? in
            s.finished = true
            return s.worker
        }
        worker?.cancel()
    }

    // MARK: Decoding

    private var isFinished: Bool { state.withLock { $0.finished } }

    private func run() async {
        let rate = Double(Self.sampleRate)
        let minimumNew = Int(timing.minimumNewSeconds * rate)
        let minimum = Int(timing.minimumSeconds * rate)
        var segments: [String] = []
        var segmentStart = 0
        var decodedEnd = 0
        var tailText = ""
        var shown = ""
        var endedQuiet = false
        var pause = timing.interval
        let quietEnd = Int(0.3 * rate)

        while !Task.isCancelled {
            try? await Task.sleep(for: pause)
            pause = timing.interval
            guard !Task.isCancelled, !isFinished else { return }
            let count = state.withLock { $0.samples.count }
            guard count - decodedEnd >= minimumNew, count - segmentStart >= minimum else { continue }

            // Nothing but silence since a decode that itself ended in silence: the text can't change.
            let quiet = state.withLock { s in LiveTranscript.isQuiet(s.samples[min(decodedEnd, count)..<count]) }
            if quiet, endedQuiet {
                state.withLock { $0.stats.skippedQuiet += 1 }
                continue
            }

            let started = ContinuousClock.now
            var tail = state.withLock { Array($0.samples[segmentStart..<count]) }
            if let cut = segmenter.cutPoint(tail[...], sampleRate: Self.sampleRate),
               let text = await decode(Array(tail[..<cut])) {
                segments.append(text)
                segmentStart += cut
                tail.removeFirst(cut)
                state.withLock { $0.stats.segments += 1 }
            }
            guard !Task.isCancelled, !isFinished else { return }
            if tail.count >= minimum {
                guard let text = await decode(tail) else { continue }
                tailText = text
            } else {
                tailText = ""
            }
            decodedEnd = count
            endedQuiet = LiveTranscript.isQuiet(tail.suffix(quietEnd))
            let elapsed = ContinuousClock.now - started
            pause = max(timing.interval, elapsed * timing.dutyFactor - elapsed)

            let text = LiveTranscript.join(segments + [tailText])
            guard text != shown, !text.isEmpty else { continue }
            let publish = state.withLock { s -> Bool in
                guard !s.finished else { return false }
                s.stats.updates += 1
                if s.stats.firstTextMs == nil, let first = s.firstAudio {
                    s.stats.firstTextMs = Double((ContinuousClock.now - first) / .microseconds(1)) / 1000
                }
                return true
            }
            guard publish else { return }
            shown = text
            onText(text)
        }
    }

    /// One decode; nil when the engine isn't ready (still loading) or failed.
    private func decode(_ samples: [Float]) async -> String? {
        let started = ContinuousClock.now
        guard let output = try? await engine.transcribe(samples, options: options) else { return nil }
        let ms = Double((ContinuousClock.now - started) / .microseconds(1)) / 1000
        state.withLock {
            $0.stats.decodes += 1
            $0.stats.decodeMs += ms
            $0.stats.longestDecodeMs = max($0.stats.longestDecodeMs, ms)
        }
        return output.text
    }
}
