import CoreGraphics
import Foundation
import Testing
@testable import FairspokenCore

@Suite("Mic level")
struct MicLevelTests {
    /// Mean square of a signal at `db` dBFS RMS.
    private func power(_ db: Float) -> Float { pow(10, db / 10) }

    @Test func scaleIsLinearInDecibelsBetweenFloorAndCeiling() {
        #expect(MicLevel.normalized(decibels: -120) == 0)
        #expect(MicLevel.normalized(decibels: MicLevel.floorDB) == 0)
        #expect(MicLevel.normalized(decibels: MicLevel.ceilingDB) == 1)
        #expect(MicLevel.normalized(decibels: 0) == 1)
        let mid = (MicLevel.floorDB + MicLevel.ceilingDB) / 2
        #expect(abs(MicLevel.normalized(decibels: mid) - 0.5) < 0.0001)
        #expect(MicLevel.normalized(rms: 0) == 0)
        #expect(MicLevel.normalized(rms: 1) == 1)
    }

    @Test func normalSpeechIsClearlyVisibleAndRoomNoiseIsCalm() {
        // Normal speech at a normal distance: about -40 to -25 dBFS RMS.
        #expect(MicLevel.normalized(decibels: -40) > 0.3)
        #expect(MicLevel.normalized(decibels: -30) > 0.6)
        // A quiet room on a built-in mic: about -60 dBFS.
        #expect(MicLevel.normalized(decibels: -60) == 0)
        #expect(MicLevel.normalized(decibels: -54) == 0)
    }

    @Test func decibelsOfPower() {
        #expect(MicLevel.decibels(meanSquare: 0) == -120)
        #expect(abs(MicLevel.decibels(meanSquare: 0.01) - -20) < 0.001)
        #expect(abs(MicLevel.decibels(meanSquare: 1) - 0) < 0.001)
    }

    @Test func windowsCoverEverySample() {
        let samples: [Float] = [1, 1, 0, 0, 0.5]
        let windows = samples.withUnsafeBufferPointer { MicLevel.windowMeanSquares($0, window: 2) }
        #expect(windows == [1, 0, 0.25])
        let none = [Float]().withUnsafeBufferPointer { MicLevel.windowMeanSquares($0, window: 2) }
        #expect(none.isEmpty)
    }

    @Test func smootherAttacksFastAndReleasesSlowly() {
        var s = LevelSmoother(attack: 0.04, release: 0.25)
        // 50 ms of a loud syllable gets most of the way up.
        for _ in 0..<5 { s.step(toward: 1, dt: 0.01) }
        #expect(s.value > 0.7)
        // 50 ms of silence after it only falls a little…
        let peak = s.value
        for _ in 0..<5 { s.step(toward: 0, dt: 0.01) }
        #expect(s.value > peak * 0.8)
        // …and half a second later it has settled.
        for _ in 0..<50 { s.step(toward: 0, dt: 0.01) }
        #expect(s.value < 0.1)
    }

    @Test func smootherDoesNotDependOnStepSize() {
        var fine = LevelSmoother()
        var coarse = LevelSmoother()
        for _ in 0..<10 { fine.step(toward: 0.8, dt: 0.01) }
        coarse.step(toward: 0.8, dt: 0.1)
        #expect(abs(fine.value - coarse.value) < 0.0001)
    }

    @Test func aSingleNoiseClickBarelyMovesTheMeter() {
        var s = LevelSmoother()
        s.step(toward: 1, dt: 0.01)
        #expect(s.value < 0.25)
    }

    @Test func trackerPlaysABufferOutSmoothlyOverItsDuration() {
        var t = MicLevelTracker()
        // 100 ms of silence, then 100 ms of speech at -30 dBFS, each arriving as one buffer.
        t.feed(meanSquares: [Float](repeating: 0, count: 10), windowSeconds: 0.01, arrival: 10.0)
        t.feed(meanSquares: [Float](repeating: power(-30), count: 10), windowSeconds: 0.01, arrival: 10.1)
        // When the speech buffer arrives the meter is still showing the end of the silence…
        #expect(t.snapshot(now: 10.1, count: 1).level < 0.01)
        // …and it rises across the next 100 ms instead of jumping.
        let a = t.snapshot(now: 10.135, count: 1).level
        let b = t.snapshot(now: 10.17, count: 1).level
        let c = t.snapshot(now: 10.2, count: 1).level
        #expect(a > 0.05)
        #expect(a < b && b < c)
        #expect(c > 0.6)
        // It never runs ahead of the audio: later reads hold the newest value.
        #expect(t.snapshot(now: 11, count: 1).level == c)
    }

    @Test func trackerHistoryIsThirtyHertzOldestFirst() {
        var t = MicLevelTracker()
        t.feed(meanSquares: [Float](repeating: 0, count: 50), windowSeconds: 0.01, arrival: 0)
        t.feed(meanSquares: [Float](repeating: power(-20), count: 50), windowSeconds: 0.01, arrival: 0.5)
        let snap = t.snapshot(now: 2, count: 30)
        #expect(snap.history.count == 30)
        // The last second: half silence, half loud speech.
        #expect(snap.history.first == 0)
        #expect(snap.history.last! > 0.9)
        #expect(snap.history == snap.history.sorted())
        #expect(snap.history.last == snap.level)
    }

    @Test func trackerStartsEmptyAndResets() {
        var t = MicLevelTracker()
        #expect(t.snapshot(now: 1, count: 4) == .init(level: 0, history: [0, 0, 0, 0]))
        t.feed(meanSquares: [power(-20)], windowSeconds: 0.1, arrival: 1)
        #expect(t.snapshot(now: 5, count: 2).level > 0)
        t.reset()
        #expect(t.snapshot(now: 5, count: 2) == .init(level: 0, history: [0, 0]))
    }

    @Test func micCheckCountsMinus40dBFSAsSpeech() {
        #expect(SetupGuide.speechLevel == MicLevel.normalized(decibels: -40))
        #expect(SetupGuide.speechLevel > 0.2 && SetupGuide.speechLevel < 0.5)
    }
}

@Suite("Live text scroll")
struct ScrollFollowTests {
    @Test func followsTheNewestLineAsTextGrows() {
        var f = ScrollFollow()
        // One line, nothing to scroll.
        do { let jump = f.update(offset: 0, contentHeight: 16, viewportHeight: 16); #expect(!jump) }
        // The text grows past the viewport: jump to the bottom.
        do { let jump = f.update(offset: 0, contentHeight: 80, viewportHeight: 64); #expect(jump) }
        // The jump lands at the bottom: still following.
        do { let jump = f.update(offset: 16, contentHeight: 80, viewportHeight: 64); #expect(!jump) }
        #expect(f.following)
        do { let jump = f.update(offset: 16, contentHeight: 96, viewportHeight: 64); #expect(jump) }
    }

    @Test func scrollingUpPausesAndScrollingBackResumes() {
        var f = ScrollFollow()
        _ = f.update(offset: 32, contentHeight: 96, viewportHeight: 64)
        // The person scrolls up to read.
        do { let jump = f.update(offset: 10, contentHeight: 96, viewportHeight: 64); #expect(!jump) }
        #expect(!f.following)
        // New words arrive: the view stays where they are reading.
        do { let jump = f.update(offset: 10, contentHeight: 112, viewportHeight: 64); #expect(!jump) }
        #expect(!f.following)
        // Back to the bottom: following again, and the next words are followed.
        do { let jump = f.update(offset: 48, contentHeight: 112, viewportHeight: 64); #expect(!jump) }
        #expect(f.following)
        do { let jump = f.update(offset: 48, contentHeight: 128, viewportHeight: 64); #expect(jump) }
    }

    @Test func textShrinkingToTheBottomResumesFollowing() {
        var f = ScrollFollow()
        _ = f.update(offset: 48, contentHeight: 112, viewportHeight: 64)
        _ = f.update(offset: 10, contentHeight: 112, viewportHeight: 64)
        #expect(!f.following)
        // A re-decode shortens the text; the view is clamped to the bottom.
        do { let jump = f.update(offset: 0, contentHeight: 64, viewportHeight: 64); #expect(!jump) }
        #expect(f.following)
        do { let jump = f.update(offset: 0, contentHeight: 80, viewportHeight: 64); #expect(jump) }
    }

    @Test func nearTheBottomCountsAsTheBottom() {
        #expect(ScrollFollow.isAtBottom(offset: 30, contentHeight: 96, viewportHeight: 64))
        #expect(!ScrollFollow.isAtBottom(offset: 20, contentHeight: 96, viewportHeight: 64))
        // Shorter than the viewport: always at the bottom.
        #expect(ScrollFollow.isAtBottom(offset: 0, contentHeight: 30, viewportHeight: 64))
    }

    @Test func theViewportGrowingIsNotAScroll() {
        // The pill grows from two lines to three as the words arrive.
        var g = ScrollFollow()
        _ = g.update(offset: 0, contentHeight: 32, viewportHeight: 32)
        do { let jump = g.update(offset: 0, contentHeight: 48, viewportHeight: 48); #expect(!jump) }
        #expect(g.following)
    }

    @Test func fadeShowsOnlyWithTextAbove() {
        #expect(!ScrollFollow.hasMoreAbove(offset: 0))
        #expect(!ScrollFollow.hasMoreAbove(offset: 2))
        #expect(ScrollFollow.hasMoreAbove(offset: 12))
    }
}
