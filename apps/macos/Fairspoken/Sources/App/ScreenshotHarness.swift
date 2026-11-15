import FairspokenUI
import FairspokenUpdates
import AppKit
import FairspokenCore
import SwiftUI

/// `--screenshots <dir>`: renders the real windows (demo data)
/// in light and dark, captures each window's own pixels and quits. `--screenshots <dir> --updates`
/// captures the update UI instead: every update state, the toast and Settings › Updates. Capturing our *own*
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
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                NSApp.appearance = NSAppearance(named: appearance)
                await dashboardShots(suffix: name)
                await onboardingShots(suffix: name)
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
        // Toggle mode, so the hints show the shortcut that stops ("Stop ⇧⌘1 · Cancel esc").
        let mode = model.settings.settings.recordingShortcutMode
        model.settings.update { $0.recordingShortcutMode = .toggle }
        defer { model.settings.update { $0.recordingShortcutMode = mode } }
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
            let c = DictationController(settings: model.settings, models: model.models, history: model.history, permissions: model.permissions)
            c.showcase(phase, liveText: name == "listening-text"
                ? "The patient reports a dry cough for two weeks, with no fever, and mild shortness of breath when climbing stairs"
                : "")
            feeders.append(feedLevels(into: c.meter))
            controllers.append(c)
        }
        let view = PillShowcase(controllers: controllers, shortcut: HotkeyController.currentShortcutSymbols)
        let hosting = NSHostingController(rootView: view)
        let window = AppWindow(contentViewController: hosting)
        window.styleMask = [.titled, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 760, height: 600))
        window.center()
        window.makeKeyAndOrderFront(nil)
        showcaseWindow = window
        try? await Task.sleep(for: .milliseconds(1500))
        window.contentViewController = NSHostingController(rootView: PillShowcase(controllers: controllers, shortcut: HotkeyController.currentShortcutSymbols))
        window.setContentSize(NSSize(width: 760, height: 600))
        try? await Task.sleep(for: .milliseconds(250))
        await capture(window, as: "pill-\(suffix)")
        feeders.forEach { $0.cancel() }
        window.orderOut(nil)
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

    private func feedLevels(into meter: LevelMeter) -> Task<Void, Never> {
        Task {
            var t = 0.0
            while !Task.isCancelled {
                t += 0.05
                let speech = 0.5 + 0.5 * sin(t * 3.1) * sin(t * 1.3 + 0.6)
                meter.push(rms: Float(0.004 + 0.09 * max(0, speech) * (0.7 + 0.3 * sin(t * 11))))
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
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        // includingWindow = 1 << 3; boundsIgnoreFraming = 1 << 0, bestResolution = 1 << 3
        guard let image = create(.null, 1 << 3, UInt32(window.windowNumber), (1 << 0) | (1 << 3))?.takeRetainedValue() else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: output.appendingPathComponent("\(name).png"))
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
