import AppKit
import SwiftUI

/// Owns the dashboard and onboarding windows and switches the activation policy:
/// regular (Dock + ⌘Tab) while one is open, accessory (menu bar only) otherwise.
@MainActor
final class WindowCoordinator: NSObject, NSWindowDelegate {
    private let model: AppModel
    private(set) var dashboard: NSWindow?
    private(set) var onboarding: NSWindow?
    private var hideObserver: NSObjectProtocol?

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    func showDashboard(_ section: AppModel.Section? = nil) {
        if let section { model.section = section }
        if dashboard == nil {
            let hosting = NSHostingController(rootView: DashboardView().environment(model))
            let window = AppWindow(contentViewController: hosting)
            // A hidden, transparent title bar: the traffic lights sit on the sidebar's frost.
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.title = AppInfo.displayName
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 1180, height: 820))
            window.minSize = NSSize(width: 960, height: 640)
            window.setFrameAutosaveName("Dashboard")
            if !window.setFrameUsingName("Dashboard") { window.center() }
            window.delegate = self
            window.identifier = NSUserInterfaceItemIdentifier("dashboard")
            dashboard = window
        }
        present(dashboard!)
    }

    /// Opens the setup guide at its first step (a guide reopened half-way through would start from
    /// stale state). `reset: false` (a dictation found the microphone off) only brings an open guide
    /// forward, so someone on the Permissions step stays there.
    func showOnboarding(reset: Bool = true) {
        if !reset, let window = onboarding {
            present(window)
            return
        }
        let view = OnboardingView { [weak self] in
            self?.onboarding?.close()
            self?.showDashboard(.home)
        }
        .environment(model)
        if let window = onboarding {
            stopOnboardingAudio()
            let hosting = NSHostingController(rootView: view)
            hosting.sizingOptions = []
            window.contentViewController = hosting
            window.setContentSize(Self.onboardingSize())
        } else {
            let hosting = NSHostingController(rootView: view)
            // The window keeps the guide's size; the view fills it.
            hosting.sizingOptions = []
            let window = AppWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            window.title = "Set up \(AppInfo.displayName)"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.setContentSize(Self.onboardingSize())
            window.center()
            window.delegate = self
            window.identifier = Self.onboardingID
            onboarding = window
        }
        if hideObserver == nil {
            hideObserver = NotificationCenter.default.addObserver(forName: NSApplication.didHideNotification, object: nil,
                                                                  queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if self?.onboarding != nil { self?.stopOnboardingAudio() } }
            }
        }
        present(onboarding!)
    }

    /// Closing, minimising or hiding the guide stops its microphone test, and a dictation into
    /// the guide itself ("Try it"). A dictation into another app carries on.
    private func stopOnboardingAudio() {
        model.micTest.stop()
        if model.dictation.phase.isListening, model.dictation.startedInWindow == Self.onboardingID { model.dictation.cancel() }
    }

    static let onboardingID = NSUserInterfaceItemIdentifier("onboarding")

    /// The guide's size, no taller than the screen (its steps scroll and its buttons stay visible).
    static func onboardingSize() -> NSSize {
        let available = (NSScreen.main?.visibleFrame.height ?? 1000) - 40
        return NSSize(width: OnboardingView.size.width, height: min(OnboardingView.size.height, max(560, available)))
    }

    func windowDidMiniaturize(_ notification: Notification) {
        if (notification.object as? NSWindow) == onboarding { stopOnboardingAudio() }
    }

    /// Screenshot harness: swap in a fresh hosting controller so the next frame reflects the
    /// current state even when the window server has paused updates for an occluded window.
    func rebuildDashboardContent() {
        guard let window = dashboard else { return }
        let frame = window.frame
        let hosting = NSHostingController(rootView: DashboardView().environment(model))
        window.contentViewController = hosting
        window.setFrame(frame, display: true)
    }

    private func present(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window == onboarding {
            stopOnboardingAudio()
            onboarding = nil
        }
        // The speed test ends with its window: a recording for it is thrown away.
        if window == dashboard { model.speedTest.isPresented = false }
        DispatchQueue.main.async { [weak self] in self?.updatePolicy() }
    }

    private func updatePolicy() {
        let anyVisible = [dashboard, onboarding].contains { $0?.isVisible == true }
        if !anyVisible { NSApp.setActivationPolicy(.accessory) }
    }
}

/// The app's windows. `appearsActive` (screenshot runs only) draws them as the key window even
/// when the session can't activate the app (a locked screen), so captures show live controls.
final class AppWindow: NSWindow {
    static var appearsActive = false
    override var isKeyWindow: Bool { Self.appearsActive || super.isKeyWindow }
    override var isMainWindow: Bool { Self.appearsActive || super.isMainWindow }
}
