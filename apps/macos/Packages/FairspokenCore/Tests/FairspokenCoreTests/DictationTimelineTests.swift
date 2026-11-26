import Foundation
import Testing
@testable import FairspokenCore

@Suite("Dictation timeline")
struct DictationTimelineTests {
    private func item(transcribe: Int, model: Int, total: Int, cleanup: Int? = 5, destination: Int? = nil,
                      paste: Int? = nil, remote: Bool = false, note: Bool = false) -> TranscriptHistoryItem {
        TranscriptHistoryItem(id: "t", createdAt: 0, text: "Hello", backend: "parakeet", location: remote ? "remote-host" : "local",
                              durationSeconds: 3, timings: DictationTimings(transcribeMs: transcribe, speechModelMs: model, totalMs: total),
                              isNote: note ? true : nil, cleanupMs: cleanup, destinationMs: destination, pasteMs: paste)
    }

    @Test func everyRecordedStepInOrderAddingUpToTheTotal() throws {
        let t = try #require(DictationTimeline(item(transcribe: 6400, model: 6280, total: 6900, cleanup: 7, destination: 12, paste: 470)))
        #expect(t.steps.map(\.kind) == [.speechModel, .handover, .destination, .cleanup, .paste, .other])
        #expect(t.steps.map(\.ms) == [6280, 120, 12, 7, 470, 11])
        #expect(t.totalMs == 6900)
        #expect(t.steps.reduce(0) { $0 + $1.ms } == 6900)
        #expect(t.dominant?.kind == .speechModel)
    }

    @Test func anOlderDictationPutsTheUntimedRestUnderOneStep() throws {
        let t = try #require(DictationTimeline(item(transcribe: 300, model: 250, total: 800)))
        #expect(t.steps.last?.title == "Finding the app and pasting")
        #expect(t.steps.last?.ms == 495)
    }

    @Test func aServerDictationNamesTheServerAndTheNetwork() throws {
        let t = try #require(DictationTimeline(item(transcribe: 400, model: 90, total: 460, destination: 3, paste: 30, remote: true)))
        #expect(t.steps.first?.title == "Speech model on Bark Server")
        #expect(t.steps.dropFirst().first?.title == "Network")
    }

    @Test func noTimelineForANoteOrADictationWithoutTimings() {
        #expect(DictationTimeline(item(transcribe: 10, model: 5, total: 20, note: true)) == nil)
        var old = item(transcribe: 10, model: 5, total: 20)
        old.timings = nil
        #expect(DictationTimeline(old) == nil)
    }

    @Test func noDominantStepWhenTheTimeIsSpread() throws {
        let t = try #require(DictationTimeline(item(transcribe: 400, model: 300, total: 1000, cleanup: 5, destination: 5, paste: 300)))
        #expect(t.dominant == nil)
    }

    @Test func timesReadInMillisecondsThenSeconds() {
        #expect(DictationTimeline.format(23) == "23 ms")
        #expect(DictationTimeline.format(6870) == "6.9 s")
    }

    @Test func theNewTimesSurviveARoundTrip() throws {
        let original = item(transcribe: 300, model: 250, total: 800, destination: 9, paste: 31)
        let data = try JSONEncoder().encode([original])
        let back = try JSONDecoder().decode([TranscriptHistoryItem].self, from: data)
        #expect(back.first?.destinationMs == 9)
        #expect(back.first?.pasteMs == 31)
    }
}
