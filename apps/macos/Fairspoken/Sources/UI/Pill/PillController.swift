import FairspokenUI
import AppKit
import SwiftUI

/// Non-activating, borderless panel that floats above everything on every Space.
/// Non-activation is the critical property: focus never leaves the target app, so ⌘V
/// lands where the user was typing (plan §2.1).
final class PillPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The pill, pinned to the bottom of the panel so it grows upwards as live text appears.
private struct PillRoot: View {
    var dictation: DictationController
    var maxLines: Int
    var onScrollableFrame: (CGRect?) -> Void

    var body: some View {
        PillView(dictation: dictation, shortcut: HotkeyController.currentShortcutSymbols, maxLines: maxLines,
                 onScrollableFrame: onScrollableFrame)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 15)
    }
}

@MainActor
final class PillController {
    private let panel: PillPanel
    private let host: NSHostingView<PillRoot>
    private let dictation: DictationController
    private var hideWork: DispatchWorkItem?
    /// Room for the pill at its largest (four lines of live text); the panel is transparent
    /// and ignores the mouse outside the pill, so the spare room is invisible and click-through.
    private static let size = NSSize(width: 520, height: 150)
    /// Screens shorter than this (visible height, points) get three lines of live text, not four.
    private static let smallScreenHeight: CGFloat = 820
    /// The pill's frame in the hosting view (top-left origin) while its text can be scrolled.
    private var scrollableFrame: CGRect?
    private var mouseMonitors: [Any] = []

    init(model: AppModel) {
        dictation = model.dictation
        panel = PillPanel(contentRect: NSRect(origin: .zero, size: Self.size))
        host = NSHostingView(rootView: PillRoot(dictation: model.dictation, maxLines: PillView.defaultMaxLines,
                                                onScrollableFrame: { _ in }))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: Self.size)
        panel.contentView = host
        panel.setAccessibilityLabel("Dictation status")
        host.rootView = root(maxLines: PillView.defaultMaxLines)
    }

    private func root(maxLines: Int) -> PillRoot {
        PillRoot(dictation: dictation, maxLines: maxLines) { [weak self] frame in
            self?.scrollableFrame = frame
            self?.updateMouse()
        }
    }

    func update(for phase: DictationController.Phase) {
        hideWork?.cancel()
        if phase == .idle {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        } else {
            show()
        }
    }

    private func show() {
        if !panel.isVisible {
            position()
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            startMouseTracking()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
    }

    private func hide() {
        stopMouseTracking()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [panel] in
            MainActor.assumeIsolated { if panel.alphaValue == 0 { panel.orderOut(nil) } }
        })
    }

    /// Bottom centre of the screen the pointer is on, just above the Dock.
    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let origin = NSPoint(x: visible.midX - Self.size.width / 2, y: visible.minY + 28)
        panel.setFrameOrigin(origin)
        let lines = visible.height < Self.smallScreenHeight ? 3 : PillView.defaultMaxLines
        if host.rootView.maxLines != lines { host.rootView = root(maxLines: lines) }
    }

    // MARK: Scrolling the live text

    /// The panel ignores the mouse, so clicks and scrolls go to the app underneath, except
    /// while the pointer is over the pill and its text can be scrolled. Then the panel takes the
    /// scroll wheel. It still never becomes key or activates the app (`PillPanel`), so the
    /// person's app keeps the keyboard focus and the text is inserted there.
    private func startMouseTracking() {
        guard mouseMonitors.isEmpty else { return }
        panel.acceptsMouseMovedEvents = true
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .scrollWheel]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMouse() }
        }) {
            mouseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.updateMouse() }
            return event
        }) {
            mouseMonitors.append(local)
        }
        updateMouse()
    }

    private func stopMouseTracking() {
        mouseMonitors.forEach(NSEvent.removeMonitor)
        mouseMonitors.removeAll()
        panel.ignoresMouseEvents = true
    }

    private func updateMouse() {
        let over: Bool
        if !mouseMonitors.isEmpty, panel.isVisible, let frame = scrollableFrame {
            let onScreen = NSRect(x: panel.frame.minX + frame.minX, y: panel.frame.maxY - frame.maxY,
                                  width: frame.width, height: frame.height)
            over = onScreen.contains(NSEvent.mouseLocation)
        } else {
            over = false
        }
        if panel.ignoresMouseEvents == over { panel.ignoresMouseEvents = !over }
    }

    #if DEBUG
    var debugPanel: NSPanel { panel }

    /// `--pill-demo`: where the scrollable pill is on screen (bottom-left origin) and whether
    /// the panel takes the mouse.
    var debugDescription: String {
        let frame = scrollableFrame.map {
            NSRect(x: panel.frame.minX + $0.minX, y: panel.frame.maxY - $0.maxY, width: $0.width, height: $0.height)
        }
        return "pill frame=\(frame.map { NSStringFromRect($0) } ?? "none") takesMouse=\(!panel.ignoresMouseEvents) key=\(panel.isKeyWindow) active=\(NSApp.isActive)"
    }
    #endif
}
