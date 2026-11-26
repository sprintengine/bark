import FairspokenUI
import FairspokenUpdates
import AppKit
import FairspokenCore
import KeyboardShortcuts
import SwiftUI

/// Menu-bar item. A native menu (keyboard navigation, VoiceOver, the system's look), led by two
/// views of Bark's own: the status (model, ready or listening, how to dictate) and the last
/// dictation with a copy button. Then dictating and pasting the last dictation again with their
/// shortcuts, the microphone and where transcription runs, the window, Settings, and Quit.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let model: AppModel
    private let windows: WindowCoordinator
    private let menu = NSMenu()
    private let headerItem = NSMenuItem()
    private let lastItem = NSMenuItem()
    private let toggleItem = NSMenuItem(title: "Start Dictation", action: #selector(toggleDictation), keyEquivalent: "")
    private let pasteLastItem = NSMenuItem(title: "Paste Last Dictation", action: #selector(pasteLast), keyEquivalent: "")
    private let pendingItem = NSMenuItem(title: "", action: #selector(openHome), keyEquivalent: "")
    private let microphoneItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
    private let locationItem = NSMenuItem(title: "Transcribe On", action: nil, keyEquivalent: "")
    private let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(updateAction), keyEquivalent: "")
    static let menuWidth: CGFloat = 300
    private var headerRoot = AnyView(EmptyView())
    private var lastRoot = AnyView(EmptyView())

    init(model: AppModel, windows: WindowCoordinator) {
        self.model = model
        self.windows = windows
        super.init()
        item.button?.setAccessibilityLabel(AppInfo.displayName)
        buildMenu()
        item.menu = menu
        update(for: .idle)
    }

    private func buildMenu() {
        menu.delegate = self
        menu.minimumWidth = Self.menuWidth
        headerRoot = AnyView(StatusMenuHeader().environment(model))
        lastRoot = AnyView(LastDictationCard(onCopy: { [weak self] in self?.copyLast() }).environment(model))
        headerItem.view = Self.hosting(headerRoot)
        headerItem.setAccessibilityElement(true)
        menu.addItem(headerItem)
        lastItem.view = Self.hosting(lastRoot)
        menu.addItem(lastItem)
        menu.addItem(.separator())

        toggleItem.target = self
        toggleItem.image = Self.symbol("waveform")
        toggleItem.setShortcut(for: .dictation)
        menu.addItem(toggleItem)
        pasteLastItem.target = self
        pasteLastItem.image = Self.symbol("doc.on.clipboard")
        pasteLastItem.setShortcut(for: .pasteLast)
        menu.addItem(pasteLastItem)
        pendingItem.target = self
        pendingItem.image = Self.symbol("clock.arrow.circlepath")
        menu.addItem(pendingItem)
        menu.addItem(.separator())

        microphoneItem.image = Self.symbol("mic")
        microphoneItem.submenu = NSMenu(title: "Microphone")
        menu.addItem(microphoneItem)
        locationItem.image = Self.symbol("laptopcomputer")
        locationItem.submenu = NSMenu(title: "Transcribe On")
        menu.addItem(locationItem)
        menu.addItem(.separator())

        // Every row carries a symbol, so the titles line up down the whole menu.
        menu.addItem(entry("Open \(AppInfo.displayName)", #selector(openHome), "o", symbol: "macwindow"))
        menu.addItem(entry("Settings…", #selector(openSettings), ",", symbol: "gearshape"))
        updateItem.target = self
        updateItem.image = Self.symbol("arrow.triangle.2.circlepath")
        menu.addItem(updateItem)
        menu.addItem(.separator())
        menu.addItem(entry("Quit \(AppInfo.displayName)", #selector(quit), "q", symbol: "power"))
    }

    private func entry(_ title: String, _ action: Selector, _ key: String, symbol: String? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        if let symbol { i.image = Self.symbol(symbol) }
        return i
    }

    private static func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }

    /// A view for a menu item: as wide as the menu (it stretches with it), as tall as it needs
    /// at the menu's narrowest.
    private static func hosting(_ view: AnyView) -> NSView {
        let host = NSHostingView(rootView: view.frame(minWidth: menuWidth, maxWidth: .infinity, alignment: .leading))
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: menuWidth, height: height(of: view))
        host.autoresizingMask = [.width]
        return host
    }

    /// The view's height at the menu's narrowest (a hosting view that doesn't size itself
    /// can't be asked for it).
    private static func height(of view: AnyView) -> CGFloat {
        ceil(NSHostingController(rootView: view.frame(width: menuWidth)).sizeThatFits(in: NSSize(width: menuWidth, height: 1000)).height)
    }

    func update(for phase: DictationController.Phase) {
        let symbol: String?
        switch phase {
        case .listening: symbol = "mic.fill"
        case .transcribing: symbol = "ellipsis.circle"
        case .failed: symbol = "exclamationmark.triangle"
        default: symbol = nil
        }
        // At rest, the sheepdog: the app icon's markings knocked out of a tile, one colour so
        // the menu bar can tint it.
        let image = symbol.map { NSImage(systemSymbolName: $0, accessibilityDescription: AppInfo.displayName) }
            ?? NSImage(named: "MenuBarMark")
        image?.accessibilityDescription = AppInfo.displayName
        image?.isTemplate = true
        item.button?.image = image
        item.button?.contentTintColor = phase.isListening ? NSColor(Crystal.live) : nil
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        // The menu shows these shortcuts as its own key equivalents; while it tracks, the global
        // hot keys would be held and fire again once it closes.
        KeyboardShortcuts.disable(.dictation); KeyboardShortcuts.disable(.pasteLast)
        refresh()
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        KeyboardShortcuts.enable(.dictation); KeyboardShortcuts.enable(.pasteLast)
    }

    /// Brings every item up to date (also before a screenshot).
    func refresh() {
        let listening = model.dictation.phase.isListening
        toggleItem.title = listening ? "Stop Dictation" : "Start Dictation"
        toggleItem.image = Self.symbol(listening ? "stop.circle" : "waveform")
        pasteLastItem.isEnabled = model.lastDictation != nil
        lastItem.isHidden = model.lastDictation == nil
        // The views' heights follow their content (the last dictation's text wraps to two lines).
        headerItem.view?.frame.size.height = Self.height(of: headerRoot)
        lastItem.view?.frame.size.height = Self.height(of: lastRoot)
        let waiting = model.pending.items.count
        pendingItem.isHidden = waiting == 0
        pendingItem.title = waiting == 1 ? "1 Dictation Not Transcribed Yet…" : "\(waiting) Dictations Not Transcribed Yet…"
        microphoneItem.attributedTitle = Self.titled("Microphone", detail: Microphones.displayName(for: model.settings.settings.audioDevice))
        let remote = model.settings.settings.transcriptionLocation == .remoteHost
        locationItem.attributedTitle = Self.titled("Transcribe On", detail: remote ? "Bark Server" : "This Mac")
        rebuildMicrophones()
        rebuildLocations()
        let update = model.updates.presentation
        updateItem.title = update.menuTitle
        updateItem.setAccessibilityLabel(update.accessibilityLabel)
    }

    /// "Microphone   MacBook Pro Microphone": the setting in the secondary colour.
    private static func titled(_ title: String, detail: String) -> NSAttributedString {
        let s = NSMutableAttributedString(string: title, attributes: [.font: NSFont.menuFont(ofSize: 0)])
        s.append(NSAttributedString(string: "   " + detail, attributes: [.font: NSFont.menuFont(ofSize: 0),
                                                                          .foregroundColor: NSColor.secondaryLabelColor]))
        return s
    }

    private func rebuildMicrophones() {
        guard let sub = microphoneItem.submenu else { return }
        sub.removeAllItems()
        let current = model.settings.settings.audioDevice
        let system = NSMenuItem(title: "System Default\(Microphones.defaultName().map { " (\($0))" } ?? "")",
                                action: #selector(chooseMicrophone(_:)), keyEquivalent: "")
        system.representedObject = ""
        system.state = current.isEmpty ? .on : .off
        system.target = self
        sub.addItem(system)
        for name in Microphones.names() {
            let i = NSMenuItem(title: name, action: #selector(chooseMicrophone(_:)), keyEquivalent: "")
            i.representedObject = name
            i.state = name == current ? .on : .off
            i.target = self
            sub.addItem(i)
        }
    }

    private func rebuildLocations() {
        guard let sub = locationItem.submenu else { return }
        sub.removeAllItems()
        let s = model.settings.settings
        let here = NSMenuItem(title: "This Mac", action: #selector(chooseLocation(_:)), keyEquivalent: "")
        here.representedObject = TranscriptionLocation.local.rawValue
        here.state = s.transcriptionLocation == .local ? .on : .off
        here.target = self
        sub.addItem(here)
        let hasServer = !s.remoteUrl.trimmingCharacters(in: .whitespaces).isEmpty
        let server = NSMenuItem(title: hasServer ? "Bark Server (\(model.hostStatus.hostName))" : "Bark Server",
                                action: hasServer ? #selector(chooseLocation(_:)) : nil, keyEquivalent: "")
        server.representedObject = TranscriptionLocation.remoteHost.rawValue
        server.state = s.transcriptionLocation == .remoteHost ? .on : .off
        server.target = self
        sub.addItem(server)
        sub.addItem(.separator())
        sub.addItem(entry("Transcription Settings…", #selector(openTranscriptionSettings), ""))
    }

    // MARK: Actions

    @objc private func toggleDictation() { model.dictation.toggleFromUI() }
    /// The menu never brings Bark forward, so the app in front is the one to paste into.
    @objc private func pasteLast() { model.pasteLast() }
    @objc private func openHome() { windows.showDashboard(.home) }
    @objc private func openSettings() { windows.showDashboard(.settings) }
    @objc private func openTranscriptionSettings() {
        model.settingsTab = .transcription
        windows.showDashboard(.settings)
    }

    @objc private func chooseMicrophone(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        model.settings.update { $0.audioDevice = name }
    }

    @objc private func chooseLocation(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let location = TranscriptionLocation(rawValue: raw) else { return }
        model.settings.update { $0.transcriptionLocation = location }
        if location == .remoteHost { model.hostStatus.refresh() }
    }

    private func copyLast() {
        guard let last = model.lastDictation else { return }
        TextInserter.copy(last.text)
        menu.cancelTracking()
    }

    /// Check, install or restart, by state; the window shows the progress and the answer.
    @objc private func updateAction() {
        windows.showDashboard()
        model.updates.performPrimaryAction()
    }
    @objc private func quit() { NSApp.terminate(nil) }

    /// Screenshots: the menu itself, to pop up in a window of Bark's own.
    var screenshotMenu: NSMenu { menu }
}

extension StatusItemController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem == updateItem { return model.updates.presentation.isEnabled }
        if menuItem == pasteLastItem { return model.lastDictation != nil && !model.dictation.phase.isActive }
        return true
    }
}

// MARK: - Views in the menu

/// "Bark is ready · Parakeet v3 on this Mac", with how to dictate on the right.
private struct StatusMenuHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            BrandMark(size: 22)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    if model.dictation.phase.isListening {
                        Circle().fill(Crystal.recording).frame(width: 7, height: 7)
                    }
                    Text(status).font(.system(size: 13, weight: .semibold)).foregroundStyle(Crystal.ink)
                }
                Text(detail).font(.system(size: 12)).foregroundStyle(Crystal.ink2).lineLimit(1)
            }
            Spacer(minLength: 8)
            Keycap(label: model.settings.settings.fnPushToTalk ? "fn" : HotkeyController.currentShortcutSymbols, outline: true)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
    }

    private var status: String {
        switch model.dictation.phase {
        case .listening: return "Listening"
        case .transcribing: return "Transcribing"
        default: break
        }
        if model.settings.settings.transcriptionLocation == .remoteHost {
            switch model.hostStatus.state {
            case .failed: return "Bark Server isn't answering"
            case .checking: return "Checking Bark Server"
            default: return "\(AppInfo.displayName) is ready"
            }
        }
        switch model.models.engineState {
        case .ready: return "\(AppInfo.displayName) is ready"
        case .failed: return "The model didn't load"
        case .idle: return "\(AppInfo.displayName) is ready"
        default: return "Getting the model ready"
        }
    }

    private var detail: String {
        if model.settings.settings.transcriptionLocation == .remoteHost { return "On \(model.hostStatus.hostName)" }
        return "\(model.models.activeModel.shortName) on this Mac"
    }
}

/// The newest dictation: where it went and when, its words (two lines), and copy.
private struct LastDictationCard: View {
    @Environment(AppModel.self) private var model
    var onCopy: () -> Void
    @State private var hovered = false

    /// The words on one run of lines, from the line the title starts at (past a greeting).
    static func preview(_ item: TranscriptHistoryItem) -> String {
        let lines = item.text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let title = DictationText.title(item)
        let start = lines.firstIndex(of: title) ?? 0
        return lines[start...].joined(separator: " ")
    }

    /// "2m ago", "just now".
    static func age(_ date: Date) -> String {
        let age = DictationText.age(date)
        return age == "now" ? "just now" : "\(age) ago"
    }

    var body: some View {
        if let item = model.lastDictation {
            Button(action: onCopy) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        AppMonogram(appName: DictationText.monogramName(item), bundleID: item.appBundleId)
                        Text("\(DictationText.appName(item)) · \(Self.age(item.date))")
                            .font(.system(size: 12)).foregroundStyle(Crystal.ink3).lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11.5))
                            .foregroundStyle(hovered ? Crystal.ink : Crystal.ink2)
                            .frame(width: 22, height: 22)
                            .background(hovered ? Crystal.rowHover : .clear, in: .rect(cornerRadius: 6, style: .continuous))
                    }
                    Text(Self.preview(item))
                        .font(.system(size: 13))
                        .foregroundStyle(Crystal.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 9)
                .background(Crystal.ink.opacity(hovered ? 0.07 : 0.04), in: .rect(cornerRadius: 6, style: .continuous))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .padding(.horizontal, 5)
            .padding(.bottom, 4)
            .help("Copy the last dictation")
            .accessibilityLabel("Last dictation, \(DictationText.appName(item)): \(item.text)")
            .accessibilityHint("Copies it")
        }
    }
}
