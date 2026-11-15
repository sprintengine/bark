import Foundation
import Testing
@testable import FairspokenCore

@Suite("Training data")
struct TrainingDataTests {
    private func temporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("training-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func entry(_ id: String, seconds: Double = 2) -> TrainingEntry {
        TrainingEntry(id: id, createdAt: 1_792_326_583, durationSeconds: seconds, speechModel: "parakeet-ultra",
                      appCategory: "code", rawText: "ask cloud code", finalText: "Ask cloud code.")
    }

    @Test func entryMatchesTheRustCaptureEntry() throws {
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry("a"))) as? [String: Any]
        #expect(Set(json?.keys.map { $0 } ?? []) ==
            ["id", "createdAt", "durationSeconds", "speechModel", "appCategory", "rawText", "finalText"])
        // A line the Tauri app wrote, with the optional fields present.
        let rust = #"{"id":"b","createdAt":1,"durationSeconds":4.2,"speechModel":"parakeet-tdt-0.6b-v3","appCategory":"email","rawText":"hi","polishedText":"Hi.","finalText":"Hi.","editedText":"Hello."}"#
        let decoded = try JSONDecoder().decode(TrainingEntry.self, from: Data(rust.utf8))
        #expect(decoded.editedText == "Hello.")
        #expect(decoded.polishedText == "Hi.")
    }

    @Test func attachesTheUsersEdit() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TrainingDataStore(root: root)
        try store.record(entry("one"), samples: [0, 0.1])
        // The same text as inserted is no edit.
        #expect(try store.attachEdit("one", edited: " Ask cloud code. ") == false)
        #expect(try store.attachEdit("one", edited: "Ask Claude Code. "))
        #expect(store.entries().first?.editedText == "Ask Claude Code.")
        let meta = try Data(contentsOf: root.appendingPathComponent("one/meta.json"))
        #expect(try JSONDecoder().decode(TrainingEntry.self, from: meta).editedText == "Ask Claude Code.")
        #expect(try store.attachEdit("gone", edited: "x") == false)
        #expect(try store.attachEdit("../one", edited: "x") == false)
    }

    @Test func recordsListsAndDeletes() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TrainingDataStore(root: root)
        let samples = [Float](repeating: 0.25, count: 32_000)
        try store.record(entry("one"), samples: samples)
        try store.record(entry("two", seconds: 3), samples: samples)
        #expect(store.entries().map(\.id) == ["one", "two"])
        #expect(FileManager.default.fileExists(atPath: store.audioURL(for: "one").path))
        let meta = try Data(contentsOf: root.appendingPathComponent("one/meta.json"))
        #expect(try JSONDecoder().decode(TrainingEntry.self, from: meta) == entry("one"))
        let mode = try FileManager.default.attributesOfItem(atPath: store.audioURL(for: "one").path)[.posixPermissions] as? Int
        #expect(mode == 0o600)

        try store.delete("one", removal: .permanent)
        #expect(store.entries().map(\.id) == ["two"])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("one").path))

        try "keep me".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try store.deleteAll(removal: .permanent)
        #expect(store.entries().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("two").path))
        // Only what the index names is removed.
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("notes.txt").path))
    }

    @Test func skipsDamagedIndexLines() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TrainingDataStore(root: root)
        try store.record(entry("one"), samples: [0.1])
        let index = root.appendingPathComponent(TrainingDataStore.indexFile)
        let handle = try FileHandle(forWritingTo: index)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{not json\n".utf8))
        try handle.close()
        try store.record(entry("two"), samples: [0.1])
        #expect(store.entries().map(\.id) == ["one", "two"])
    }

    private func append(_ line: String, to root: URL) throws {
        let handle = try FileHandle(forWritingTo: root.appendingPathComponent(TrainingDataStore.indexFile))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
        try handle.close()
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    @Test func idsAreCheckedBeforeTheyBecomePaths() throws {
        for id in ["one", "6f1c2d3e-0000-4000-8000-000000000000", "demo-0"] { #expect(TrainingDataStore.isSafeID(id)) }
        for id in ["", ".", "..", "../outside", "a/b", "/abs", "a\\b", "x..y", "C:"] { #expect(!TrainingDataStore.isSafeID(id)) }

        let parent = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try "keep".write(to: parent.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
        let store = TrainingDataStore(root: root)
        #expect(throws: (any Error).self) { try store.record(entry("../escape"), samples: [0.1]) }
        #expect(!exists(parent.appendingPathComponent("escape")))
        try store.record(entry("one"), samples: [0.1])
        for id in ["", "..", parent.path] {
            try append(String(decoding: JSONEncoder().encode(entry(id)), as: UTF8.self), to: root)
        }

        #expect(store.entries().map(\.id) == ["one"])
        try store.delete("..", removal: .permanent)
        try store.delete("", removal: .permanent)
        try store.deleteAll(removal: .permanent)
        #expect(exists(root))
        #expect(exists(parent.appendingPathComponent("keep.txt")))
        // The unsafe lines are kept, not acted on.
        let index = try String(contentsOf: root.appendingPathComponent(TrainingDataStore.indexFile), encoding: .utf8)
        #expect(index.split(separator: "\n").count == 3)
    }

    @Test func rewritesKeepUndecodableLinesByteForByte() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TrainingDataStore(root: root)
        try store.record(entry("one"), samples: [0.1])
        let damaged = "{not json"
        let newer = #"{"version":2,"something":"else"}"#
        try append(damaged, to: root)
        try append(newer, to: root)
        try store.record(entry("two"), samples: [0.1])

        try store.delete("one", removal: .permanent)
        let index = root.appendingPathComponent(TrainingDataStore.indexFile)
        let lines = try String(contentsOf: index, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(Array(lines.prefix(2)) == [damaged, newer])
        #expect(store.entries().map(\.id) == ["two"])

        try store.deleteAll(removal: .permanent)
        #expect(try String(contentsOf: index, encoding: .utf8) == damaged + "\n" + newer + "\n")
    }

    @Test func anIndexThatCannotBeReadIsNeverRewritten() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TrainingDataStore(root: root)
        try store.record(entry("one"), samples: [0.1])
        // Stand in for an unreadable index: a folder where the file should be.
        let index = root.appendingPathComponent(TrainingDataStore.indexFile)
        try FileManager.default.moveItem(at: index, to: root.appendingPathComponent("saved-index"))
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)

        #expect(throws: TrainingDataStore.StoreError.indexUnreadable(root.path)) { try store.delete("one", removal: .permanent) }
        #expect(throws: TrainingDataStore.StoreError.indexUnreadable(root.path)) { try store.deleteAll(removal: .permanent) }
        #expect(throws: TrainingDataStore.StoreError.indexUnreadable(root.path)) { try store.rebuildIndex() }
        #expect(exists(store.audioURL(for: "one")))
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: index.path, isDirectory: &isDirectory) && isDirectory.boolValue)
    }

    @Test func deleteAllRemovesOnlyTheEntriesTheIndexNames() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TrainingDataStore(root: root)
        try store.record(entry("one"), samples: [0.1])
        try store.record(entry("two"), samples: [0.1])
        let unlisted = root.appendingPathComponent("unlisted", isDirectory: true)
        try FileManager.default.createDirectory(at: unlisted, withIntermediateDirectories: false)
        try Data([1, 2, 3]).write(to: unlisted.appendingPathComponent(TrainingDataStore.audioFile))

        try store.deleteAll(removal: .permanent)

        #expect(store.entries().isEmpty)
        #expect(!exists(root.appendingPathComponent("one")) && !exists(root.appendingPathComponent("two")))
        #expect(!exists(root.appendingPathComponent(TrainingDataStore.indexFile)))
        #expect(exists(unlisted.appendingPathComponent(TrainingDataStore.audioFile)))
        #expect(exists(root))
    }

    @Test func rebuildsTheIndexFromEachMetaFile() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TrainingDataStore(root: root)
        var older = entry("older")
        older.createdAt -= 60
        try store.record(entry("newer"), samples: [0.1])
        try store.record(older, samples: [0.1])
        try store.record(entry("gone"), samples: [0.1])
        try FileManager.default.removeItem(at: root.appendingPathComponent("gone"))
        try append("{not json", to: root)
        // A folder without meta.json, and one whose meta.json names another id, are left out.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("no-meta"), withIntermediateDirectories: false)
        try FileManager.default.copyItem(at: root.appendingPathComponent("newer"), to: root.appendingPathComponent("copy"))

        #expect(try store.rebuildIndex() == 2)
        #expect(store.entries().map(\.id) == ["older", "newer"])
        let index = try String(contentsOf: root.appendingPathComponent(TrainingDataStore.indexFile), encoding: .utf8)
        #expect(index.hasSuffix("{not json\n"))
        let backups = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".bak") }
        #expect(backups.count == 1)
        let backup = try String(contentsOf: root.appendingPathComponent(backups[0]), encoding: .utf8)
        #expect(backup.contains(#""id":"gone""#))

        // With no index at all, say after the folders were put back from the Trash.
        try FileManager.default.removeItem(at: root.appendingPathComponent(TrainingDataStore.indexFile))
        #expect(try store.rebuildIndex() == 2)
        #expect(store.entries().map(\.id) == ["older", "newer"])
    }

    @Test func anAppendAfterALineWithoutItsNewlineStartsANewLine() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TrainingDataStore(root: root)
        try store.record(entry("one"), samples: [0.1])
        // As if a writer stopped before its newline.
        let index = root.appendingPathComponent(TrainingDataStore.indexFile)
        let data = try Data(contentsOf: index)
        try data.dropLast().write(to: index)

        try store.record(entry("two"), samples: [0.1])
        #expect(store.entries().map(\.id) == ["one", "two"])
    }

    @Test func theSharedLockHoldsOffRewritesButNeverDropsARecording() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TrainingDataStore(root: root)
        try store.record(entry("one"), samples: [0.1])
        // The desktop app holding the lock (flock, on the same file it uses).
        let held = try #require(TrainingDataStore(root: root).lockIndex())

        #expect(throws: TrainingDataStore.StoreError.busy(root.path)) { try store.delete("one", removal: .permanent) }
        #expect(throws: TrainingDataStore.StoreError.busy(root.path)) { try store.deleteAll(removal: .permanent) }
        #expect(throws: TrainingDataStore.StoreError.busy(root.path)) { try store.rebuildIndex() }
        #expect(exists(store.audioURL(for: "one")))

        // An append waits for the lock, however long, rather than going ahead.
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? store.record(entry("two"), samples: [0.1])
            finished.signal()
        }
        #expect(finished.wait(timeout: .now() + TrainingDataStore.lockWait + 0.5) == .timedOut)
        #expect(exists(store.audioURL(for: "two")))
        #expect(store.entries().map(\.id) == ["one"])

        close(held)
        #expect(finished.wait(timeout: .now() + 10) == .success)
        #expect(store.entries().map(\.id) == ["one", "two"])
        try store.delete("one", removal: .permanent)
        #expect(store.entries().map(\.id) == ["two"])
    }

    @Test func neverCreatesAMissingFolder() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("unmounted-\(UUID().uuidString)/Training")
        let store = TrainingDataStore(root: missing)
        #expect(!store.isAvailable)
        #expect(throws: TrainingDataStore.StoreError.folderUnavailable(missing.path)) {
            try store.record(entry("one"), samples: [0.1])
        }
        #expect(!FileManager.default.fileExists(atPath: missing.deletingLastPathComponent().path))
    }

    @Test func wavHeaderAndSamples() {
        let wav = TrainingDataStore.wav([0, 1, -1, 0.5])
        #expect(wav.count == 44 + 8)
        #expect(String(decoding: wav[0..<4], as: UTF8.self) == "RIFF")
        #expect(String(decoding: wav[8..<12], as: UTF8.self) == "WAVE")
        func u32(_ at: Int) -> UInt32 { wav[at..<at + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) } }
        func i16(_ at: Int) -> Int16 { Int16(bitPattern: UInt16(wav[at]) | UInt16(wav[at + 1]) << 8) }
        #expect(u32(4) == 36 + 8)
        #expect(u32(24) == 16_000)
        #expect(u32(40) == 8)
        #expect([i16(44), i16(46), i16(48), i16(50)] == [0, 32767, -32767, 16384])
    }

    @Test func summaryAndReadiness() {
        let summary = TrainingSummary([entry("a", seconds: 1800), entry("b", seconds: 1800)])
        #expect(summary.count == 2)
        #expect(summary.isEnoughToTrain)
        #expect(summary.bytes == 2 * (44 + 1800 * 32_000))
        #expect(abs(summary.progress - 0.1) < 0.0001)
        #expect(!TrainingSummary([entry("c", seconds: 60)]).isEnoughToTrain)
    }

    @Test func categoriesFollowTheRustTable() {
        #expect(AppCategory.of(bundleID: "com.tinyspeck.slackmacgap") == .messaging)
        #expect(AppCategory.of(bundleID: "com.jetbrains.rustrover") == .code)
        #expect(AppCategory.of(bundleID: "com.mitchellh.ghostty") == .terminal)
        #expect(AppCategory.of(bundleID: "com.google.Chrome") == .other)
        #expect(AppCategory.of(bundleID: nil) == .other)
    }

    @Test func settingsKeepTheCaptureChoiceAndFolder() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"trainingCapture":true,"trainingDataFolder":" /Volumes/External/x "}"#.utf8))
        #expect(s.trainingCapture)
        #expect(s.trainingDataFolder == "/Volumes/External/x")
        #expect(!AppSettings().trainingCapture)
    }
}
