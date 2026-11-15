import FairspokenUI
import FairspokenUpdates
import AppKit
import FairspokenCore
import SwiftUI

/// `--screenshots <dir>`: renders the real windows (demo data)
/// in light and dark, captures each window's own pixels and quits. `--screenshots <dir> --updates`
/// captures the update UI instead: every update state, the toast and Settings › Updates; `--speed-test` captures
/// Home's speed-test card and every step of the test (sample runs, nothing recorded). Capturing our *own*
/// windows needs no Screen Recording permission, so this works from the command line.
@MainActor
final class ScreenshotHarness {
    private let model: AppModel
    private let windows: WindowCoordinator
    private let output: URL
    private var showcaseWindow: NSWindow?

    init(model: AppModel, windows: WindowCoordinator, output: URL) {
        self.model = model
        self.windows = windows
        self.output = output
    }

    func run() {
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        AppWindow.appearsActive = true
        Self.drawAsActiveApp()
        model.models.prepare(model.settings.settings.model)
        NSApp.setActivationPolicy(.regular)
        Task {
            windows.showDashboard(.home)
            // Activation is cooperative on macOS 14+; keep asking until we're frontmost so
            // windows render in their active state.
            for _ in 0..<40 where !NSApp.isActive {
                NSApp.activate()
                // Dev-only: the cooperative API can't take focus from a terminal; the legacy
                // call still can. Invoked dynamically to keep the build warning-free.
                _ = NSApp.perform(NSSelectorFromString("activateIgnoringOtherApps:"), with: true as NSNumber)
                try? await Task.sleep(for: .milliseconds(100))
            }
            try? await Task.sleep(for: .seconds(1))
            if AppInfo.arguments.contains("--updates") {
                await updateShots()
                NSApp.terminate(nil)
                return
            }
            // Let the engine finish warming so status chips read "Ready".
            for _ in 0..<150 where !model.models.engineState.isReady {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if AppInfo.arguments.contains("--speed-test") {
                for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                    NSApp.appearance = NSAppearance(named: appearance)
                    await speedTestShots(suffix: name)
                }
                NSApp.terminate(nil)
                return
            }
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                NSApp.appearance = NSAppearance(named: appearance)
                // `--pill-only`: just the recording pill, for quick review of its states.
                if !AppInfo.arguments.contains("--pill-only") {
                    await dashboardShots(suffix: name)
                    await onboardingShots(suffix: name)
                }
                await pillShots(suffix: name)
            }
            NSApp.terminate(nil)
        }
    }

    private func dashboardShots(suffix: String) async {
        windows.showDashboard(.home)
        // One size for every shot, whatever the window was last left at.
        windows.dashboard?.setContentSize(NSSize(width: 1180, height: 800))
        model.dictation.showcase(.idle, inAppResult: .init(
            text: "Please book a follow-up appointment in ten days and request a chest X-ray.",
            words: 14, delivery: .shownInApp, latencyMs: 74, placement: .neuralEngine))
        for section in AppModel.Section.allCases {
            windows.showDashboard(section)
            if section == .settings { model.settingsTab = .general }
            try? await Task.sleep(for: .milliseconds(1600))
            await freshFrame()
            if let window = windows.dashboard { await capture(window, as: "\(section.rawValue)-\(suffix)") }
        }
        await modelLinkShots(suffix: suffix)
        // Home while listening: the level and the words so far in the dictate bar.
        windows.showDashboard(.home)
        model.dictation.showcase(.listening(since: Date().addingTimeInterval(-7)),
                                 liveText: "Can we move the Thursday practice meeting to")
        let feeder = feedLevels(into: model.dictation.meter)
        try? await Task.sleep(for: .milliseconds(1400))
        await freshFrame()
        if let window = windows.dashboard { await capture(window, as: "home-listening-\(suffix)") }
        feeder.cancel()
        model.dictation.showcase(.idle)
        // "See all": every dictation by day.
        model.homeShowsAllDictations = true
        try? await Task.sleep(for: .milliseconds(900))
        await freshFrame()
        if let window = windows.dashboard { await capture(window, as: "home-all-\(suffix)") }
        model.homeShowsAllDictations = false
        // Before the first dictation.
        model.history.showcaseEmpty(true)
        model.dictation.showcaseClearResult()
        try? await Task.sleep(for: .milliseconds(900))
        await freshFrame()
        if let window = windows.dashboard { await capture(window, as: "home-first-use-\(suffix)") }
        model.history.showcaseEmpty(false)
        // `--small-windows`: Home and Models at the smallest window size, for layout review.
        if AppInfo.arguments.contains("--small-windows") {
            windows.dashboard?.setContentSize(NSSize(width: 960, height: 640))
            for section in [AppModel.Section.home, .models, .settings] {
                windows.showDashboard(section)
                try? await Task.sleep(for: .milliseconds(1000))
                await freshFrame()
                if let window = windows.dashboard { await capture(window, as: "small-\(section.rawValue)-\(suffix)") }
            }
            windows.dashboard?.setContentSize(NSSize(width: 1180, height: 800))
        }
        model.settingsTab = .transcription
        windows.showDashboard(.settings)
        try? await Task.sleep(for: .milliseconds(1000))
        await freshFrame()
        if let window = windows.dashboard { await capture(window, as: "settings-transcription-\(suffix)") }
        // The same tab with Network device chosen (the sample host; no tailnet scan, so no real machines).
        let location = model.settings.settings.transcriptionLocation
        model.settings.update { $0.transcriptionLocation = .remoteHost }
        model.hostStatus.refresh(force: true)
        try? await Task.sleep(for: .milliseconds(800))
        await freshFrame()
        if let window = windows.dashboard { await capture(window, as: "settings-host-\(suffix)") }
        model.settings.update { $0.transcriptionLocation = location }
        // Entries learned from corrections beside the user's own (screenshot settings are never saved).
        model.settings.update { s in
            for term in ["Beaumont", "Niamh"] where !s.vocabularyHints.contains(term) {
                s.vocabularyHints.append(term)
                if term == "Niamh" { s.learnedVocabularyHints.append(term) }
            }
            if !s.transcriptCorrections.contains(where: { $0.from == "cloud code" }) {
                s.transcriptCorrections.append(TranscriptCorrection(from: "h b a one c", to: "HbA1c"))
                s.transcriptCorrections.append(TranscriptCorrection(from: "cloud code", to: "Claude Code", origin: .learned,
                                                                    models: ["parakeet-tdt-0.6b-v3"]))
            }
        }
        model.settingsTab = .vocabulary
        try? await Task.sleep(for: .milliseconds(800))
        await freshFrame()
        if let window = windows.dashboard { await capture(window, as: "settings-vocabulary-\(suffix)") }
        windows.dashboard?.orderOut(nil)
    }

    /// The Models library with a download in progress and a favourite, a model's detail sheet,
    /// and "Download from Link…" open in a sheet, then with the link saved. Screenshot settings
    /// are never saved, and nothing downloads.
    private func modelLinkShots(suffix: String) async {
        let id = "parakeet-tdt-0.6b-v2"
        let sample = "https://artifactory.example.org/artifactory/models/parakeet-tdt-0.6b-v2-mac.zip"
        model.models.presentedAsAvailable = [id]
        model.models.refresh()
        model.models.showcase("large-v3-turbo", .downloading(0.42))
        model.settings.update { $0.favoriteModels = ["small.en"] }
        windows.showDashboard(.models)
        try? await Task.sleep(for: .milliseconds(1200))
        await freshFrame()
        if let window = windows.dashboard { await capture(window, as: "models-library-\(suffix)") }

        model.modelDetailID = "large-v3"
        try? await Task.sleep(for: .milliseconds(1200))
        await captureSheet(as: "models-detail-\(suffix)")
        model.modelDetailID = nil
        try? await Task.sleep(for: .milliseconds(600))

        model.linkDraft = sample
        model.linkEditorModel = id
        model.modelDetailID = id
        try? await Task.sleep(for: .milliseconds(1200))
        await captureSheet(as: "models-link-open-\(suffix)")
        model.linkEditorModel = nil
        // The query (a token) is never shown.
        model.settings.update { $0.modelLinks[id] = sample + "?X-JFrog-Art-Api=sample-token" }
        try? await Task.sleep(for: .milliseconds(600))
        await captureSheet(as: "models-link-saved-\(suffix)")
        model.modelDetailID = nil
        try? await Task.sleep(for: .milliseconds(600))
        model.settings.update {
            $0.modelLinks = [:]
            $0.favoriteModels = []
        }
        model.models.presentedAsAvailable = []
        model.models.refresh()
    }

    /// Home's speed-test card (inviting, then with a result) and each step of the test: typing
    /// part-way, speaking (ready, listening, transcribing), and the results of a clean run and of a
    /// rough one. Sample runs: nothing records and nothing is saved.
    private func speedTestShots(suffix: String) async {
        let test = model.speedTest
        let passage = SpeedTest.passages[0]
        let typing = SpeedTest.TypingResult(seconds: 112, wpm: 44, accuracy: 96)
        windows.showDashboard(.home)
        windows.dashboard?.setContentSize(NSSize(width: 1180, height: 800))
        model.dictation.showcase(.idle)
        model.dictation.showcaseClearResult()

        func shoot(_ name: String) async {
            try? await Task.sleep(for: .milliseconds(1200))
            await freshFrame()
            if let window = windows.dashboard { await capture(window, as: "speed-test-\(name)-\(suffix)") }
        }
        func shootSheet(_ name: String, wait: Int = 1200) async {
            try? await Task.sleep(for: .milliseconds(wait))
            await captureSheet(as: "speed-test-\(name)-\(suffix)")
        }

        // Home before any test: the invitation, time saved against the typical pace.
        test.showcaseSummary(SpeedTest.Summary())
        model.history.showcaseTypingWPM(nil)
        await shoot("home-invite")
        // Home after one: the last result, time saved against the measured pace.
        test.showcaseSummary(SpeedTestController.demoSummary)
        model.history.showcaseTypingWPM(44)
        await shoot("home-result")

        // 1 Type: part-way, with a wrong key and a skipped space.
        let typed = String(passage.prefix(172))
            .replacingOccurrences(of: "evening fog", with: "eveninf fog")
            .replacingOccurrences(of: "turned for", with: "turnedfor")
        test.showcaseTyping(passage: passage, typed: typed, seconds: 41)
        await shootSheet("1-typing", wait: 1600)

        // 2 Speak: ready, listening (words so far), transcribing.
        test.showcaseSpeaking(passage: passage, typing: typing)
        await shootSheet("2-speak-ready")
        model.dictation.showcase(.listening(since: Date().addingTimeInterval(-14)),
                                 liveText: "The harbor lights came on one by one as the evening fog rolled in, and the small boats turned",
                                 trigger: .button, measuring: true)
        let feeder = feedLevels(into: model.dictation.meter)
        await shootSheet("2-speak-listening")
        feeder.cancel()
        model.dictation.showcase(.transcribing, measuring: true)
        await shootSheet("2-speak-transcribing")
        model.dictation.showcase(.idle)

        // 3 Results: a clean run (one word heard differently), a new best, its typing speed not yet chosen for Home.
        model.history.showcaseTypingWPM(nil)
        let clean = passage.replacingOccurrences(of: "notebook he had", with: "notebook he'd")
        test.showcaseResults(passage: passage, typing: typing, transcript: clean, speakingSeconds: 32.6, newBest: true)
        await shootSheet("3-results")
        // A rough one: gated, then with its times shown anyway.
        let words = passage.split(separator: " ")
        let rough = (words.prefix(30) + ["and", "the", "harbour", "master", "stood"] + words.suffix(20)).joined(separator: " ")
        test.showcaseResults(passage: passage, typing: typing, transcript: rough, speakingSeconds: 29.1)
        await shootSheet("3-results-gated")
        test.showcaseResults(passage: passage, typing: typing, transcript: rough, speakingSeconds: 29.1, gatedTimes: true)
        await shootSheet("3-results-gated-times")
        test.isPresented = false
        try? await Task.sleep(for: .milliseconds(600))
    }

    /// The sheet attached to the dashboard, captured on its own.
    private func captureSheet(as name: String) async {
        guard let sheet = windows.dashboard?.attachedSheet else { return }
        sheet.displayIfNeeded()
        await capture(sheet, as: name)
    }

    /// The sidebar update button in each state (the window, Home), the available toast, and
    /// Settings › Updates with an update ready. Simulated: Sparkle is never started here.
    private func updateShots() async {
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            for name in UpdateState.sampleNames {
                guard let state = UpdateState.sample(named: name) else { continue }
                model.updates.simulate(state, toast: name == "available")
                windows.showDashboard(.home)
                try? await Task.sleep(for: .milliseconds(900))
                await freshFrame()
                if let window = windows.dashboard { await capture(window, as: "update-\(name)-\(suffix)") }
                model.updates.dismissToast()
            }
            model.updates.simulate(.available(version: "0.3.0"))
            model.settingsTab = .updates
            windows.showDashboard(.settings)
            try? await Task.sleep(for: .milliseconds(1000))
            await freshFrame()
            if let window = windows.dashboard { await capture(window, as: "settings-updates-\(suffix)") }
        }
    }

    /// Every step of the setup guide. The microphone test is fed sample levels and "Try it" shows
    /// a dictated message with the next one arriving; nothing records and nothing downloads.
    private func onboardingShots(suffix: String) async {
        let names: [OnboardingView.Step: String] = [.welcome: "welcome", .permissions: "permissions", .microphone: "microphone",
                                                    .model: "model", .shortcut: "shortcut", .tryIt: "try-it", .finish: "finish"]
        for step in OnboardingView.Step.allCases {
            var feeder: Task<Void, Never>?
            if step == .microphone {
                model.micTest.showcase(listening: true, peak: 0.7)
                feeder = feedLevels(into: model.micTest.meter)
            }
            if step == .tryIt {
                model.dictation.showcase(.listening(since: Date().addingTimeInterval(-4)), liveText: "And copy in the practice nurse so she")
                feeder = feedLevels(into: model.dictation.meter)
            }
            let view = OnboardingView(initialStep: step, showcase: true) {}.environment(model)
            let hosting = NSHostingController(rootView: view)
            hosting.sizingOptions = []
            let window = AppWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.setContentSize(OnboardingView.size)
            window.center()
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(1400))
            await capture(window, as: "onboarding-\(step.rawValue + 1)-\(names[step] ?? "step")-\(suffix)")
            feeder?.cancel()
            model.micTest.stop()
            model.dictation.showcase(.idle)
            window.orderOut(nil)
        }
    }

    /// The pill states over a wallpaper-like backdrop (the real pill samples the desktop,
    /// which a window capture can't include, so it is staged in a showcase window).
    private func pillShots(suffix: String) async {
        let phases: [(String, DictationController.Phase)] = [
            ("listening", .listening(since: Date().addingTimeInterval(-12))),
            ("listening-text", .listening(since: Date().addingTimeInterval(-9))),
            ("transcribing", .transcribing),
            ("inserted", .done(.init(text: "x", words: 38, delivery: .pasted(app: "Mail"), latencyMs: 68, placement: .neuralEngine))),
            ("error", .failed("No speech detected")),
        ]
        var controllers: [DictationController] = []
        var feeders: [Task<Void, Never>] = []
        for (name, phase) in phases {
            let c = DictationController(settings: model.settings, models: model.models, history: model.history, permissions: model.permissions,
                                        pending: model.pending)
            c.showcase(phase, liveText: name == "listening-text"
                ? "The patient reports a dry cough for two weeks, with no fever, and mild shortness of breath when climbing stairs"
                : "")
            feeders.append(feedLevels(into: c.meter))
            controllers.append(c)
        }
        let window = stageShowcase(PillShowcase(controllers: controllers, shortcut: HotkeyController.currentShortcutSymbols))
        try? await Task.sleep(for: .milliseconds(1500))
        window.contentViewController = NSHostingController(rootView: PillShowcase(controllers: controllers, shortcut: HotkeyController.currentShortcutSymbols))
        window.setContentSize(NSSize(width: 760, height: 600))
        try? await Task.sleep(for: .milliseconds(250))
        await capture(window, as: "pill-\(suffix)")
        feeders.forEach { $0.cancel() }
        window.orderOut(nil)
        await pillLevelShots(suffix: suffix)
        await pillScrollShots(suffix: suffix)
    }

    /// The level indicator at a few voice levels (peak dBFS RMS), with and without Reduce Motion.
    private func pillLevelShots(suffix: String) async {
        let levels: [Float?] = [nil, -42, -32, -22]
        for reduceMotion in [false, true] {
            var controllers: [DictationController] = []
            var feeders: [Task<Void, Never>] = []
            for peak in levels {
                let c = DictationController(settings: model.settings, models: model.models, history: model.history,
                                            permissions: model.permissions, pending: model.pending)
                c.showcase(.listening(since: Date().addingTimeInterval(-4)))
                feeders.append(feedLevels(into: c.meter, peakDB: peak))
                controllers.append(c)
            }
            let showcase = PillShowcase(controllers: controllers, shortcut: HotkeyController.currentShortcutSymbols)
                .environment(\.showcaseReduceMotion, reduceMotion)
            let window = stageShowcase(showcase, size: NSSize(width: 760, height: 380))
            try? await Task.sleep(for: .milliseconds(1800))
            // A fresh hosting controller renders the level as it is now (see `freshFrame`).
            window.contentViewController = NSHostingController(rootView: showcase)
            window.setContentSize(NSSize(width: 760, height: 380))
            try? await Task.sleep(for: .milliseconds(250))
            await capture(window, as: "pill-levels\(reduceMotion ? "-reduce-motion" : "")-\(suffix)")
            feeders.forEach { $0.cancel() }
            window.orderOut(nil)
        }
    }

    /// Long live text: following the newest words, then scrolled partway up by a real scroll
    /// event (which pauses the following while more words arrive).
    private func pillScrollShots(suffix: String) async {
        let text = Self.longDictation
        let c = DictationController(settings: model.settings, models: model.models, history: model.history,
                                    permissions: model.permissions, pending: model.pending)
        c.showcase(.listening(since: Date().addingTimeInterval(-48)), liveText: text)
        let feeder = feedLevels(into: c.meter)
        let window = stageShowcase(PillShowcase(controllers: [c], shortcut: HotkeyController.currentShortcutSymbols),
                                    size: NSSize(width: 760, height: 260))
        try? await Task.sleep(for: .milliseconds(1500))
        await capture(window, as: "pill-scroll-bottom-\(suffix)")
        if let scroll = Self.scrollViews(in: window.contentView).first,
           let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 14, wheel2: 0, wheel3: 0),
           let event = NSEvent(cgEvent: cg) {
            scroll.scrollWheel(with: event)
        }
        try? await Task.sleep(for: .milliseconds(400))
        // More words arrive while scrolled up: the view stays where it was.
        c.showcase(.listening(since: Date().addingTimeInterval(-50)), liveText: text + " Please also send a copy to the practice nurse.")
        try? await Task.sleep(for: .milliseconds(600))
        await capture(window, as: "pill-scroll-up-\(suffix)")
        feeder.cancel()
        window.orderOut(nil)
    }

    static let longDictation = "The patient reports a dry cough for two weeks, with no fever, and mild shortness of breath when "
        + "climbing stairs. She has no chest pain. She stopped smoking three years ago. On examination her chest is clear "
        + "and her oxygen saturation is ninety seven percent on room air. Plan: a chest X-ray, bloods including a full "
        + "blood count, and review in ten days, sooner if she gets worse."

    private static func scrollViews(in view: NSView?) -> [NSScrollView] {
        guard let view else { return [] }
        return (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }

    private func stageShowcase(_ view: some View, size: NSSize = NSSize(width: 760, height: 600)) -> NSWindow {
        let window = AppWindow(contentViewController: NSHostingController(rootView: view))
        window.styleMask = [.titled, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.setContentSize(size)
        window.center()
        window.makeKeyAndOrderFront(nil)
        showcaseWindow = window
        return window
    }

    /// Dev-only: the session may be locked while screenshots run, and then the app can't become
    /// active, so AppKit draws every switch and button as in a background window. Reporting the
    /// app as active for this run draws them as a person sees them.
    private static func drawAsActiveApp() {
        #if DEBUG
        guard let method = class_getInstanceMethod(NSApplication.self, #selector(getter: NSApplication.isActive)) else { return }
        let block: @convention(block) (AnyObject) -> Bool = { _ in true }
        method_setImplementation(method, imp_implementationWithBlock(block))
        #endif
    }

    /// Speech-like levels: syllables peaking near `peakDB` (dBFS RMS) over a quiet room, or only
    /// the room (about -62 dBFS) when nil.
    private func feedLevels(into meter: LevelMeter, peakDB: Float? = -28) -> Task<Void, Never> {
        Task {
            var t = 0.0
            while !Task.isCancelled {
                t += 0.03
                let db: Float
                if let peakDB {
                    // Syllables about five a second near the peak, dipping 18 dB between them.
                    let syllable = pow(abs(sin(t * 5.5)), 0.6) * (0.75 + 0.25 * sin(t * 1.3))
                    db = peakDB - 18 * (1 - Float(syllable))
                } else {
                    db = -62 + Float(2 * sin(t * 7))
                }
                meter.push(rms: pow(10, db / 20))
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
    }

    /// When the session's windows are occluded (screen locked, display asleep) AppKit stops
    /// driving SwiftUI frame updates; a fresh hosting controller always renders once.
    private func freshFrame() async {
        if windows.dashboard != nil {
            windows.rebuildDashboardContent()
            try? await Task.sleep(for: .milliseconds(350))
        }
    }

    // MARK: Capture

    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// `CGWindowListCreateImage` is unavailable to Swift in the macOS 15+ SDK but still works at
    /// runtime for the calling app's own windows (no Screen Recording grant needed). Dev-only.
    private func capture(_ window: NSWindow, as name: String) async {
        // Activation is cooperative and can lag; wait (briefly) for the window to be key so it
        // renders in its active state (coloured controls, prominent buttons).
        for _ in 0..<20 where !window.isKeyWindow || !NSApp.isActive {
            window.makeKeyAndOrderFront(nil)
            _ = NSApp.perform(NSSelectorFromString("activateIgnoringOtherApps:"), with: true as NSNumber)
            try? await Task.sleep(for: .milliseconds(100))
        }
        window.displayIfNeeded()
        try? Self.png(of: window)?.write(to: output.appendingPathComponent("\(name).png"))
    }

    /// The window's own pixels as PNG.
    static func png(of window: NSWindow) -> Data? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        // includingWindow = 1 << 3; boundsIgnoreFraming = 1 << 0, bestResolution = 1 << 3
        guard let image = create(.null, 1 << 3, UInt32(window.windowNumber), (1 << 0) | (1 << 3))?.takeRetainedValue() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}

private struct PillShowcase: View {
    var controllers: [DictationController]
    var shortcut: String

    var body: some View {
        ZStack {
            // A quiet, wallpaper-like backdrop: cool slate with a soft sage glow.
            LinearGradient(colors: [Color(red: 0.36, green: 0.42, blue: 0.47), Color(red: 0.58, green: 0.63, blue: 0.66),
                                    Color(red: 0.80, green: 0.82, blue: 0.80)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(Color(red: 0.55, green: 0.75, blue: 0.64).opacity(0.35)).frame(width: 420).blur(radius: 90).offset(x: -220, y: -120)
            VStack(spacing: 18) {
                ForEach(Array(controllers.enumerated()), id: \.offset) { _, c in
                    PillView(dictation: c, shortcut: shortcut).frame(width: 520).frame(minHeight: 76)
                }
            }
            .padding(.top, 20)
        }
        .ignoresSafeArea()
    }
}
