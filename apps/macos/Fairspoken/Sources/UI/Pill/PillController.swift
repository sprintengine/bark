import FairspokenCore
import FairspokenUI
import AppKit
import SwiftUI

/// Non-activating, borderless panel that floats above everything on every Space.
/// Non-activation is the critical property: focus never leaves the target app, so ⌘V
/// lands where the user was typing (plan §2.1). Clicks on it reach its buttons without
/// making it key or bringing Bark forward.
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
        acceptsMouseMovedEvents = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A hosting view whose buttons answer the first click: the panel is never key, so without
/// this a click would only "activate" a window that can't be activated.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The pill, pinned to the bottom of the panel so it grows upwards as live text appears.
private struct PillRoot: View {
    var dictation: DictationController
    var maxLines: Int
    var interaction: PillInteraction
    var serverName: () -> String?

    var body: some View {
        PillView(dictation: dictation, shortcut: HotkeyController.currentShortcutSymbols, maxLines: maxLines,
                 interaction: interaction, serverName: serverName())
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, PillController.shadowRoom)
    }
}

/// The style menu's content, following the dictation as it changes.
private struct StyleMenuRoot: View {
    var dictation: DictationController
    var interaction: PillInteraction

    var body: some View {
        if let state = StyleChipState(resolution: dictation.currentStyle, rulesResolution: dictation.rulesStyle,
                                      target: dictation.alwaysUseTarget), !state.isLocked {
            StyleMenuView(state: state) { style in
                dictation.setStyleOverride(style)
                interaction.closeMenu()
            } onRules: {
                dictation.setStyleOverride(nil)
                interaction.closeMenu()
            } onAlwaysUse: { style in
                dictation.alwaysUseStyle(style)
                interaction.closeMenu()
            }
            .padding(PillController.menuShadowRoom)
            .fixedSize()
        }
    }
}

@MainActor
final class PillController {
    private let panel: PillPanel
    private let host: FirstClickHostingView<PillRoot>
    private let menuPanel: PillPanel
    private let menuHost: FirstClickHostingView<StyleMenuRoot>
    private let model: AppModel
    private let dictation: DictationController
    let interaction: PillInteraction
    private var hideWork: DispatchWorkItem?
    /// Room for the pill at its largest (four lines of live text) and its shadow; the panel is
    /// transparent and ignores the mouse outside the pill, so the spare room is invisible and
    /// click-through.
    private static let size = NSSize(width: 520, height: 196)
    /// Below the capsule, for its shadow.
    static let shadowRoom: CGFloat = 26
    /// Around the style menu, for its shadow.
    static let menuShadowRoom: CGFloat = 16
    /// Screens shorter than this (visible height, points) get three lines of live text, not four.
    private static let smallScreenHeight: CGFloat = 820
    /// Resting the pointer on the style chip this long opens the menu.
    private static let hoverDelay: TimeInterval = 0.18
    /// A menu the pointer opened closes once the pointer has been away this long.
    private static let leaveDelay: TimeInterval = 0.35
    private var mouseMonitors: [Any] = []
    private var poll: Timer?
    private var hoverSince: Date?
    private var awaySince: Date?

    init(model: AppModel) {
        self.model = model
        dictation = model.dictation
        panel = PillPanel(contentRect: NSRect(origin: .zero, size: Self.size))
        let interaction = PillInteraction()
        self.interaction = interaction
        host = FirstClickHostingView(rootView: PillRoot(dictation: model.dictation, maxLines: PillView.defaultMaxLines,
                                                        interaction: interaction, serverName: { nil }))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: Self.size)
        panel.contentView = host
        panel.setAccessibilityLabel("Dictation status")

        menuPanel = PillPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 320))
        menuPanel.ignoresMouseEvents = false
        menuHost = FirstClickHostingView(rootView: StyleMenuRoot(dictation: model.dictation, interaction: interaction))
        menuHost.sizingOptions = []
        menuPanel.contentView = menuHost
        menuPanel.setAccessibilityLabel("Styles for this dictation")

        host.rootView = root(maxLines: PillView.defaultMaxLines)
        interaction.onMenuChange = { [weak self] open in self?.menuChanged(open) }
    }

    private func root(maxLines: Int) -> PillRoot {
        PillRoot(dictation: dictation, maxLines: maxLines, interaction: interaction) { [weak model] in
            guard let model, let host = URL(string: model.settings.settings.remoteUrl)?.host() else { return nil }
            return PillPresentation.shortHostName(host)
        }
    }

    func update(for phase: DictationController.Phase) {
        hideWork?.cancel()
        if !phase.isListening { interaction.closeMenu() }
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
        }
        // Also when a new dictation starts during the fade-out, which stopped the tracking.
        startMouseTracking()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
    }

    private func hide() {
        stopMouseTracking()
        interaction.closeMenu()
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
        let origin = NSPoint(x: visible.midX - Self.size.width / 2, y: visible.minY + 43 - Self.shadowRoom)
        panel.setFrameOrigin(origin)
        let lines = visible.height < Self.smallScreenHeight ? 3 : PillView.defaultMaxLines
        if host.rootView.maxLines != lines { host.rootView = root(maxLines: lines) }
    }

    // MARK: The mouse

    /// The panel ignores the mouse, so clicks and scrolls go to the app underneath, except while
    /// the pointer is over the pill when it has buttons (listening, Retry) or text to scroll. It
    /// still never becomes key or activates the app (`PillPanel`), so the person's app keeps the
    /// keyboard focus and the text is inserted there. Mouse moves arrive by event monitors and,
    /// as the pointer may rest without moving, a light 20 Hz check while the pill is up.
    private func startMouseTracking() {
        guard mouseMonitors.isEmpty else { return }
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .scrollWheel]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events.union(.leftMouseDown), handler: { [weak self] event in
            MainActor.assumeIsolated {
                // A click in another app closes a menu that was opened with a click.
                if event.type == .leftMouseDown { self?.interaction.closeMenu() }
                self?.updateMouse()
            }
        }) {
            mouseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.updateMouse() }
            return event
        }) {
            mouseMonitors.append(local)
        }
        poll = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMouse() }
        }
        updateMouse()
    }

    private func stopMouseTracking() {
        mouseMonitors.forEach(NSEvent.removeMonitor)
        mouseMonitors.removeAll()
        poll?.invalidate()
        poll = nil
        panel.ignoresMouseEvents = true
        interaction.chipHovered = false
        hoverSince = nil
        awaySince = nil
    }

    /// A frame from the pill (hosting-view coordinates, top-left origin) on screen.
    private func onScreen(_ frame: CGRect) -> NSRect {
        NSRect(x: panel.frame.minX + frame.minX, y: panel.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
    }

    /// Where the pointer is (a stand-in in the demo, which can't move the real one).
    private var pointer: NSPoint {
        #if DEBUG
        if let debugPointer { return debugPointer }
        #endif
        return NSEvent.mouseLocation
    }

    private func updateMouse() {
        let mouse = pointer
        let tracking = !mouseMonitors.isEmpty && panel.isVisible
        let capsule = onScreen(interaction.capsuleFrame)
        let wantsMouse = interaction.capsuleTakesMouse || interaction.scrollable
        let over = tracking && wantsMouse && capsule.contains(mouse)
        if panel.ignoresMouseEvents == over { panel.ignoresMouseEvents = !over }

        // The style chip: resting on it opens the menu.
        let chip = interaction.chipFrame.map(onScreen)
        let onChip = tracking && dictation.phase.isListening && (chip?.contains(mouse) ?? false)
        if interaction.chipHovered != onChip { interaction.chipHovered = onChip }
        if !onChip { interaction.hoverSuppressed = false }
        if onChip, !interaction.hoverSuppressed {
            hoverSince = hoverSince ?? Date()
            if !interaction.menuOpen, let since = hoverSince, Date().timeIntervalSince(since) >= Self.hoverDelay {
                interaction.openMenu(byHover: true)
            }
        } else {
            hoverSince = nil
        }

        // A menu the pointer opened closes when the pointer has left the chip, the menu and
        // the way between them.
        guard interaction.menuOpen, interaction.openedByHover, let chip else {
            awaySince = nil
            return
        }
        let menu = menuPanel.frame.insetBy(dx: Self.menuShadowRoom - 2, dy: Self.menuShadowRoom - 2)
        let bridge = NSRect(x: min(chip.minX, menu.minX), y: chip.minY, width: max(chip.maxX, menu.maxX) - min(chip.minX, menu.minX),
                            height: max(0, menu.minY - chip.minY) + 1)
        let inside = chip.insetBy(dx: -4, dy: -4).contains(mouse) || menu.contains(mouse) || bridge.contains(mouse)
        if inside {
            awaySince = nil
        } else {
            awaySince = awaySince ?? Date()
            if let since = awaySince, Date().timeIntervalSince(since) >= Self.leaveDelay { interaction.closeMenu() }
        }
    }

    // MARK: The style menu

    private func menuChanged(_ open: Bool) {
        awaySince = nil
        guard open else {
            if menuPanel.isVisible {
                panel.removeChildWindow(menuPanel)
                menuPanel.orderOut(nil)
            }
            return
        }
        guard let chipFrame = interaction.chipFrame else { interaction.closeMenu(); return }
        let root = StyleMenuRoot(dictation: dictation, interaction: interaction)
        menuHost.rootView = root
        // The hosting view doesn't size itself (`sizingOptions` is empty), so measure the content.
        let size = NSHostingController(rootView: root).sizeThatFits(in: NSSize(width: 600, height: 2000))
        guard size.width > 0, size.height > 0 else { interaction.closeMenu(); return }
        let chip = onScreen(chipFrame)
        let capsule = onScreen(interaction.capsuleFrame)
        let screen = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        // Above the pill, its left edge under the chip's.
        var x = chip.minX - 4 - Self.menuShadowRoom
        x = min(max(x, screen.minX), screen.maxX - size.width)
        let y = capsule.maxY + 6 - Self.menuShadowRoom
        menuPanel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        menuHost.frame = NSRect(origin: .zero, size: size)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        menuPanel.alphaValue = reduceMotion ? 1 : 0
        panel.addChildWindow(menuPanel, ordered: .above)
        menuPanel.orderFrontRegardless()
        if !reduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Motion.fastDuration
                menuPanel.animator().alphaValue = 1
            }
        }
        NSAccessibility.post(element: menuPanel, notification: .created)
    }

    #if DEBUG
    /// `--pill-demo-paste` without Accessibility: the pointer as the demo moves it.
    var debugPointer: NSPoint? {
        didSet { updateMouse() }
    }
    var debugPanel: NSPanel { panel }
    var debugMenuPanel: NSPanel { menuPanel }

    /// `--pill-demo`: where the pill is on screen (bottom-left origin), whether the panel takes
    /// the mouse, whether the menu is open, and focus.
    var debugDescription: String {
        let frame = onScreen(interaction.capsuleFrame)
        return "pill frame=\(NSStringFromRect(frame)) takesMouse=\(!panel.ignoresMouseEvents) menu=\(interaction.menuOpen) "
            + "key=\(panel.isKeyWindow || menuPanel.isKeyWindow) active=\(NSApp.isActive)"
    }

    /// The chip's centre and a menu row's centre on screen, for the demo's pointer.
    var debugChipCentre: NSPoint? {
        interaction.chipFrame.map { let r = onScreen($0); return NSPoint(x: r.midX, y: r.midY) }
    }
    #endif
}
