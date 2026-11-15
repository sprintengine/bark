import FairspokenCore
import Foundation
import Testing
@testable import FairspokenWhisper

/// The Whisper store's layout and delete rule (no network), plus an opt-in real download into a
/// temporary folder that loads the model and transcribes a WAV:
///
///     FAIRSPOKEN_REAL_WHISPER=tiny.en FAIRSPOKEN_REAL_WHISPER_WAV=/path/to/clip.wav swift test --filter Whisper
///
/// Every check here uses its own temporary store; the app's models folder is never touched.
@Suite("Whisper model store", .serialized)
struct WhisperStoreTests {
    static let environment = ProcessInfo.processInfo.environment

    private func withStore(_ body: (URL) async throws -> Void) async throws {
        let previous = WhisperModels.root
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-store-\(UUID().uuidString)", isDirectory: true)
        WhisperModels.setRoot(root)
        defer {
            WhisperModels.setRoot(previous)
            try? FileManager.default.removeItem(at: root)
        }
        try await body(root)
    }

    @Test func everyWhisperRowHasATokenizerAndAFolderInTheStore() async throws {
        try await withStore { root in
            for m in SpeechModelCatalog.all where m.engine == .whisper {
                #expect(WhisperModels.tokenizerRepo(m.id) != nil, "\(m.id)")
                let dir = try #require(WhisperModels.directory(for: m.id))
                #expect(ModelStorage.contained(dir, in: root) != nil, "\(m.id)")
                #expect(dir.lastPathComponent == m.variant)
                #expect(!WhisperModels.isInstalled(m.id))
            }
            #expect(WhisperModels.directory(for: "parakeet-tdt-0.6b-v3") == nil)
            #expect(SpeechModels.engine(of: "large-v3") == .whisper)
            #expect(SpeechModels.supportsLinks("parakeet-ultra") && !SpeechModels.supportsLinks("large-v3"))
        }
    }

    /// Installed needs the marker, the three Core ML bundles and the tokenizer; delete removes
    /// only that model's folder and keeps the shared tokenizer.
    @Test func installStateAndDelete() async throws {
        try await withStore { _ in
            let fm = FileManager.default
            let dir = try #require(WhisperModels.directory(for: "base.en"))
            let tokenizer = try #require(WhisperModels.tokenizerDirectory(for: "base.en"))
            for bundle in WhisperModels.bundles {
                try fm.createDirectory(at: dir.appendingPathComponent("\(bundle).mlmodelc"), withIntermediateDirectories: true)
            }
            try fm.createDirectory(at: tokenizer, withIntermediateDirectories: true)
            fm.createFile(atPath: tokenizer.appendingPathComponent("tokenizer.json").path, contents: Data("{}".utf8))
            #expect(!WhisperModels.isInstalled("base.en"))  // no marker: an interrupted download
            fm.createFile(atPath: dir.appendingPathComponent(WhisperModels.marker).path, contents: Data())
            #expect(WhisperModels.isInstalled("base.en"))
            #expect(!WhisperModels.isInstalled("base"))
            try WhisperModels.delete("base.en")
            #expect(!fm.fileExists(atPath: dir.path))
            #expect(fm.fileExists(atPath: tokenizer.appendingPathComponent("tokenizer.json").path))
            #expect(throws: (any Error).self) { try WhisperModels.delete("parakeet-tdt-0.6b-v3") }
        }
    }

    @Test(.enabled(if: environment["FAIRSPOKEN_REAL_WHISPER"] != nil, "Set FAIRSPOKEN_REAL_WHISPER to a Whisper model id"))
    func downloadsLoadsAndTranscribes() async throws {
        let id = try #require(Self.environment["FAIRSPOKEN_REAL_WHISPER"])
        try await withStore { _ in
            try await WhisperModels.download(id) { _ in }
            #expect(WhisperModels.isInstalled(id))
            let engine = LocalSpeechRouter()
            try await engine.load(id) { _ in }
            #expect(await engine.loadedModelID == id)
            if let wav = Self.environment["FAIRSPOKEN_REAL_WHISPER_WAV"] {
                let samples = try Self.read16kMonoWAV(URL(fileURLWithPath: wav))
                let out = try await engine.transcribe(samples, options: .init(language: "en"))
                print("\(id): \(out.text) (\(out.modelMs) ms)")
                #expect(!out.text.isEmpty)
            }
            await engine.unload()
            try WhisperModels.delete(id)
            #expect(!WhisperModels.isInstalled(id))
        }
    }

    /// 16-bit PCM WAV at 16 kHz mono (the LibriSpeech clips), without AVFoundation.
    static func read16kMonoWAV(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        guard let range = data.range(of: Data("data".utf8)) else { return [] }
        let start = range.upperBound + 4
        return stride(from: start, to: data.count - 1, by: 2).map { i in
            Float(Int16(littleEndian: data.subdata(in: i..<i + 2).withUnsafeBytes { $0.loadUnaligned(as: Int16.self) })) / 32768
        }
    }
}
