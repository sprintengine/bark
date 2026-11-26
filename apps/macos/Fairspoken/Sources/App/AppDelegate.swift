import AppKit
import FairspokenUpdates
import OSLog

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel!
    private var windows: WindowCoordinator!
    private var statusItem: StatusItemController!
    private var pill: PillController!
    private var harness: ScreenshotHarness?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if SelfTest.runIfRequested() { return }
        model = AppModel()
        windows = WindowCoordinator(model: model)
        statusItem = StatusItemController(model: model, windows: windows)
        pill = PillController(model: model)
        NSApp.mainMenu = Self.buildMainMenu(target: self)

        model.openDashboard = { [weak self] section in self?.windows.showDashboard(section) }
        model.openOnboarding = { [weak self] in self?.windows.showOnboarding() }
        model.dictation.onPhaseChange = { [weak self] phase in
            self?.pill.update(for: phase)
            self?.statusItem.update(for: phase)
            // A model chosen during the dictation is loaded once it ends.
            if !phase.isActive { self?.model.models.dictationEnded() }
        }
        model.dictation.onNeedsOnboarding = { [weak self] in self?.windows.showOnboarding(reset: false) }

        if let dir = AppInfo.screenshotDirectory {
            harness = ScreenshotHarness(model: model, windows: windows, statusItem: statusItem, output: dir)
            harness?.run()
            return
        }
        #if DEBUG
        if AppInfo.arguments.contains("--pill-demo") || AppInfo.arguments.contains("--pill-demo-paste") {
            PillDemo.run(model: model, pill: pill)
            return
        }
        #endif
        model.startServices()
        if model.needsOnboarding {
            windows.showOnboarding()
        } else if AppInfo.isDemo || AppInfo.arguments.contains("--show-dashboard") {
            windows.showDashboard(.home)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { windows.showDashboard() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        model?.settings.saveNow()
        model?.history.flush()
    }

    @objc func showAbout() {
        windows.showDashboard(.settings)
        model.settingsQuery = ""
        model.settingsTab = .about
    }

    @objc func showSettings() {
        windows.showDashboard(.settings)
    }

    /// View › Home, Models, Post-training, Settings (⌘1…⌘4).
    @objc func showSection(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let section = AppModel.Section(rawValue: raw) else { return }
        windows.showDashboard(section)
    }

    /// App menu › Check for Updates…: opens the window so the answer (a toast) is visible.
    @objc func checkForUpdates() {
        windows.showDashboard()
        model.updates.checkForUpdates()
    }

    private static func buildMainMenu(target: AppDelegate) -> NSMenu {
        let main = NSMenu()
        let name = AppInfo.displayName

        let appMenu = NSMenu(title: name)
        let about = NSMenuItem(title: "About \(name)", action: #selector(showAbout), keyEquivalent: "")
        about.target = target
        appMenu.addItem(about)
        let updates = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updates.target = target
        appMenu.addItem(updates)
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = target
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem(title: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        main.addItem(submenu(appMenu))

        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        edit.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        main.addItem(submenu(edit))

        // View: the sidebar (the main window answers toggleDashboardSidebar:) and the sections, so ⌘1…⌘4
        // work with the sidebar hidden too.
        let view = NSMenu(title: "View")
        let sidebar = NSMenuItem(title: "Hide Sidebar", action: #selector(DashboardWindow.toggleDashboardSidebar(_:)), keyEquivalent: "s")
        sidebar.keyEquivalentModifierMask = [.control, .command]
        view.addItem(sidebar)
        view.addItem(.separator())
        for section in AppModel.Section.allCases {
            let item = NSMenuItem(title: section.title, action: #selector(showSection(_:)), keyEquivalent: "\(section.shortcutNumber)")
            item.target = target
            item.representedObject = section.rawValue
            view.addItem(item)
        }
        main.addItem(submenu(view))

        let window = NSMenu(title: "Window")
        window.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        window.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        return main
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
