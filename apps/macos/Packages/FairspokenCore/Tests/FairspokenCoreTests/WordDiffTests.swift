import Testing
@testable import FairspokenCore

@Suite("Word diff")
struct WordDiffTests {
    @Test func marksFillersAndCorrections() {
        let diff = WordDiff(from: "um so can you send it by Thursday no wait Friday",
                            to: "Can you send it by Friday?")
        #expect(diff.runs.map(\.kind) == [.removed, .same, .removed, .same])
        #expect(diff.runs[0].text == "um so")
        // A kept run shows the pasted spelling.
        #expect(diff.runs[1].text == "Can you send it by")
        #expect(diff.runs[2].text == "Thursday no wait")
        #expect(diff.runs[3].text == "Friday?")
        #expect(diff.removedCount == 5)
        #expect(diff.addedCount == 0)
        #expect(diff.changeCount == 2)
        #expect(diff.removedInOriginal == [true, true, false, false, false, false, false, true, true, true, false])
    }

    @Test func replacementIsRemovedThenAdded() {
        let diff = WordDiff(from: "he's sort of handling it", to: "He is handling it")
        #expect(diff.runs.map(\.kind) == [.removed, .added, .same])
        #expect(diff.runs[0].text == "he's sort of")
        #expect(diff.runs[1].text == "He is")
        #expect(diff.changeCount == 1)
    }

    @Test func identicalTextIsUnchanged() {
        let diff = WordDiff(from: "Running late.", to: "running late")
        #expect(diff.isUnchanged)
        #expect(WordDiff(from: "", to: "").runs.isEmpty)
    }

    @Test func additionsOnly() {
        let diff = WordDiff(from: "could you send it", to: "Hi Aoife, could you send it Thanks, Sam")
        #expect(diff.runs.map(\.kind) == [.added, .same, .added])
        #expect(diff.addedCount == 4)
    }
}
