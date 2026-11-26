import Foundation
import Testing
@testable import FairspokenCore

/// Stands in for `DictationController`: the lifecycle decides, this does what the controller
/// does with the microphone, the session and the background transcription.
private final class FakeSession {
    let name: String
    var cancelled = false
    init(_ name: String) { self.name = name }
}

private final class Harness {
    var lifecycle = DictationLifecycle<FakeSession>()
    var mode: RecordingShortcutMode = .toggle
    var micOn = false
    var started: [String] = []
    /// Transcriptions still running, by dictation id (the controller's background task).
    var running: [Int] = []
    var delivered: [Int] = []
    var dropped: [Int] = []

    func press(_ event: DictationTriggerEvent) {
        switch lifecycle.action(for: event, shortcutMode: mode) {
        case .start(let trigger):
            let session = FakeSession("dictation \(lifecycle.id + 1)")
            micOn = true
            started.append(session.name)
            lifecycle.begin(trigger, session: session)
        case .stop:
            stop()
        case .ignore:
            break
        }
    }

    func stop() {
        guard case let (id, session)? = lifecycle.endListening() else { return }
        micOn = false
        #expect(session != nil, "the session must reach stop()")
        running.append(id)
    }

    /// The transcript is delivered (`complete()`): the pill shows "done" while the task that
    /// produced it is still winding down.
    func deliver(_ id: Int) {
        guard lifecycle.isTranscribing(id) else {
            dropped.append(id)
            return
        }
        delivered.append(id)
        lifecycle.finish(id)
    }

    /// The background task's last step, possibly long after `deliver`.
    @discardableResult
    func taskFinishes(_ id: Int) -> Bool {
        running.removeAll { $0 == id }
        return lifecycle.finish(id)
    }

    func escape() -> (id: Int, stage: DictationLifecycle<FakeSession>.Stage, session: FakeSession?)? {
        guard let cancelled = lifecycle.cancel() else { return nil }
        micOn = false
        cancelled.session?.cancelled = true
        return cancelled
    }
}

@Suite struct DictationLifecycleTests {
    /// The race the founder hit: fn pressed again 15 ms after "done", while the first
    /// dictation's task was still finishing. Its late finish used to wipe the new recording's
    /// session, and every later stop silently did nothing.
    @Test func aLateFinishCannotTakeOverTheNextRecording() {
        let h = Harness()
        h.press(.fnDown)
        #expect(h.lifecycle.stage == .listening(.fn))
        h.press(.fnUp)
        #expect(h.lifecycle.stage == .transcribing)
        #expect(!h.micOn)
        h.deliver(1)
        #expect(h.lifecycle.stage == .idle)

        // The next dictation starts before the first one's task has finished.
        h.press(.fnDown)
        #expect(h.lifecycle.id == 2)
        #expect(h.lifecycle.stage == .listening(.fn))
        #expect(h.micOn)

        // Now the first task finishes: it is not current, so it changes nothing.
        #expect(h.taskFinishes(1) == false)
        #expect(h.lifecycle.stage == .listening(.fn))
        #expect(h.lifecycle.id == 2)

        // And the second recording still stops.
        h.press(.fnUp)
        #expect(h.lifecycle.stage == .transcribing)
        #expect(!h.micOn)
        #expect(h.running == [2])
        h.deliver(2)
        #expect(h.delivered == [1, 2])
        #expect(h.taskFinishes(2) == false)
        #expect(h.lifecycle.stage == .idle)
    }

    @Test func aRecordingThatFailsIsFinishedByItsTaskOnly() {
        let h = Harness()
        h.press(.button)
        h.press(.button)
        // No speech, or kept to retry: the task finishes it and may say so.
        #expect(h.taskFinishes(1))
        #expect(h.lifecycle.stage == .idle)
        #expect(!h.taskFinishes(1))
    }

    @Test func escapeWhileTranscribingDropsTheLateTranscript() {
        let h = Harness()
        h.press(.shortcutDown)
        h.press(.shortcutDown)
        #expect(h.lifecycle.stage == .transcribing)
        // Transcribing ignores the triggers.
        h.press(.shortcutDown)
        h.press(.fnDown)
        h.press(.button)
        #expect(h.lifecycle.stage == .transcribing)

        let cancelled = h.escape()
        #expect(cancelled?.id == 1)
        #expect(cancelled?.stage == .transcribing)
        #expect(cancelled?.session == nil, "the session went to stop()")
        #expect(h.lifecycle.stage == .idle)

        // The transcript lands afterwards: dropped, and the task changes nothing.
        h.deliver(1)
        #expect(h.dropped == [1])
        #expect(h.delivered.isEmpty)
        #expect(!h.taskFinishes(1))

        // A new dictation works as usual.
        h.press(.shortcutDown)
        #expect(h.lifecycle.stage == .listening(.hotkey))
        #expect(h.lifecycle.id == 2)
    }

    @Test func escapeWhileListeningHandsBackTheSessionToCancel() {
        let h = Harness()
        h.press(.fnDown)
        let cancelled = h.escape()
        #expect(cancelled?.stage == .listening(.fn))
        #expect(cancelled?.session?.cancelled == true)
        #expect(!h.micOn)
        #expect(h.escape() == nil)
        // Fn's release, after Escape, does nothing.
        h.press(.fnUp)
        #expect(h.lifecycle.stage == .idle)
    }

    @Test(arguments: [DictationTrigger.hotkey, .fn, .button])
    func anyTriggerStopsARecordingWhicheverStartedIt(_ started: DictationTrigger) {
        let start: DictationTriggerEvent = switch started {
        case .hotkey: .shortcutDown
        case .fn: .fnDown
        case .button: .button
        }
        for mode in RecordingShortcutMode.allCases {
            for stopper in [DictationTriggerEvent.shortcutDown, .fnDown, .button] where stopper != start {
                let h = Harness()
                h.mode = mode
                h.press(start)
                #expect(h.lifecycle.stage == .listening(started))
                h.press(stopper)
                #expect(h.lifecycle.stage == .transcribing, "\(stopper) should stop a recording started by \(started) (\(mode))")
                #expect(!h.micOn)
            }
        }
    }

    @Test func releasingAKeyEndsOnlyTheRecordingThatKeyStarted() {
        let h = Harness()
        h.mode = .pushToTalk
        h.press(.button)
        h.press(.fnUp)
        h.press(.shortcutUp)
        #expect(h.lifecycle.stage == .listening(.button))

        let fn = Harness()
        fn.mode = .pushToTalk
        fn.press(.fnDown)
        fn.press(.shortcutUp)
        #expect(fn.lifecycle.stage == .listening(.fn))
        fn.press(.fnUp)
        #expect(fn.lifecycle.stage == .transcribing)
    }

    @Test func theShortcutTogglesOrIsHeld() {
        let toggle = Harness()
        toggle.press(.shortcutDown)
        toggle.press(.shortcutUp)
        #expect(toggle.lifecycle.stage == .listening(.hotkey))
        toggle.press(.shortcutDown)
        #expect(toggle.lifecycle.stage == .transcribing)

        let held = Harness()
        held.mode = .pushToTalk
        held.press(.shortcutDown)
        // A repeated key-down while it is held doesn't end it; the release does.
        held.press(.shortcutDown)
        #expect(held.lifecycle.stage == .listening(.hotkey))
        held.press(.shortcutUp)
        #expect(held.lifecycle.stage == .transcribing)
    }

    @Test func aMissedFnReleaseIsEndedByTheNextPress() {
        let h = Harness()
        h.press(.fnDown)
        // The release was lost; the next press stops rather than doing nothing.
        h.press(.fnDown)
        #expect(h.lifecycle.stage == .transcribing)
        #expect(!h.micOn)
    }

    @Test func stoppingWhenNothingListensChangesNothing() {
        var lifecycle = DictationLifecycle<FakeSession>()
        let ended = lifecycle.endListening()
        #expect(ended == nil)
        let finished = lifecycle.finish(0)
        #expect(!finished)
        let cancelled = lifecycle.cancel()
        #expect(cancelled == nil)
        lifecycle.begin(.button, session: FakeSession("a"))
        let finishedWhileListening = lifecycle.finish(1)
        #expect(!finishedWhileListening, "a listening dictation is ended by stopping it, not finished")
        #expect(lifecycle.isListening)
    }

    @Test func theDeadlineAllowsForTheModelTheHostAndLongRecordings() {
        let local = DictationLifecycle<FakeSession>.transcribingDeadline(recordingSeconds: 10, engineReady: true, remoteTimeoutSeconds: nil)
        #expect(local == .seconds(35))
        let loading = DictationLifecycle<FakeSession>.transcribingDeadline(recordingSeconds: 10, engineReady: false, remoteTimeoutSeconds: nil)
        #expect(loading == .seconds(215))
        // The live answer's timeout, plus the 30 s of quick re-sends, plus this Mac.
        let host = DictationLifecycle<FakeSession>.transcribingDeadline(recordingSeconds: 10, engineReady: true, remoteTimeoutSeconds: 20)
        #expect(host == .seconds(85))
        let long = DictationLifecycle<FakeSession>.transcribingDeadline(recordingSeconds: 3600, engineReady: false, remoteTimeoutSeconds: 300)
        #expect(long == .seconds(900))
    }
}
