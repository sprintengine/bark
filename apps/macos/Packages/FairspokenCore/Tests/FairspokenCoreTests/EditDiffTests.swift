import Foundation
import Testing
@testable import FairspokenCore

/// The cases of `edit_diff.rs`'s tests, plus `misheard_as` and `contains_words`.
@Suite("Edit diff")
struct EditDiffTests {
    /// The field before insertion is `before|after`, with the caret at `|`; returns the anchor
    /// and the field's text right after the insertion.
    private func insert(_ field: String, _ inserted: String) -> (InsertionAnchor, String) {
        let parts = field.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let (before, after) = (parts[0], parts[1])
        let anchor = InsertionAnchor(field: before + after, selectionStart: before.utf16.count, selectionLength: 0, inserted: inserted)
        return (anchor, before + inserted + after)
    }

    private func fix(_ heard: String, _ intended: String) -> Mishearing { Mishearing(heard: heard, intended: intended) }

    @Test func typoFixIsFoundAndClassified() throws {
        let (anchor, inserted) = insert("Dear team,\n|\nThanks, Aoife", "Their going to ship the release on Friday. ")
        let edited = inserted.replacingOccurrences(of: "Their", with: "They're")
        let region = try #require(anchor.locate(in: edited))
        #expect(region == "They're going to ship the release on Friday. ")
        #expect(EditDiff.classify(inserted: anchor.inserted, edited: region) == .edited(fixes: [fix("Their", "They're")]))
    }

    @Test func nameFixIsAMisheardCandidate() throws {
        let (anchor, inserted) = insert("Notes: |", "Ask cloud code to rebase the branch. ")
        let edited = inserted.replacingOccurrences(of: "cloud code", with: "Claude Code")
        let region = try #require(anchor.locate(in: edited))
        #expect(EditDiff.classify(inserted: anchor.inserted, edited: region) == .edited(fixes: [fix("cloud code", "Claude Code")]))
    }

    @Test func capitalisingANameCountsAsAFix() {
        #expect(EditDiff.classify(inserted: "send it to niamh today", edited: "send it to Niamh today")
            == .edited(fixes: [fix("niamh", "Niamh")]))
    }

    @Test func fullRewriteYieldsNoFixes() throws {
        let (anchor, _) = insert("Subject line|", " I went to the shop to buy some milk and bread. ")
        let rewritten = "Subject line Picked up groceries this morning, all sorted. "
        let region = try #require(anchor.locate(in: rewritten))
        #expect(EditDiff.classify(inserted: anchor.inserted, edited: region) == .rewrite)
    }

    @Test func unrelatedReplacementAndPureInsertionsAreIgnored() {
        #expect(EditDiff.classify(inserted: "please send the report to the board",
                                  edited: "please send the final report to the committee") == .edited(fixes: []))
        #expect(EditDiff.classify(inserted: "Meeting at noon.", edited: "Meeting at noon!") == .unchanged)
    }

    @Test func textTypedBeforeTheRegionShiftsOffsetsButNotTheMatch() throws {
        let (anchor, inserted) = insert("Hello Seán,\n\n|\n\nBest wishes", "The results from Beaumont came back normal. ")
        // The user adds a paragraph above, then fixes the dictation.
        let edited = inserted
            .replacingOccurrences(of: "Hello Seán,", with: "Hello Seán,\n\nA quick update before the weekend.")
            .replacingOccurrences(of: "normal", with: "normal again")
        let region = try #require(anchor.locate(in: edited))
        #expect(region == "The results from Beaumont came back normal again. ")
        #expect(EditDiff.classify(inserted: anchor.inserted, edited: region) == .edited(fixes: []))
    }

    @Test func editedContextFallsBackToAShorterAnchor() throws {
        let (anchor, inserted) = insert("The first paragraph is long enough to need trimming down. |", "Book a table at four. ")
        let edited = inserted
            .replacingOccurrences(of: "The first paragraph", with: "Our opening paragraph")
            .replacingOccurrences(of: "four", with: "for")
        #expect(anchor.locate(in: edited) == "Book a table at for. ")
    }

    @Test func emojiBeforeTheCaretConvertsUTF16Offsets() throws {
        // Each emoji is two UTF-16 code units but one character.
        let (anchor, inserted) = insert("🎉🎉 Party |🥳 tonight", "with siobhan ")
        #expect(anchor.start == 9)
        #expect(anchor.before == "🎉🎉 Party ")
        #expect(anchor.after == "🥳 tonight")
        let edited = inserted.replacingOccurrences(of: "siobhan", with: "Siobhán")
        let region = try #require(anchor.locate(in: edited))
        #expect(region == "with Siobhán ")
        #expect(EditDiff.classify(inserted: anchor.inserted, edited: region) == .edited(fixes: [fix("siobhan", "Siobhán")]))
    }

    @Test func selectionReplacedByTheDictationIsExcludedFromTheContext() {
        // "Bob" is selected: UTF-16 offset 8 (the emoji counts twice), length 3.
        let anchor = InsertionAnchor(field: "Call 🙂 Bob about it", selectionStart: 8, selectionLength: 3, inserted: "Rob")
        #expect(anchor.before == "Call 🙂 ")
        #expect(anchor.after == " about it")
    }

    @Test func deletedContextOrDictationIsNotFound() {
        let (anchor, _) = insert("Intro text here. |Closing text here.", "Dictated words. ")
        #expect(anchor.locate(in: "Something else entirely") == nil)
    }

    @Test func typingOnAfterADictationAtTheEndIsNotPartOfIt() throws {
        let (anchor, inserted) = insert("Plan:\n|", "Ship the beta on Monday. ")
        let edited = inserted + "Then write the release notes and tell the team."
        let region = try #require(anchor.locate(in: edited))
        #expect(region == "Ship the beta on Monday. ")
        #expect(EditDiff.classify(inserted: anchor.inserted, edited: region) == .unchanged)
    }

    @Test func contextIsCappedEitherSide() {
        let long = String(repeating: "word ", count: 40)
        let anchor = InsertionAnchor(field: long + long, selectionStart: long.utf16.count, selectionLength: 0, inserted: "x")
        #expect(anchor.before.count == EditDiff.contextCharacters)
        #expect(anchor.after.count == EditDiff.contextCharacters)
        #expect(anchor.start == long.count)
    }

    @Test func misheardAsAcceptsCloseRespellingsOnly() {
        #expect(EditDiff.misheardAs("cloud code", "Claude Code"))
        #expect(EditDiff.misheardAs("rocket deck", "RocketDeck"))
        #expect(EditDiff.misheardAs("jon", "John"))
        #expect(EditDiff.misheardAs("siobhan", "Siobhán"))
        #expect(!EditDiff.misheardAs("board", "committee"))
        #expect(!EditDiff.misheardAs("dog", "cat"))
        #expect(!EditDiff.misheardAs("", "anything"))
    }

    @Test func containsWordsMatchesWholeWordsInOrder() {
        #expect(EditDiff.containsWords("Ask cloud code, please.", "cloud code"))
        #expect(EditDiff.containsWords("ask Cloud Code", "cloud code"))
        #expect(!EditDiff.containsWords("ask cloudy code", "cloud code"))
        #expect(!EditDiff.containsWords("code cloud", "cloud code"))
        #expect(!EditDiff.containsWords("anything", ""))
    }
}
