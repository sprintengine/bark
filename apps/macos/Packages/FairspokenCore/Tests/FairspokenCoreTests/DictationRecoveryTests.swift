import Foundation
import Synchronization
import Testing
@testable import FairspokenCore

/// Answers uploads in order from a script (the last answer repeats), recording each request
/// and whether the recording was still on disk when it was sent.
final class ScriptedTransport: HTTPTransport {
    enum Answer: Sendable {
        case json(Int, String)
        case drop
    }

    private let script: [Answer]
    private let audio: URL?
    private let state = Mutex<(requests: [URLRequest], audioOnDisk: [Bool])>(([], []))

    init(_ script: [Answer], audio: URL? = nil) {
        self.script = script
        self.audio = audio
    }

    var requests: [URLRequest] { state.withLock { $0.requests } }
    var audioOnDiskAtEachRequest: [Bool] { state.withLock { $0.audioOnDisk } }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let n = state.withLock {
            $0.requests.append(request)
            $0.audioOnDisk.append(audio.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
            return $0.requests.count
        }
        switch script[min(n, script.count) - 1] {
        case .json(let status, let body):
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
        case .drop:
            throw URLError(.networkConnectionLost)
        }
    }
}

/// Holds an async call until it is opened, ignoring cancellation.
final class Gate: Sendable {
    private let state = Mutex<(open: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func wait() async {
        await withCheckedContinuation { continuation in
            let now = state.withLock { state -> Bool in
                if state.open { return true }
                state.waiters.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { state in
            state.open = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

/// Collects what reached `deliver`.
final class Delivered: Sendable {
    private let texts = Mutex<[String]>([])
    var all: [String] { texts.withLock { $0 } }
    func add(_ output: TranscriptionOutput) { texts.withLock { $0.append(output.text) } }
}

/// Stands in for the Trash: moves files into a temporary folder (or refuses, like a volume
/// without a Trash), recording what it was given.
final class TrashBin: Sendable {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("trash-\(UUID().uuidString)", isDirectory: true)
    private let state = Mutex<(refuses: Bool, received: [String])>((false, []))

    var refuses: Bool {
        get { state.withLock { $0.refuses } }
        set { state.withLock { $0.refuses = newValue } }
    }
    var received: [String] { state.withLock { $0.received } }

    func move(_ url: URL) throws {
        if refuses { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: folder.appendingPathComponent(url.lastPathComponent))
        state.withLock { $0.received.append(url.lastPathComponent) }
    }
}

@Suite("Dictations are never lost")
struct DictationRecoveryTests {
    static let ok = #"{"text":"Patient reports chest tightness.","durationSeconds":3.0,"backend":"parakeet","model":"parakeet-tdt-0.6b-v3"}"#
    static let silent = #"{"text":"  ","durationSeconds":3.0,"backend":"parakeet","model":"parakeet-tdt-0.6b-v3"}"#
    static let shortTail = #"{"error":"Invalid audio data provided. Must be at least 300ms of 16kHz audio."}"#

    let store: PendingDictationStore
    let recovery: DictationRecovery
    let trash = TrashBin()

    init() {
        store = PendingDictationStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-\(UUID().uuidString)", isDirectory: true), moveToTrash: { [trash] in try trash.move($0) })
        recovery = DictationRecovery(store: store, sleep: { _ in })
    }

    /// Three seconds of a sweep, written the way capture writes it: 100 ms chunks as they come.
    func record(_ id: String = "dictation-1", seconds: Double = 3) throws -> [Float] {
        let samples = (0..<Int(seconds * 16_000)).map { Float(sin(Double($0) * 0.05)) * 0.5 }
        let writer = try store.begin(PendingDictation(id: id, createdAt: Date(), appName: "Mail", appBundleId: "com.apple.mail"))
        for start in stride(from: 0, to: samples.count, by: 1_600) {
            writer.append(Array(samples[start..<min(start + 1_600, samples.count)]))
        }
        try writer.finish()
        store.update(id) { $0.durationSeconds = seconds }
        return samples
    }

    func client(_ transport: ScriptedTransport) -> TranscriptionRoutes {
        let client = RemoteBatchClient(baseURL: URL(string: "http://127.0.0.1:48173")!,
                                       options: .init(token: "secret", model: "parakeet-tdt-0.6b-v3", language: "en", vocabularyHints: []),
                                       transport: transport)
        return TranscriptionRoutes(remote: { wav, timeout in try await client.transcribe(wav: wav, timeout: timeout) })
    }

    func uploadedSamples(_ request: URLRequest) throws -> [Int16] {
        try WAVFile.decode(try #require(request.httpBody)).samples
    }

    @Test func hostFailureKeepsTheAudioAndResendsItThenDeletesItOnceDelivered() async throws {
        let samples = try record()
        let transport = ScriptedTransport([.json(503, #"{"error":"Transcription worker queue is unavailable"}"#), .json(200, Self.ok)],
                                          audio: store.audioURL("dictation-1"))
        let delivered = Delivered()
        let outcome = await recovery.run("dictation-1", live: {
            throw RemoteTranscriptionError.http(status: 500, message: RemoteProtocol.errorMessage(statusCode: 500, body: Data(Self.shortTail.utf8)))
        }, routes: client(transport), policy: .live(timeoutSeconds: 60), deliver: { delivered.add($0); return true })

        guard case .delivered(let output) = outcome else { Issue.record("expected delivery, got \(outcome)"); return }
        #expect(output.text == "Patient reports chest tightness.")
        #expect(delivered.all == ["Patient reports chest tightness."])
        // Re-sent twice (503, then 200), each time the whole recording, read back from disk.
        #expect(transport.requests.count == 2)
        #expect(transport.audioOnDiskAtEachRequest == [true, true])
        #expect(try uploadedSamples(transport.requests[1]) == PCM.int16(from: samples))
        // Delivered, so nothing is kept.
        #expect(!FileManager.default.fileExists(atPath: store.audioURL("dictation-1").path))
        #expect(store.all().isEmpty)
    }

    @Test func aStreamThatDropsMidwayIsResentInFull() async throws {
        let samples = try record(seconds: 30)
        let transport = ScriptedTransport([.json(200, Self.ok)])
        // The live stream had sent about half the audio when the connection went.
        let streamed = Mutex(0)
        let outcome = await recovery.run("dictation-1", live: {
            streamed.withLock { $0 = samples.count / 2 }
            throw RemoteTranscriptionError.unreachable("The network connection was lost.")
        }, routes: client(transport), policy: .live(timeoutSeconds: 60), deliver: { _ in true })

        #expect(outcome == .delivered(TranscriptionOutput(text: "Patient reports chest tightness.", modelMs: 0, model: "parakeet-tdt-0.6b-v3",
                                                          backend: "parakeet", placement: .remoteHost)).withAnyTiming(outcome))
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "http://127.0.0.1:48173/v1/transcriptions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "audio/wav")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(request.value(forHTTPHeaderField: "x-fairspoken-client") == "fairspoken-macos")
        // All 30 s, not the half the stream never delivered.
        let sent = try uploadedSamples(request)
        #expect(sent.count == samples.count && sent.count > streamed.withLock { $0 })
        #expect(sent == PCM.int16(from: samples))
    }

    @Test func whenEveryAttemptFailsTheDictationIsKeptAndSurvivesARestart() async throws {
        let samples = try record()
        let transport = ScriptedTransport([.drop])
        let outcome = await recovery.run("dictation-1", live: { throw RemoteTranscriptionError.timedOut(60) },
                                         routes: client(transport), policy: .live(timeoutSeconds: 60), deliver: { _ in
            Issue.record("nothing should be delivered")
            return true
        })
        guard case .kept(let kept) = outcome else { Issue.record("expected the dictation to be kept, got \(outcome)"); return }
        #expect(kept.state == .failed)
        #expect(kept.attempts == 3) // the stream, then both re-sends
        #expect(kept.lastError == "Remote transcription host did not respond within 60s of the recording ending")
        #expect(transport.requests.count == 2)

        // A new launch: a fresh store on the same folder finds it, audio intact.
        let relaunched = PendingDictationStore(directory: store.directory)
        let found = relaunched.recoverInterrupted()
        #expect(found.map(\.id) == ["dictation-1"])
        #expect(found.first?.appName == "Mail")
        #expect(found.first?.durationSeconds == 3)
        #expect(try relaunched.samples("dictation-1").count == samples.count)
        #expect(DictationRetryPolicy.isDue(try #require(found.first), now: Date().addingTimeInterval(121)))
        #expect(!DictationRetryPolicy.isDue(try #require(found.first), now: Date()))

        // The host is back: the later retry delivers it and only then deletes the audio.
        let back = ScriptedTransport([.json(200, Self.ok)], audio: relaunched.audioURL("dictation-1"))
        let delivered = Delivered()
        let later = await DictationRecovery(store: relaunched, sleep: { _ in })
            .run("dictation-1", live: nil, routes: client(back), policy: .later(timeoutSeconds: 60), deliver: { delivered.add($0); return true })
        guard case .delivered = later else { Issue.record("expected delivery, got \(later)"); return }
        #expect(back.audioOnDiskAtEachRequest == [true])
        #expect(delivered.all.count == 1)
        #expect(relaunched.all().isEmpty)
    }

    @Test func fallsBackToThisMacWhenTheHostStaysDown() async throws {
        let samples = try record()
        let transport = ScriptedTransport([.drop])
        var routes = client(transport)
        let heard = Mutex(0)
        routes.local = { input in
            heard.withLock { $0 = input.count }
            return TranscriptionOutput(text: "Transcribed here.", modelMs: 40, model: "parakeet-ultra", placement: .neuralEngine)
        }
        let progress = Mutex<[DictationRecovery.Progress]>([])
        let outcome = await recovery.run("dictation-1", live: { throw RemoteTranscriptionError.unreachable("Could not connect to the server.") },
                                         routes: routes, policy: .live(timeoutSeconds: 60),
                                         progress: { p in progress.withLock { $0.append(p) } }, deliver: { _ in true })
        guard case .delivered(let output) = outcome else { Issue.record("expected delivery, got \(outcome)"); return }
        #expect(output.placement == .neuralEngine)
        #expect(heard.withLock { $0 } == samples.count)
        #expect(progress.withLock { $0 } == [.retrying(attempt: 1, of: 2), .retrying(attempt: 2, of: 2), .transcribingOnThisMac])
        #expect(store.all().isEmpty)
    }

    @Test func aRefusalIsNotResentButStillFallsBack() async throws {
        _ = try record()
        let transport = ScriptedTransport([.json(200, Self.ok)])
        var routes = client(transport)
        routes.local = { _ in TranscriptionOutput(text: "Here.", modelMs: 1, model: "m", placement: .neuralEngine) }
        let outcome = await recovery.run("dictation-1", live: {
            throw RemoteTranscriptionError.http(status: 401, message: "Remote transcription host returned an error: 401 Unauthorized")
        }, routes: routes, policy: .live(timeoutSeconds: 60), deliver: { _ in true })
        #expect(transport.requests.isEmpty)
        guard case .delivered(let output) = outcome else { Issue.record("expected delivery, got \(outcome)"); return }
        #expect(output.text == "Here.")
    }

    @Test func noSpeechIsAnAnswerNotAFailure() async throws {
        _ = try record()
        let transport = ScriptedTransport([.json(200, Self.ok)])
        let outcome = await recovery.run("dictation-1", live: { throw RemoteTranscriptionError.noSpeech },
                                         routes: client(transport), policy: .live(timeoutSeconds: 60), deliver: { _ in true })
        #expect(outcome == .noSpeech)
        #expect(transport.requests.isEmpty)
        #expect(store.all().isEmpty)
    }

    @Test func aKeptDictationThatTurnsOutSilentGoesToTheTrashNotAway() async throws {
        _ = try record()
        let transport = ScriptedTransport([.json(200, Self.silent)])
        let outcome = await recovery.run("dictation-1", live: nil, routes: client(transport), policy: .later(timeoutSeconds: 60),
                                         deliver: { _ in Issue.record("nothing to deliver"); return true })
        #expect(outcome == .noSpeech)
        // Kept because something failed, so an empty answer later isn't trusted with the audio.
        #expect(trash.received == ["dictation-1.wav"])
        #expect(FileManager.default.fileExists(atPath: trash.folder.appendingPathComponent("dictation-1.wav").path))
        #expect(store.all().isEmpty)
    }

    @Test func noSpeechAfterAFailedAttemptGoesToTheTrashNotAway() async throws {
        _ = try record()
        let transport = ScriptedTransport([.json(200, Self.silent)])
        let outcome = await recovery.run("dictation-1", live: { throw RemoteTranscriptionError.timedOut(60) },
                                         routes: client(transport), policy: .live(timeoutSeconds: 60), deliver: { _ in true })
        #expect(outcome == .noSpeech)
        #expect(trash.received == ["dictation-1.wav"])
    }

    @Test func aTranscriptThatPostProcessingEmptiesIsNotTakenAsDelivered() async throws {
        _ = try record()
        let transport = ScriptedTransport([.json(200, Self.ok)])
        let outcome = await recovery.run("dictation-1", live: nil, routes: client(transport), policy: .later(timeoutSeconds: 60),
                                         deliver: { _ in false })
        #expect(outcome == .noSpeech)
        #expect(trash.received == ["dictation-1.wav"])
    }

    @Test func aKeptDictationStaysWhenTheTrashCantTakeIt() async throws {
        _ = try record()
        trash.refuses = true
        var routes = client(ScriptedTransport([.json(200, Self.silent)]))
        routes.local = { _ in
            Issue.record("a silent answer is not a failure to fall back from")
            return TranscriptionOutput(text: "x", modelMs: 0, model: "m", placement: .neuralEngine)
        }
        let outcome = await recovery.run("dictation-1", live: nil, routes: routes, policy: .later(timeoutSeconds: 60), deliver: { _ in true })
        guard case .kept(let kept) = outcome else { Issue.record("expected the dictation to be kept, got \(outcome)"); return }
        #expect(kept.lastError == "No speech was heard, and the recording couldn't be moved to the Trash")
        #expect(FileManager.default.fileExists(atPath: store.audioURL("dictation-1").path))
    }

    @Test func deletingMovesToTheTrashAndNothingIsLostWhenItCant() throws {
        _ = try record()
        trash.refuses = true
        #expect(throws: CocoaError.self) { try store.trash("dictation-1") }
        #expect(store.all().map(\.id) == ["dictation-1"])
        trash.refuses = false
        try store.trash("dictation-1")
        #expect(trash.received == ["dictation-1.wav"])
        #expect(store.all().isEmpty)
        #expect(store.item("dictation-1") == nil)
    }

    @Test func aDeliveredRecordingMovesToThePostTrainingFolderInsteadOfBeingWrittenTwice() throws {
        let samples = try record()
        let before = try store.wav("dictation-1")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("training-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let training = TrainingDataStore(root: root)

        let file = try #require(store.handOff("dictation-1"))
        // Out of the pending list at once, so the delivery that follows can't delete it.
        #expect(store.all().isEmpty)
        let entry = TrainingEntry(createdAt: 1, durationSeconds: 3, speechModel: "parakeet-ultra", appCategory: "email",
                                  rawText: "Patient reports chest tightness.", finalText: "Patient reports chest tightness.")
        try training.record(entry, movingAudioFrom: file)
        store.remove("dictation-1")

        #expect(!FileManager.default.fileExists(atPath: file.path))
        let kept = try Data(contentsOf: training.audioURL(for: entry.id))
        #expect(kept == before)
        #expect(try WAVFile.decode(kept).samples == PCM.int16(from: samples))
        #expect(training.entries().map(\.id) == [entry.id])
        // The same 16 kHz mono 16-bit layout post-training writes itself.
        #expect(kept == TrainingDataStore.wav(samples))
    }

    @Test func anInterruptedHandOffIsClearedAtLaunchAndNeverTakenForADictation() throws {
        _ = try record()
        _ = try #require(store.handOff("dictation-1"))
        #expect(store.recoverInterrupted().isEmpty)
        store.clearHandOffs()
        #expect(!FileManager.default.fileExists(atPath: store.directory.appendingPathComponent(".handoff").path))
    }

    @Test func aFailedFallbackSaysWhatBothAnswered() async throws {
        _ = try record()
        var routes = client(ScriptedTransport([.json(500, Self.shortTail)]))
        routes.local = { _ in throw NSError(domain: "engine", code: 2, userInfo: [NSLocalizedDescriptionKey: "The speech model is still loading"]) }
        let outcome = await recovery.run("dictation-1", live: nil, routes: routes, policy: .later(timeoutSeconds: 60), deliver: { _ in true })
        guard case .kept(let kept) = outcome else { Issue.record("expected the dictation to be kept, got \(outcome)"); return }
        #expect(kept.attempts == 2)
        #expect(kept.lastError == "Remote transcription host returned an error (500 Internal Server Error): "
            + "Invalid audio data provided. Must be at least 300ms of 16kHz audio. · On this Mac: The speech model is still loading")
    }

    @Test func aRecordingCutShortByAQuitIsRecoveredAtLaunch() throws {
        let samples = (0..<8_000).map { Float($0 % 100) / 200 }
        let writer = try store.begin(PendingDictation(id: "dictation-2", createdAt: Date()))
        writer.append(Array(samples[..<4_000]))
        writer.append(Array(samples[4_000...]))
        // The app dies here, after the writes but before `finish`: the header still says 0 bytes.
        writer.drain()

        let found = PendingDictationStore(directory: store.directory).recoverInterrupted()
        #expect(found.map(\.id) == ["dictation-2"])
        #expect(found.first?.state == .failed)
        #expect(found.first?.lastError == "Bark quit before this dictation was transcribed")
        #expect(found.first?.durationSeconds == 0.5)
        #expect(try store.samples("dictation-2").count == 8_000)
        // The repaired header is a normal WAV now.
        let data = try store.wav("dictation-2")
        #expect(data[40..<44].elementsEqual(WAVFile.le32(16_000)))
    }

    /// Escape while transcribing, or the deadline: the run is cancelled while its live attempt
    /// is still out. The transcript that lands afterwards is never delivered, nothing else is
    /// tried, and the recording stays on disk to retry.
    @Test func aCancelledRunKeepsTheRecordingAndDropsTheLateTranscript() async throws {
        _ = try record()
        let gate = Gate()
        let delivered = Delivered()
        let triedHere = Mutex(false)
        let routes = TranscriptionRoutes(local: { _ in
            triedHere.withLock { $0 = true }
            return TranscriptionOutput(text: "Here.", modelMs: 1, model: "m", placement: .neuralEngine)
        })
        let recovery = self.recovery
        let run = Task {
            await recovery.run("dictation-1", live: {
                // Like an engine call that doesn't stop when cancelled.
                await gate.wait()
                return TranscriptionOutput(text: "Too late.", modelMs: 1, model: "m", placement: .neuralEngine)
            }, routes: routes, policy: .live(timeoutSeconds: 60), deliver: { delivered.add($0); return true })
        }
        run.cancel()
        gate.open()
        let outcome = await run.value
        guard case .kept(let kept) = outcome else { Issue.record("expected the recording kept, got \(outcome)"); return }
        #expect(kept.state == .failed)
        #expect(kept.lastError?.contains("Stopped before it was transcribed") == true)
        #expect(delivered.all.isEmpty)
        #expect(!triedHere.withLock { $0 })
        #expect(FileManager.default.fileExists(atPath: store.audioURL("dictation-1").path))
    }

    /// The controller refuses a transcript for a dictation that was cancelled while it was
    /// being tidied: that is not "no speech", and the recording is not deleted.
    @Test func aDeliveryRefusedBecauseOfCancellingIsNotNoSpeech() async throws {
        _ = try record()
        let recovery = self.recovery
        let outcome = await Task {
            await recovery.run("dictation-1", live: {
                TranscriptionOutput(text: "Words.", modelMs: 1, model: "m", placement: .neuralEngine)
            }, routes: TranscriptionRoutes(), policy: .live(timeoutSeconds: 60), deliver: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return false
            })
        }.value
        guard case .kept = outcome else { Issue.record("expected the recording kept, got \(outcome)"); return }
        #expect(FileManager.default.fileExists(atPath: store.audioURL("dictation-1").path))
        #expect(trash.received.isEmpty)
    }

    @Test func retryableErrors() {
        #expect(RemoteTranscriptionError.http(status: 500, message: "").isRetryable)
        #expect(RemoteTranscriptionError.http(status: 503, message: "").isRetryable)
        #expect(RemoteTranscriptionError.http(status: 429, message: "").isRetryable)
        #expect(!RemoteTranscriptionError.http(status: 401, message: "").isRetryable)
        #expect(!RemoteTranscriptionError.http(status: 413, message: "").isRetryable)
        #expect(RemoteTranscriptionError.unreachable("").isRetryable)
        #expect(RemoteTranscriptionError.timedOut(60).isRetryable)
        #expect(!RemoteTranscriptionError.noSpeech.isRetryable)
        #expect(DictationRetryPolicy.isRetryable(URLError(.cannotConnectToHost)))
        #expect(!DictationRetryPolicy.isRetryable(RemoteURLPolicy.ValidationError.requiresHTTPS))
        #expect(DictationRetryPolicy.backoff(afterAttempts: 1) == .seconds(30))
        #expect(DictationRetryPolicy.backoff(afterAttempts: 3) == .seconds(120))
        #expect(DictationRetryPolicy.backoff(afterAttempts: 40) == .seconds(1800))
    }

    @Test func wavRoundTrips() throws {
        let samples: [Int16] = [0, 1, -1, .max, .min, 1234]
        let data = WAVFile.encode(samples, sampleRate: 16_000)
        #expect(data.count == 44 + 12)
        let decoded = try WAVFile.decode(data)
        #expect(decoded.samples == samples && decoded.sampleRate == 16_000)
        #expect(throws: WAVFile.DecodeError.notWAV) { try WAVFile.decode(Data("nope".utf8)) }
    }
}

private extension DictationOutcome {
    /// Equal to `actual` when both are deliveries of the same text (timings differ run to run).
    func withAnyTiming(_ actual: DictationOutcome) -> DictationOutcome {
        guard case .delivered(var expected) = self, case .delivered(let got) = actual else { return self }
        expected.modelMs = got.modelMs
        return .delivered(expected)
    }
}
