import FairspokenSpeech
import FairspokenWhisper
import AVFoundation
import AppKit
import Foundation
import FairspokenCore

/// Headless end-to-end check of the real pipeline without the microphone or TCC:
///
///   Contents/MacOS/Fairspoken --selftest <file.wav> [--model parakeet-ultra | large-v3-turbo | …] [--host URL --token T]
///
/// 1. Loads the model on the Neural Engine (timing), transcribes the file through the same
///    `LocalBatchSession` + post-processor the hotkey path uses.
/// 2. With `--host`: streams the file through `RemoteStreamSession` (framed PCM16, chunked,
///    paced at 4× real time) while subscribed to `/v1/events`, and reports both.
///
///   Contents/MacOS/Fairspoken --discover [name | name:port [--password P]]
///
/// Scans the tailnet the way Settings › Find my host does (or probes one typed entry) and
/// prints what answered; with `--password`, pairs with the typed host (nothing is saved).
///
///   Contents/MacOS/Fairspoken --pipeline-demo        (Debug builds only)
///
/// Runs sample transcripts through post-processing (cleanup, corrections, each style's layout)
/// as a dictation into Mail, Slack, Notes and so on would, and prints plain text, HTML and edits.
@MainActor
enum SelfTest {
    static func runIfRequested() -> Bool {
        let args = AppInfo.arguments
        #if DEBUG
        if args.contains("--pipeline-demo") {
            pipelineDemo()
            exit(0)
        }
        #endif
        if let i = args.firstIndex(of: "--discover") {
            let entry = i + 1 < args.count && !args[i + 1].hasPrefix("-") ? args[i + 1] : nil
            let password = args.firstIndex(of: "--password").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
            Task {
                await discover(entry: entry, password: password)
                exit(0)
            }
            return true
        }
        if let i = args.firstIndex(of: "--ax-probe") {
            let delay = i + 1 < args.count ? Int(args[i + 1]) ?? 5 : 5
            Task {
                await axProbe(after: delay)
                exit(0)
            }
            return true
        }
        guard let i = args.firstIndex(of: "--selftest"), i + 1 < args.count else { return false }
        let file = URL(fileURLWithPath: args[i + 1])
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        Task {
            await run(file: file, model: value("--model") ?? SpeechModelCatalog.defaultModelID,
                      host: value("--host"), token: value("--token") ?? "")
            exit(0)
        }
        return true
    }

    private static func say(_ s: String) { FileHandle.standardOutput.write(Data((s + "\n").utf8)) }

    #if DEBUG
    /// Sample dictations through the real pipeline, for each style, with the rules a fresh
    /// install has. Nothing is pasted, saved or sent anywhere.
    private static func pipelineDemo() {
        let rules = StyleRules()
        let samples: [(DictationDestination, String)] = [
            (.init(bundleID: "com.apple.mail", appName: "Mail", windowTitle: "Re: Thursday's clinic"),
             "Hi Aoife, um, thanks for sending these on. I've looked at the audit results and we can go through them on Thursday, no wait, Friday at 2 pm. Kind regards, Pádraig."),
            (.init(bundleID: "com.google.Chrome", appName: "Chrome", url: "https://mail.google.com/mail/u/0/?compose=new#inbox"),
             "Dear Mr Byrne, thank you for your letter. New paragraph. Your appointment is confirmed for the 4th at 3 pm, sorry, 4 pm. Many thanks."),
            (.init(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack"),
             "So I was thinking we could, we could move standup to, uh, 10 tomorrow."),
            (.init(bundleID: "com.apple.Notes", appName: "Notes"),
             "Heading: shopping list. Bullet point milk bullet point eggs, bullet point the, the brown bread and"),
            (.init(bundleID: "com.microsoft.Word", appName: "Word"),
             "First, we need to update the consent form. Second, the audit is due on the 12th. Third, the new nurse starts Monday."),
            (.init(bundleID: "com.example.unknown", appName: "Another app"),
             "We need a feature where you can fix a sentence if the user says, where you can fix a sentence if the user says the wrong thing."),
            (.init(bundleID: "com.apple.dt.Xcode", appName: "Xcode"),
             "um the getUserName function should, should return nil when the cache is empty"),
            (.init(bundleID: "com.apple.Terminal", appName: "Terminal"),
             "um git commit dash m fix the build new line"),
            (.init(bundleID: "com.apple.Safari", appName: "Safari", url: "https://example.com/search", isSingleLineField: true),
             "Clinics in Cork, um, open on Saturday new line"),
        ]
        var settings = AppSettings()
        settings.vocabularyHints = ["getUserName"]
        for (destination, raw) in samples {
            let resolution = rules.resolve(destination)
            let start = ContinuousClock.now
            let r = DictationPipeline.process(raw, context: PostProcessContext(settings: settings, appBundleID: destination.bundleID, resolution: resolution))
            let us = (ContinuousClock.now - start) / .microseconds(1)
            say("== \(destination.appName ?? "?")\(destination.host.map { " (\($0))" } ?? ""): \(resolution.style.rawValue), \(resolution.reason), \(Int(us)) µs")
            say("heard: \(raw)")
            say("plain:\n\(r.plainText)")
            if let html = r.html { say("html:  \(html)") }
            say("edits: " + r.edits.map { "\($0.kind.rawValue) \"\($0.removed)\" → \"\($0.inserted.replacingOccurrences(of: "\n", with: "⏎"))\"" }.joined(separator: "; "))
            say("")
        }
    }
    #endif

    private static func discover(entry: String?, password: String?) async {
        let discovery = TailnetDiscovery()
        say("tailscale: \(discovery.locateCLI() ?? "not found")")
        let t = ContinuousClock.now
        do {
            if let entry {
                let host = try await discovery.probe(entry: entry)
                say(String(describing: host))
                if let password {
                    let response = try await HostPairingClient().pair(url: host.url, password: password, clientName: HostFinder.computerName)
                    say("paired: name=\(response.name ?? "?") token=\(response.token.map { "\($0.prefix(4))… (\($0.count) chars)" } ?? "none")")
                }
            } else {
                let status = try await discovery.status()
                let candidates = TailnetDiscovery.candidates(from: status)
                say("probing \(candidates.count) machines: " + candidates.map { "\($0.machine) \($0.urls.map(\.absoluteString))" }.joined(separator: ", "))
                let hosts = await discovery.probe(candidates)
                if hosts.isEmpty { say("no Bark hosts answered") }
                for host in hosts { say(String(describing: host)) }
            }
        } catch {
            say("FAIL: \(error.localizedDescription)")
        }
        say("took \((ContinuousClock.now - t) / .milliseconds(1)) ms, client name “\(HostFinder.computerName)”")
    }

    /// `--ax-probe [seconds]`: waits, then says whether the edit watcher could read the focused
    /// field of the app in front, before and after asking a Chromium-based app for its
    /// accessibility tree. Prints lengths and offsets only, never the text.
    private static func axProbe(after seconds: Int) async {
        say("Accessibility trusted: \(AXIsProcessTrusted())")
        say("Focus a text field in the app to check; reading in \(seconds) s…")
        try? await Task.sleep(for: .seconds(seconds))
        guard let app = NSWorkspace.shared.frontmostApplication, let bundleID = app.bundleIdentifier else {
            say("FAIL: no frontmost app")
            return
        }
        let pid = app.processIdentifier
        let chromium = FieldReader.isChromiumBased(bundleURL: app.bundleURL, bundleID: bundleID)
        say("app: \(bundleID) (Chromium-based: \(chromium))")
        func describe(_ label: String) async {
            let read = await FieldReader.withTimeout(.seconds(2)) { FieldReader.snapshot(pid: pid, bundleID: bundleID) }
            switch read {
            case .success(let field)?:
                say("\(label): readable, \(field.value.utf16.count) UTF-16 units, selection \(field.selectionStart)+\(field.selectionLength)")
            case .failure(let skip)?: say("\(label): not watched (\(skip.rawValue))")
            case nil: say("\(label): timed out")
            }
        }
        await describe("before")
        guard chromium else { return }
        let enabled = await FieldReader.withTimeout { FieldReader.enableManualAccessibility(pid: pid) }
        say("AXManualAccessibility: \(enabled == true ? "set" : "not supported")")
        try? await Task.sleep(for: .seconds(1))
        await describe("after")
    }

    private static func run(file: URL, model: String, host: String?, token: String) async {
        guard let samples = try? load16k(file) else { say("FAIL: cannot read \(file.path)"); return }
        let seconds = Double(samples.count) / 16_000
        say(String(format: "audio: %@ (%.2f s)", file.lastPathComponent, seconds))
        let gate = RecordingGate.evaluate(AudioStats(samples: samples, sampleRate: 16_000))
        say("gate: \(gate)")

        // Local, Neural Engine, on the engine the model needs (FluidAudio or WhisperKit).
        let engine = LocalSpeechRouter()
        let t0 = ContinuousClock.now
        do {
            try await engine.load(model) { stage in
                if case .downloading(let f) = stage, Int(f * 100) % 10 == 0 { print("download \(Int(f * 100))%") }
            }
            let loadMs = (ContinuousClock.now - t0) / .milliseconds(1)
            say(String(format: "local: loaded + warmed %@ in %.0f ms", model, loadMs))
            for run in 1...3 {
                let session = LocalBatchSession(engine: engine, options: .init())
                let t = ContinuousClock.now
                let out = try await session.finish(allSamples: samples)
                let text = await BasicPostProcessor().process(out.text, context: .init(appBundleID: nil, vocabulary: ["X-ray", "Parakeet"]))
                let ms = (ContinuousClock.now - t) / .milliseconds(1)
                say(String(format: "local run %d: %.0f ms (model %d ms, %.0f× real time): %@", run, ms, out.modelMs, seconds * 1000 / max(1, ms), text))
            }
        } catch {
            say("FAIL local: \(error.localizedDescription)")
        }

        // Remote host, streamed, with the SSE feed watched alongside.
        guard let host else { return }
        do {
            let base = try RemoteURLPolicy.validateBaseURL(host)
            let health = try await RemoteHostClient.health(baseURL: host, token: token)
            say("remote: health ok=\(health.ok) backend=\(health.backend) version=\(health.serverVersion ?? "?")")
            let events = Task.detached { await watchEvents(base: base, token: token, seconds: 3 + seconds / 4 + 6) }
            try? await Task.sleep(for: .milliseconds(400))
            let session = RemoteStreamSession(base: base, token: token)
            let chunk = 1_600
            var i = 0
            let t = ContinuousClock.now
            while i < samples.count {
                session.append(Array(samples[i..<min(i + chunk, samples.count)]))
                i += chunk
                try? await Task.sleep(for: .milliseconds(25)) // 100 ms of audio every 25 ms = 4× real time
            }
            let released = ContinuousClock.now
            let out = try await session.finish(allSamples: samples)
            say(String(format: "remote: streamed in %.0f ms, release → text %.0f ms, model=%@: %@",
                       (released - t) / .milliseconds(1), (ContinuousClock.now - released) / .milliseconds(1), out.model, out.text))
            let seen = await events.value
            say("events: " + seen.joined(separator: ", "))
        } catch {
            say("FAIL remote: \(error.localizedDescription)")
        }
    }

    nonisolated private static func watchEvents(base: URL, token: String, seconds: Double) async -> [String] {
        var request = URLRequest(url: RemoteURLPolicy.endpoint(base, RemoteProtocol.eventsPath))
        for (k, v) in RemoteProtocol.authHeaders(token: token) { request.setValue(v, forHTTPHeaderField: k) }
        var seen: [String] = []
        let deadline = ContinuousClock.now + .seconds(seconds)
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { return ["HTTP \(status) (would fall back to polling)"] }
            var parser = SSEParser()
            var state = HostLiveState()
            for try await byte in bytes {
                if ContinuousClock.now > deadline { break }
                guard case .event(let e)? = parser.push(byte) else { continue }
                let event = try HostEvent.decode(e)
                state.apply(event)
                seen.append(e.type)
                if case .jobCompleted = event { break }
            }
            seen.append("state: \(state.workers.count) workers, \(state.models.count) models, served \(state.totalTranscriptions)")
        } catch {
            seen.append("error: \(error.localizedDescription)")
        }
        return seen
    }

    private static func load16k(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: input)
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else { return [] }
        let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(file.length) * 16_000 / file.processingFormat.sampleRate + 1024))!
        let feed = OneShot(input)
        _ = converter.convert(to: out, error: nil) { _, status in
            guard let buffer = feed.take() else { status.pointee = .endOfStream; return nil }
            status.pointee = .haveData
            return buffer
        }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }
}

/// Converter input handed over once (the converter calls back synchronously).
nonisolated private final class OneShot: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? { defer { buffer = nil }; return buffer }
}

private extension RemoteStreamSession {
    convenience init(base: URL, token: String) {
        self.init(baseURL: base, options: .init(token: token, model: SpeechModelCatalog.defaultModelID, language: "en",
                                                vocabularyHints: ["X-ray"]), timeoutSeconds: 30)
    }
}
