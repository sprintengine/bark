import Foundation
import Testing
@testable import FairspokenCore

/// The cases of `learned.rs`'s tests, plus the settings and corrections they feed.
@Suite("Learned store")
struct LearnedStoreTests {
    private let model = "parakeet-tdt-0.6b-v3"

    private func fix(_ heard: String, _ intended: String) -> Mishearing { Mishearing(heard: heard, intended: intended) }

    /// The Irish general practice pack the app bundles, read from the Tauri app's sources.
    private static let packDrugs: DrugLexicon = {
        // Tests/FairspokenCoreTests/<file> → FairspokenCore → Packages → macos → apps → the repo.
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { repo.deleteLastPathComponent() }
        let pack = repo.appendingPathComponent("src-tauri/packs/ie-general-practice.json")
        return DrugLexicon(packs: [(try? Data(contentsOf: pack)) ?? Data()])
    }()

    @Test func uncommonNameJoinsTheVocabularyOnTheFirstFix() {
        var store = LearnedStore()
        #expect(store.observe(fix("Neve", "Niamh"), model: model, now: 1) == [.vocabulary("Niamh")])
        // A second sighting adds the scoped correction, never the term again.
        #expect(store.observe(fix("neve", "Niamh"), model: model, now: 2) == [.correction(from: "Neve", to: "Niamh", models: [model])])
        #expect(store.observe(fix("Neve", "Niamh"), model: model, now: 3).isEmpty)
    }

    @Test func commonWordMappingNeedsTwoSightingsAndRecordsItsModels() {
        var store = LearnedStore()
        #expect(store.observe(fix("their", "there"), model: model, now: 1).isEmpty)
        #expect(store.observe(fix("their", "there"), model: "large-v3-turbo", now: 2)
            == [.correction(from: "their", to: "there", models: [model, "large-v3-turbo"])])
    }

    @Test func sentenceInitialCapitalsAndCaseOnlyFixesAreNotCorrections() {
        var store = LearnedStore()
        #expect(store.observe(fix("Their", "They're"), model: model, now: 1).isEmpty)
        // "niamh" → "Niamh" earns the term but never a correction.
        #expect(store.observe(fix("niamh", "Niamh"), model: model, now: 1) == [.vocabulary("Niamh")])
        #expect(store.observe(fix("niamh", "Niamh"), model: model, now: 2).isEmpty)
    }

    @Test func medicinePairsAndLookAlikesAreOnlySuggested() throws {
        var store = LearnedStore()
        // Both sides look like medicines (suffix rule).
        #expect(store.observe(fix("omeprazole", "esomeprazole"), model: model, now: 1).isEmpty)
        // One side is on the look-alike/sound-alike list.
        #expect(store.observe(fix("hydroxyzine", "hydralazine"), model: model, now: 1).isEmpty)
        #expect(store.observe(fix("hydroxyzine", "hydralazine"), model: model, now: 2).isEmpty)
        let suggestions = store.suggestions
        #expect(suggestions.count == 2)
        #expect(suggestions.allSatisfy { $0.reason == LearnedStore.medicineReason })

        // Accepting applies the correction; it is then no longer suggested.
        let accepted = store.accept(suggestions[1].id)
        #expect(accepted == .correction(from: "hydroxyzine", to: "hydralazine", models: [model]))
        let again = store.accept(suggestions[1].id)
        #expect(again == nil)
        let dismissed = store.dismiss(suggestions[0].id)
        #expect(dismissed)
        #expect(store.suggestions.isEmpty)
        #expect(store.observe(fix("omeprazole", "esomeprazole"), model: model, now: 3).isEmpty)
    }

    @Test func aCommonWordHeardForAMedicineStillLearns() {
        var store = LearnedStore()
        // Only the intended side is a medicine, and not a look-alike one.
        #expect(store.observe(fix("ram a pill", "ramipril"), model: model, now: 1).isEmpty)
        #expect(store.observe(fix("ram a pill", "ramipril"), model: model, now: 2)
            == [.correction(from: "ram a pill", to: "ramipril", models: [model])])
        #expect(store.suggestions.isEmpty)
    }

    @Test func bundledPackMedicinesCountAsMedical() {
        #expect(!Self.packDrugs.isEmpty)
        let store = LearnedStore(drugs: Self.packDrugs)
        #expect(store.looksMedical("Zyloric"))
        #expect(store.looksMedical("allopurinol"))
        #expect(!LearnedStore().looksMedical("Zyloric"))
        for word in ["Healthlink", "kubectl", "patient", "tablet"] { #expect(!Self.packDrugs.contains(word), "\(word)") }
        #expect(Self.packDrugs.contains("CO-CODAMOL"))
        // A brand to its substance: both medicines only through the pack, so a suggestion at once.
        var learning = LearnedStore(drugs: Self.packDrugs)
        #expect(learning.observe(fix("Zyloric", "allopurinol"), model: model, now: 1).isEmpty)
        #expect(learning.suggestions.first?.reason == LearnedStore.medicineReason)
        var plain = LearnedStore()
        _ = plain.observe(fix("Zyloric", "allopurinol"), model: model, now: 1)
        #expect(plain.suggestions.isEmpty)
    }

    @Test func shortSingleWordsWaitForTheUser() {
        var store = LearnedStore()
        _ = store.observe(fix("an", "and"), model: model, now: 1)
        #expect(store.observe(fix("an", "and"), model: model, now: 2).isEmpty)
        #expect(store.suggestions.first?.reason == LearnedStore.shortWordReason)
    }

    @Test func promotionsMarkLearnedEntriesAndRespectTheUsersOwn() {
        var settings = AppSettings()
        settings.transcriptCorrections = [TranscriptCorrection(from: "fair spoken", to: "FairSpoken")]
        let changes = LearnedStore.apply([
            .vocabulary("Niamh"),
            .vocabulary("niamh"),
            .correction(from: "Fair Spoken", to: "Fairspoken", models: []),
            .correction(from: "cloud code", to: "Claude Code", models: [model]),
        ], to: &settings)
        #expect(changes.count == 2)
        #expect(settings.vocabularyHints == ["Niamh"])
        #expect(settings.learnedVocabularyHints == ["Niamh"])
        #expect(settings.transcriptCorrections.count == 2)
        #expect(settings.transcriptCorrections[0].origin == .manual)
        #expect(settings.transcriptCorrections[1].origin == .learned)
        #expect(settings.transcriptCorrections[1].models == [model])
    }

    @Test func aFullDictionaryIsLeftAlone() {
        var settings = AppSettings()
        settings.vocabularyHints = (0..<50).map { "Term\($0)" }
        #expect(LearnedStore.apply([.vocabulary("Niamh")], to: &settings).isEmpty)
        #expect(settings.vocabularyHints.count == 50)
    }

    @Test func storeRoundTripsThroughItsFile() throws {
        var first = LearnedStore()
        _ = first.observe(fix("cloud", "Claude"), model: model, now: 1)
        let data = try first.encoded()
        let reloaded = LearnedStore.load(data)
        #expect(reloaded.items.count == 1)
        #expect(reloaded.items[0].intended == "Claude")
        #expect(reloaded.items[0].vocabulary)
        // A missing or unreadable file is an empty store.
        #expect(LearnedStore.load(nil).items.isEmpty)
        #expect(LearnedStore.load(Data("not json".utf8)).items.isEmpty)
    }

    @Test func readsTheRustFile() throws {
        let rust = #"{"items":[{"id":"a","heard":"hydroxyzine","intended":"hydralazine","count":1,"firstSeen":1,"lastSeen":1,"models":["parakeet-tdt-0.6b-v3"],"status":"suggested","vocabulary":false,"reason":"Medicine names are never changed automatically. Check this before accepting it."},{"id":"b","heard":"x","intended":"y","count":2,"firstSeen":1,"lastSeen":2}]}"#
        let store = LearnedStore.load(Data(rust.utf8))
        #expect(store.items.count == 2)
        #expect(store.suggestions.map(\.id) == ["a"])
        #expect(store.items[1].status == .observed)
        let json = try JSONSerialization.jsonObject(with: store.encoded()) as? [String: Any]
        let first = (json?["items"] as? [[String: Any]])?.first
        #expect(first?["status"] as? String == "suggested")
        #expect(first?["firstSeen"] as? Int == 1)
    }

    @Test func oldestSettledItemsAreForgottenBeyondTheCap() {
        var store = LearnedStore()
        _ = store.observe(fix("hydroxyzine", "hydralazine"), model: model, now: 0)
        for i in 1...LearnedStore.maxItems { _ = store.observe(fix("word\(i)", "ward\(i)"), model: model, now: Int64(i)) }
        #expect(store.items.count == LearnedStore.maxItems)
        // The suggestion is the oldest but waits for the user; the oldest settled item went.
        #expect(store.suggestions.count == 1)
        #expect(!store.items.contains { $0.heard == "word1" })
    }

    // MARK: Settings and corrections

    @Test func learnedEntriesRoundTripThroughSettings() throws {
        let json = #"{"vocabularyHints":["Niamh"],"learnedVocabularyHints":["Niamh","Removed","Niamh"],"transcriptCorrections":[{"from":"knee of","to":"Niamh","origin":"learned","models":["parakeet-tdt-0.6b-v3"," "]},{"from":"fair spoken","to":"Fairspoken"},{"from":"  ","to":"x"}]}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(settings.learnFromEdits)
        #expect(settings.learnedVocabularyHints == ["Niamh"])
        #expect(settings.transcriptCorrections.count == 2)
        #expect(settings.transcriptCorrections[0].origin == .learned)
        #expect(settings.transcriptCorrections[0].models == ["parakeet-tdt-0.6b-v3"])
        #expect(settings.transcriptCorrections[1].origin == .manual)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any]
        let corrections = encoded?["transcriptCorrections"] as? [[String: Any]]
        #expect(corrections?[0]["origin"] as? String == "learned")
        #expect(corrections?[0]["models"] as? [String] == ["parakeet-tdt-0.6b-v3"])
        // Unscoped corrections have no models key, as settings.rs writes them.
        #expect(corrections?[1]["models"] == nil)
        #expect(corrections?[1]["origin"] as? String == "manual")
        // Removing a term removes its marker.
        var removed = settings
        removed.vocabularyHints = []
        #expect(removed.normalized().learnedVocabularyHints.isEmpty)
        let off = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"learnFromEdits":false}"#.utf8))
        #expect(!off.learnFromEdits)
    }

    @Test func correctionsApplyInOrderWithinTheirScope() {
        let corrections = [
            TranscriptCorrection(from: "cloud code", to: "Claude Code", origin: .learned, models: [model]),
            TranscriptCorrection(from: "neve", to: "Niamh"),
        ]
        #expect(TranscriptCorrections.apply("ask Cloud Code and neve.", corrections: corrections, speechModel: model)
            == "ask Claude Code and Niamh.")
        // Another model may hear the phrase correctly: the scoped correction leaves it alone.
        #expect(TranscriptCorrections.apply("ask cloud code and neve", corrections: corrections, speechModel: "remote-host")
            == "ask cloud code and Niamh")
        // Whole phrases only.
        #expect(TranscriptCorrections.apply("Genevieve", corrections: corrections, speechModel: model) == "Genevieve")
        var disabled = corrections[1]
        disabled.enabled = false
        #expect(TranscriptCorrections.apply("neve", corrections: [disabled], speechModel: model) == "neve")
    }

    @Test func postProcessorAppliesCorrectionsAfterCasing() async {
        let context = PostProcessContext(appBundleID: nil, vocabulary: ["HbA1c"],
                                         corrections: [TranscriptCorrection(from: "neve", to: "Niamh")], speechModel: model)
        #expect(await BasicPostProcessor().process("  neve's hba1c ", context: context) == "Niamh's HbA1c")
    }

    @Test func speechModelIDFollowsTheLocation() {
        var settings = AppSettings()
        #expect(settings.speechModelID == settings.model)
        settings.transcriptionLocation = .remoteHost
        #expect(settings.speechModelID == "remote-host")
    }
}
