import Foundation

/// The live microphone level the meters draw: a perceptual (dBFS) scale, attack/release
/// smoothing, and a steady 30 Hz series played out in real time.
///
/// Capture hands over audio in buffers of up to 100 ms (macOS often delivers 4800 frames at
/// 48 kHz), so a meter that only moved per buffer would step ten times a second. The tracker
/// measures 10 ms windows, smooths them in audio time, keeps one value per 30 Hz tick, and
/// replays those ticks against the clock, one buffer behind, so a reader polling at 30 Hz sees
/// a smooth line rather than bursts.
public enum MicLevel {
    /// Silence and room noise sit at or below this (built-in and USB mics: about -60 to -50).
    public static let floorDB: Float = -52
    /// Loud speech close to the mic. Normal speech at a normal distance (about -40 to -25 dBFS
    /// RMS) then fills a third to most of the meter.
    public static let ceilingDB: Float = -20
    /// The window the level is measured over.
    public static let windowSeconds = 0.01

    /// dBFS of a mean square (power); -120 for silence.
    public static func decibels(meanSquare: Float) -> Float {
        guard meanSquare > 1e-12 else { return -120 }
        return 10 * log10(meanSquare)
    }

    /// 0…1 from dBFS, linear in decibels between the floor and the ceiling.
    public static func normalized(decibels db: Float) -> Float {
        max(0, min(1, (db - floorDB) / (ceilingDB - floorDB)))
    }

    /// 0…1 from an RMS amplitude.
    public static func normalized(rms: Float) -> Float {
        normalized(decibels: decibels(meanSquare: rms * rms))
    }

    /// Mean square of each consecutive `window`-sample run of `samples` (a short tail counts as
    /// its own window).
    public static func windowMeanSquares(_ samples: UnsafeBufferPointer<Float>, window: Int) -> [Float] {
        guard window > 0, !samples.isEmpty else { return [] }
        var out: [Float] = []
        out.reserveCapacity(samples.count / window + 1)
        var start = 0
        while start < samples.count {
            let end = min(samples.count, start + window)
            var sum: Float = 0
            for i in start..<end { sum += samples[i] * samples[i] }
            out.append(sum / Float(end - start))
            start = end
        }
        return out
    }
}

/// One-pole attack/release follower: rises quickly to a louder value, falls back slowly, so
/// the meter jumps with each syllable and settles calmly in pauses. Time constants are in
/// seconds, so the feel doesn't depend on how often it is stepped.
public struct LevelSmoother: Equatable, Sendable {
    public var attack: Double
    public var release: Double
    public private(set) var value: Float = 0

    public init(attack: Double = 0.04, release: Double = 0.25) {
        self.attack = attack
        self.release = release
    }

    @discardableResult
    public mutating func step(toward target: Float, dt: Double) -> Float {
        let tau = target > value ? attack : release
        let k = tau > 0 ? Float(1 - exp(-max(0, dt) / tau)) : 1
        value += (target - value) * k
        return value
    }

    public mutating func reset() { value = 0 }
}

/// The level and its recent history, as of a moment. See `MicLevel`.
public struct MicLevelTracker: Sendable {
    public static let tickSeconds = 1.0 / 30
    /// Ticks kept: the longest meter (44 bars) plus a buffer's worth of play-out delay.
    public static let capacity = 96

    public struct Snapshot: Equatable, Sendable {
        /// The current level, 0…1.
        public var level: Float
        /// Oldest first, newest last; `count` values, 0 where there is no audio yet.
        public var history: [Float]
    }

    private var smoother = LevelSmoother()
    private var ring = [Float](repeating: 0, count: MicLevelTracker.capacity)
    /// Ticks written so far; tick `k` (1-based) covers audio time `k * tickSeconds`.
    private var ticks = 0
    private var audioTime = 0.0
    private var anchor: (wall: Double, audio: Double)?
    private var delay = 0.1

    public init() {}

    /// Feeds one capture buffer, measured as windows of `windowSeconds` each, that arrived at
    /// `arrival` (seconds on a monotonic clock).
    public mutating func feed(meanSquares: [Float], windowSeconds: Double, arrival: Double) {
        guard !meanSquares.isEmpty, windowSeconds > 0 else { return }
        for ms in meanSquares {
            smoother.step(toward: MicLevel.normalized(decibels: MicLevel.decibels(meanSquare: ms)), dt: windowSeconds)
            audioTime += windowSeconds
            while Double(ticks + 1) * Self.tickSeconds <= audioTime + 1e-9 {
                ring[ticks % Self.capacity] = smoother.value
                ticks += 1
            }
        }
        // Play out one buffer behind the clock, so the next buffer lands before it is needed.
        delay = min(0.25, max(Self.tickSeconds, Double(meanSquares.count) * windowSeconds))
        anchor = (arrival, audioTime)
    }

    public mutating func reset() { self = MicLevelTracker() }

    /// The level at `now` and the `count` ticks before it.
    public func snapshot(now: Double, count: Int) -> Snapshot {
        let count = max(0, count)
        guard let anchor, ticks > 0 else { return Snapshot(level: 0, history: [Float](repeating: 0, count: count)) }
        // Audio time on screen: advances with the clock, never past what has arrived.
        let t = max(0, min(anchor.audio, anchor.audio + (now - anchor.wall) - delay))
        let position = t / Self.tickSeconds
        let newest = min(ticks, Int(position.rounded(.down)))
        let fraction = Float(position - Double(newest))
        let current = value(at: newest)
        let next = newest < ticks ? value(at: newest + 1) : current
        let level = current + (next - current) * max(0, min(1, fraction))
        var history = [Float](repeating: 0, count: count)
        for i in 0..<count {
            history[count - 1 - i] = value(at: newest - i)
        }
        if count > 0 { history[count - 1] = level }
        return Snapshot(level: level, history: history)
    }

    /// Tick `k`'s level, 0 before the first tick or once it has left the ring.
    private func value(at k: Int) -> Float {
        guard k >= 1, k <= ticks, k > ticks - Self.capacity else { return 0 }
        return ring[(k - 1) % Self.capacity]
    }
}
