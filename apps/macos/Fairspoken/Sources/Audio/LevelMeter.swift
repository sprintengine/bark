import Foundation
import FairspokenCore
import os

/// The live mic level, shared between the audio thread (writer) and the meters (readers, which
/// poll it from a `TimelineView` at up to 30 Hz, so there are no main-actor hops per buffer).
/// The level math is `MicLevelTracker`'s: 10 ms windows on a dBFS scale, attack/release
/// smoothing and a 30 Hz series played out against the clock. The lock is held only to copy a
/// few numbers, so the audio thread never waits on a reader for long.
nonisolated final class LevelMeter: @unchecked Sendable {
    typealias Snapshot = MicLevelTracker.Snapshot

    private let state = OSAllocatedUnfairLock(initialState: MicLevelTracker())

    /// One buffer of 16 kHz mono capture. Measured outside the lock.
    func process(_ samples: UnsafeBufferPointer<Float>, sampleRate: Double) {
        let window = max(1, Int(sampleRate * MicLevel.windowSeconds))
        let powers = MicLevel.windowMeanSquares(samples, window: window)
        let seconds = Double(window) / sampleRate
        let now = Self.clock()
        state.withLock { $0.feed(meanSquares: powers, windowSeconds: seconds, arrival: now) }
    }

    /// One reading of `seconds` at an RMS amplitude (screenshots and previews).
    func push(rms: Float, seconds: Double = 0.03) {
        let now = Self.clock()
        state.withLock { $0.feed(meanSquares: [rms * rms], windowSeconds: seconds, arrival: now) }
    }

    func reset() {
        state.withLock { $0.reset() }
    }

    /// The level now and the `count` most recent 30 Hz values (oldest first).
    func snapshot(count: Int = 0) -> Snapshot {
        let now = Self.clock()
        return state.withLock { $0.snapshot(now: now, count: count) }
    }

    private static func clock() -> Double { ProcessInfo.processInfo.systemUptime }
}
