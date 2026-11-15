import Foundation
import Testing
@testable import FairspokenCore

@Suite("Model catalogue")
struct ModelCatalogueTests {
    @Test func idsAreUniqueAndTheDefaultExists() {
        let ids = SpeechModelCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(SpeechModelCatalog.model(id: SpeechModelCatalog.defaultModelID)?.engine == .parakeet)
    }

    @Test func everyRowIsComplete() {
        for m in SpeechModelCatalog.all {
            #expect((1...5).contains(m.accuracy), "\(m.id) accuracy")
            #expect((1...5).contains(m.speed), "\(m.id) speed")
            #expect(m.approxBytes > 0 && m.memoryBytes > 0, "\(m.id) sizes")
            #expect(!m.name.isEmpty && !m.summary.isEmpty && !m.details.isEmpty && !m.license.isEmpty, "\(m.id) text")
            #expect(m.kind == .speech && m.isLocal, "\(m.id) kind")
            #expect(m.sourceURL != nil, "\(m.id) source")
            if m.scoreSource == .measured || m.scoreSource == .published {
                #expect(m.wer != nil && m.rtfx != nil, "\(m.id) figures")
            }
        }
    }

    /// The bars come from the figures, so two models with the same numbers score the same.
    @Test func barsFollowTheFigures() {
        for m in SpeechModelCatalog.all {
            if let wer = m.wer { #expect(m.accuracy == ScoreScale.accuracy(wer: wer), "\(m.id)") }
            if let rtfx = m.rtfx { #expect(m.speed == ScoreScale.speed(rtfx: rtfx), "\(m.id)") }
        }
        #expect(ScoreScale.accuracy(wer: 2.0) == 5)
        #expect(ScoreScale.accuracy(wer: 2.8) == 4)
        #expect(ScoreScale.accuracy(wer: 30) == 1)
        #expect(ScoreScale.speed(rtfx: 129) == 5)
        #expect(ScoreScale.speed(rtfx: 40) == 4)
        #expect(ScoreScale.speed(rtfx: 1) == 1)
    }

    @Test func whisperRowsPointAtWhisperKitVariants() {
        let whisper = SpeechModelCatalog.all.filter { $0.engine == .whisper }
        #expect(whisper.count >= 10)
        for m in whisper {
            #expect(m.repository == "argmaxinc/whisperkit-coreml")
            #expect(m.variant?.isEmpty == false, "\(m.id) variant")
            // English-only Whisper models are the `.en` and distilled ones.
            #expect(m.englishOnly == (m.id.hasSuffix(".en") || m.id.hasPrefix("distil-")), "\(m.id)")
        }
        #expect(SpeechModelCatalog.model(id: "large-v3-turbo")?.variant == "openai_whisper-large-v3-v20240930_626MB")
    }

    @Test func unknownIdsResolveToTheDefault() {
        #expect(SpeechModelCatalog.resolve("nope").id == SpeechModelCatalog.defaultModelID)
        #expect(SpeechModelCatalog.resolve("small.en").id == "small.en")
    }
}

@Suite("Model library filtering and sorting")
struct ModelCatalogueQueryTests {
    let all = SpeechModelCatalog.all

    @Test func defaultQueryKeepsEverythingRecommendedFirst() {
        let rows = ModelCatalogueQuery().apply(to: all)
        #expect(rows.count == all.count)
        #expect(rows.first?.isRecommended == true)
        #expect(rows.prefix { $0.isRecommended }.count == all.filter(\.isRecommended).count)
    }

    @Test func searchMatchesEveryWordAnywhere() {
        let turbo = ModelCatalogueQuery(search: "whisper turbo").apply(to: all)
        #expect(turbo.first?.id == "large-v3-turbo")
        #expect(turbo.allSatisfy { "\($0.name) \($0.summary)".lowercased().contains("turbo") })
        #expect(ModelCatalogueQuery(search: "small.en").apply(to: all).map(\.id) == ["small.en"])
        #expect(ModelCatalogueQuery(search: "NVIDIA").apply(to: all).allSatisfy { $0.publisher == "NVIDIA" })
        #expect(ModelCatalogueQuery(search: "no such model").apply(to: all).isEmpty)
    }

    @Test func filtersCombine() {
        let english = ModelCatalogueQuery(engine: .whisper, language: .englishOnly).apply(to: all)
        #expect(!english.isEmpty)
        #expect(english.allSatisfy { $0.engine == .whisper && $0.englishOnly })
        let multi = ModelCatalogueQuery(language: .multilingual).apply(to: all)
        #expect(multi.allSatisfy { !$0.englishOnly })
        #expect(ModelCatalogueQuery(engine: .parakeet).apply(to: all).allSatisfy { $0.engine == .parakeet })
        #expect(ModelCatalogueQuery(localOnly: true).apply(to: all).count == all.count)
        #expect(ModelCatalogueQuery(engine: .whisper).isFiltered)
        #expect(!ModelCatalogueQuery(search: "x", sort: .size).isFiltered)
    }

    @Test func downloadedFilterUsesTheInstalledSet() {
        let rows = ModelCatalogueQuery(downloadedOnly: true).apply(to: all, installed: ["base", "parakeet-ultra"])
        #expect(Set(rows.map(\.id)) == ["base", "parakeet-ultra"])
        #expect(ModelCatalogueQuery(downloadedOnly: true).apply(to: all).isEmpty)
    }

    @Test func sortsBestFirst() {
        let bySize = ModelCatalogueQuery(sort: .size).apply(to: all)
        #expect(zip(bySize, bySize.dropFirst()).allSatisfy { $0.approxBytes <= $1.approxBytes })
        let bySpeed = ModelCatalogueQuery(sort: .speed).apply(to: all)
        #expect(zip(bySpeed, bySpeed.dropFirst()).allSatisfy { $0.speed >= $1.speed })
        let byAccuracy = ModelCatalogueQuery(sort: .accuracy).apply(to: all)
        #expect(zip(byAccuracy, byAccuracy.dropFirst()).allSatisfy { $0.accuracy >= $1.accuracy })
        let byName = ModelCatalogueQuery(sort: .name).apply(to: all).map(\.name)
        #expect(byName == byName.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    @Test func favouritesComeFirstInAnySort() {
        let rows = ModelCatalogueQuery(sort: .size).apply(to: all, favourites: ["large-v3", "medium"])
        #expect(Set(rows.prefix(2).map(\.id)) == ["large-v3", "medium"])
        // Favourites keep the chosen order among themselves (smaller first).
        #expect(rows.first?.id == "large-v3")
    }
}

@Suite("Model folder deletion")
struct ModelStorageTests {
    private func sandbox() throws -> (root: URL, models: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ms-\(UUID().uuidString)", isDirectory: true)
        let models = root.appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(at: models.appendingPathComponent("whisper/a", isDirectory: true), withIntermediateDirectories: true)
        return (root, models)
    }

    @Test func deletesOnlyInsideTheModelsFolder() throws {
        let (root, models) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = models.appendingPathComponent("whisper/a")
        #expect(try ModelStorage.removeItem(target, inside: models))
        #expect(!FileManager.default.fileExists(atPath: target.path))
        // Already gone counts as removed.
        #expect(try ModelStorage.removeItem(target, inside: models))
    }

    @Test func refusesTheRootItselfAndAnythingOutside() throws {
        let (root, models) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let sibling = root.appendingPathComponent("Models-other", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        for target in [models, models.appendingPathComponent("."), models.appendingPathComponent("whisper/../.."),
                       models.appendingPathComponent("../Models-other"), sibling, root,
                       URL(fileURLWithPath: "/"), URL(string: "https://example.org/Models/x")!] {
            #expect(ModelStorage.contained(target, in: models) == nil, "\(target)")
            #expect(try !ModelStorage.removeItem(target, inside: models), "\(target)")
        }
        #expect(FileManager.default.fileExists(atPath: sibling.path))
        #expect(FileManager.default.fileExists(atPath: models.path))
        #expect(ModelStorage.contained(URL(fileURLWithPath: "/"), in: URL(fileURLWithPath: "/")) == nil)
    }

    @Test func followsSymbolicLinksBeforeDeciding() throws {
        let (root, models) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("precious", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = models.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        // A link out of the folder, and a path through it, are refused; the target survives.
        #expect(try !ModelStorage.removeItem(link, inside: models))
        #expect(try !ModelStorage.removeItem(link.appendingPathComponent("child"), inside: models))
        #expect(FileManager.default.fileExists(atPath: outside.path))
        // A models folder reached through a link still works for what is really inside it.
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: models)
        #expect(ModelStorage.contained(alias.appendingPathComponent("whisper/a"), in: models) != nil)
        #expect(ModelStorage.contained(models.appendingPathComponent("whisper/a"), in: alias) != nil)
    }
}

@Suite("Choosing a model")
struct ModelActivationTests {
    @Test func anInstalledModelLoadsAtOnceBetweenDictations() {
        var a = ModelActivation()
        #expect(a.request("large-v3", installed: true, downloading: false, dictationActive: false) == .load("large-v3"))
        #expect(a == ModelActivation())
    }

    /// "Use" during a dictation waits for it to end; only the latest choice is loaded.
    @Test func aChoiceDuringDictationWaitsForItToEnd() {
        var a = ModelActivation()
        #expect(a.request("large-v3", installed: true, downloading: false, dictationActive: true) == .none)
        #expect(a.request("small.en", installed: true, downloading: false, dictationActive: true) == .none)
        #expect(a.waitingForDictation == "small.en")
        #expect(a.dictationEnded() == .load("small.en"))
        #expect(a.dictationEnded() == .none)
    }

    /// A model that isn't downloaded goes through the library's tracked download, then loads.
    @Test func aMissingModelDownloadsFirstThenLoads() {
        var a = ModelActivation()
        #expect(a.request("large-v3", installed: false, downloading: false, dictationActive: false) == .download("large-v3"))
        #expect(a.downloadFinished("other", success: true, dictationActive: false) == .none)
        #expect(a.downloadFinished("large-v3", success: true, dictationActive: false) == .load("large-v3"))
        // Already downloading: no second download.
        #expect(a.request("medium", installed: false, downloading: true, dictationActive: false) == .none)
        #expect(a.waitingForDownload == "medium")
    }

    @Test func aCancelledOrFailedDownloadActivatesNothing() {
        var a = ModelActivation()
        _ = a.request("large-v3", installed: false, downloading: false, dictationActive: false)
        #expect(a.downloadFinished("large-v3", success: false, dictationActive: false) == .none)
        #expect(a == ModelActivation())
    }

    @Test func aDownloadThatFinishesMidDictationWaitsToo() {
        var a = ModelActivation()
        _ = a.request("large-v3", installed: false, downloading: false, dictationActive: false)
        #expect(a.downloadFinished("large-v3", success: true, dictationActive: true) == .none)
        #expect(a.dictationEnded() == .load("large-v3"))
    }

    /// A dictation started before any model was ready waits for one, so the first model loads
    /// at once instead of waiting for that dictation to end.
    @Test func onlyALoadedModelMakesAChoiceWait() {
        #expect(ModelActivation.mustWait(dictating: true, engineReady: true))
        #expect(!ModelActivation.mustWait(dictating: true, engineReady: false))
        #expect(!ModelActivation.mustWait(dictating: false, engineReady: true))
        var a = ModelActivation()
        _ = a.request("large-v3", installed: false, downloading: false, dictationActive: false)
        let wait = ModelActivation.mustWait(dictating: true, engineReady: false)
        #expect(a.downloadFinished("large-v3", success: true, dictationActive: wait) == .load("large-v3"))
    }

    @Test func aNewerChoiceReplacesOneWaitingForItsDownload() {
        var a = ModelActivation()
        _ = a.request("large-v3", installed: false, downloading: false, dictationActive: false)
        #expect(a.request("parakeet-tdt-0.6b-v3", installed: true, downloading: false, dictationActive: false) == .load("parakeet-tdt-0.6b-v3"))
        #expect(a.downloadFinished("large-v3", success: true, dictationActive: false) == .none)
    }
}
