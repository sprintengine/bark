import AVFoundation
import Darwin
import FairspokenCore
import Foundation
import Synchronization
import Testing
@testable import FairspokenSpeech

/// Plays recordings through `LiveTranscriptionSession` in real time (100 ms frames, as the
/// microphone delivers them) on the installed Parakeet model and prints what live text costs:
/// when the first words appear, how often the text updates, the Neural Engine time per decode,
/// CPU time against a plain batch session, and release-to-text. Skipped unless
/// `FAIRSPOKEN_LIVE_TEXT_CLIPS` lists 16 kHz mono WAV files (comma-separated):
///
///     FAIRSPOKEN_LIVE_TEXT_CLIPS=/path/a.wav,/path/b.wav swift test --filter LiveText
///
/// `FAIRSPOKEN_REAL_MODEL_ID` picks the model (default `parakeet-tdt-0.6b-v3`); it must be
/// installed already. Not part of scripts/test.sh.
@Suite("Live text on a real model (opt-in)", .serialized)
struct LiveTextMeasurementTests {
    static let clips = ProcessInfo.processInfo.environment["FAIRSPOKEN_LIVE_TEXT_CLIPS"]?
        .split(separator: ",").map(String.init) ?? []

    @Test(.enabled(if: !clips.isEmpty, "Set FAIRSPOKEN_LIVE_TEXT_CLIPS to WAV files"))
    func measuresLiveText() async throws {
        let id = ProcessInfo.processInfo.environment["FAIRSPOKEN_REAL_MODEL_ID"] ?? "parakeet-tdt-0.6b-v3"
        try #require(ParakeetModels.isInstalled(id), "\(id) is not installed")
        let engine = FluidAudioEngine()
        try await engine.load(id) { _ in }

        for path in Self.clips {
            let samples = try Self.read(path)
            let seconds = Double(samples.count) / 16_000

            // Baseline: today's batch session (nothing runs while speaking).
            let batchCPU0 = Self.cpuSeconds()
            let batch = LocalBatch(engine: engine)
            try await Self.play(samples, into: batch)
            let batchRelease = ContinuousClock.now
            let batchText = try await batch.finish(allSamples: samples).text
            let batchReleaseMs = (ContinuousClock.now - batchRelease) / .microseconds(1) / 1000
            let batchCPU = Self.cpuSeconds() - batchCPU0

            // Live text.
            let updates = Mutex<[(Double, String)]>([])
            let start = ContinuousClock.now
            let liveCPU0 = Self.cpuSeconds()
            let live = LiveTranscriptionSession(engine: engine, options: .init()) { text in
                updates.withLock { $0.append(((ContinuousClock.now - start) / .microseconds(1) / 1000, text)) }
            }
            try await Self.play(samples, into: live)
            let release = ContinuousClock.now
            let final = try await live.finish(allSamples: samples).text
            let releaseMs = (release.duration(to: .now)) / .microseconds(1) / 1000
            let liveCPU = Self.cpuSeconds() - liveCPU0
            let stats = live.statistics
            let log = updates.withLock { $0 }
            let gaps = zip(log.dropFirst(), log).map { $0.0 - $1.0 }

            #expect(final == batchText, "the inserted text must match the batch pass")
            print("""
            LIVE \((path as NSString).lastPathComponent) \(String(format: "%.1f", seconds)) s audio
              first text at \(stats.firstTextMs.map { String(format: "%.0f", $0) } ?? "-") ms, \(stats.updates) updates, \
            median gap \(Self.median(gaps).map { String(format: "%.0f", $0) } ?? "-") ms
              \(stats.decodes) decodes (\(stats.segments) segments, \(stats.skippedQuiet) quiet skips), \
            mean \(String(format: "%.1f", stats.decodeMs / Double(max(1, stats.decodes)))) ms, \
            longest \(String(format: "%.1f", stats.longestDecodeMs)) ms, \
            engine busy \(String(format: "%.1f", 100 * stats.decodeMs / 1000 / seconds))% of the recording
              CPU \(String(format: "%.2f", liveCPU)) s live vs \(String(format: "%.2f", batchCPU)) s batch \
            (\(String(format: "%.1f", 100 * (liveCPU - batchCPU) / seconds))% of one core extra)
              release to text \(String(format: "%.0f", releaseMs)) ms live vs \(String(format: "%.0f", batchReleaseMs)) ms batch
              last live: \(log.last?.1 ?? "")
              final:     \(final)
            """)
        }
        await engine.unload()
    }

    // MARK: Helpers

    private final class LocalBatch: TranscriptionSession, @unchecked Sendable {
        let engine: FluidAudioEngine
        init(engine: FluidAudioEngine) { self.engine = engine }
        func append(_ samples16k: [Float]) {}
        func finish(allSamples: [Float]) async throws -> TranscriptionOutput {
            try await engine.transcribe(allSamples, options: .init())
        }
        func cancel() {}
    }

    /// Feeds 100 ms frames on the wall clock, as the microphone does.
    private static func play(_ samples: [Float], into session: any TranscriptionSession) async throws {
        let frame = 1_600
        let start = ContinuousClock.now
        var i = 0
        while i < samples.count {
            let n = min(frame, samples.count - i)
            session.append(Array(samples[i..<(i + n)]))
            i += n
            let due = start + .microseconds(Int64(Double(i) / 16_000 * 1_000_000))
            if due > .now { try await Task.sleep(until: due, clock: .continuous) }
        }
    }

    private static func read(_ path: String) throws -> [Float] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let format = file.processingFormat
        try #require(format.sampleRate == 16_000 && format.channelCount == 1, "\(path) must be 16 kHz mono")
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let data = try #require(buffer.floatChannelData)
        return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return s(usage.ru_utime) + s(usage.ru_stime)
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
