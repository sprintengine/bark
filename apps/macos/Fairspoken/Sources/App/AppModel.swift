import FairspokenSpeech
import FairspokenWhisper
import FairspokenUpdates
import AppKit
import FairspokenCore
import Observation

/// Composition root shared by every window, the menu bar item and the pill.
@Observable
final class AppModel {
    enum Section: String, CaseIterable, Identifiable {
        case home, models, training, settings
        var id: String { rawValue }
        var title: String {
            switch self {
            case .home: "Home"
            case .models: "Models"
            case .training: "Post-training"
            case .settings: "Settings"
            }
        }
        var symbol: String {
            switch self {
            case .home: "house.fill"
            case .models: "square.stack.3d.up.fill"
            case .training: "waveform.badge.mic"
            case .settings: "gearshape.fill"
            }
        }
    }

    var section: Section = .home {
        didSet {
            if section != .home { selectedDictationID = nil }
            if section != .settings { settingsQuery = "" }
        }
    }
    /// The dictation open in the main area (a row of the sidebar's thread list). Nil is Home,
    /// the new-dictation screen.
    var selectedDictationID: String?
    /// The thread list's search text and filter.
    var historyQuery = ""
    var historyFilter: HistoryFilter = .all
    /// Set by ⌘K; the sidebar's search field takes the focus and clears it (also when the sidebar
    /// was hidden and the field appears only now).
    var searchFocusPending = false
    /// "Paste last dictation" is under way (a second press waits for it to finish).
    @ObservationIgnored var pastingLast = false
    /// The ⌘K palette is open over the main window.
    var paletteOpen = false
    /// Screenshots: the palette opened with this query typed.
    var showcasePaletteQuery: String?
    /// Home's composer: what's typed there and the dictations made into it, kept while you look
    /// at other screens.
    var homeDraft = ""
    var homeDraftSources: [String] = []
    /// Screenshots: the thread row drawn as if under the pointer.
    var showcaseHoveredRow: String?
    /// Bumped to start editing the open dictation's text (⏎ in the thread list).
    var editRequest = 0
    /// Dictations being transcribed again from their kept recording.
    var retryingDictations: Set<String> = []
    /// What the last action on a dictation did ("Copied", "Pasted into Mail"), shown briefly.
    var dictationNotice: String?

    enum HistoryFilter: String, CaseIterable, Identifiable {
        case all, notes, clipboard
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "All dictations"
            case .notes: "Notes"
            case .clipboard: "Copied to the clipboard"
            }
        }
    }

    /// Opens a dictation from the thread list (or Home, with nil).
    func open(dictation id: String?) {
        if section != .home { section = .home }
        selectedDictationID = id
    }
    /// The main window's sidebar is shown (View › Show Sidebar, ⌃⌘S, or the toolbar's sidebar
    /// button). Remembered across launches.
    var sidebarVisible = !UserDefaults.standard.bool(forKey: "SidebarHidden") {
        didSet { UserDefaults.standard.set(!sidebarVisible, forKey: "SidebarHidden") }
    }
    /// The settings page. Going to a page leaves any settings search.
    var settingsTab: SettingsView.Tab = .general {
        didSet { settingsQuery = "" }
    }
    /// The settings sidebar's search: every matching row from every page.
    var settingsQuery = ""
    /// Set by ⌘F in Settings; the settings search field takes the focus and clears it.
    var settingsSearchFocusPending = false
    /// Settings › App styles: the app or site whose preview is open, and the add sheet.
    var appStylesOpenRow: String?
    var appStylesAddPresented = false

    let settings: SettingsStore
    let history: HistoryStore
    let training: TrainingLibrary
    let pending: PendingDictations
    let learned: LearnedLibrary
    @ObservationIgnored let editWatcher: EditWatcher
    let permissions: Permissions
    let models: ModelLibrary
    let dictation: DictationController
    let micTest: MicTest
    let speedTest: SpeedTestController
    let hostStatus: HostStatus
    let hostFinder: HostFinder
    let updates: UpdateController
    @ObservationIgnored let hotkeys: HotkeyController

    @ObservationIgnored var openDashboard: ((Section?) -> Void)?
    @ObservationIgnored var openOnboarding: (() -> Void)?

    init() {
        settings = SettingsStore()
        // Before anything can download.
        ParakeetModels.setLinks(settings.settings.modelLinks)
        history = HistoryStore()
        training = TrainingLibrary(settings: settings)
        learned = LearnedLibrary(settings: settings)
        editWatcher = EditWatcher(settings: settings)
        permissions = Permissions()
        models = ModelLibrary()
        pending = PendingDictations(settings: settings, models: models, history: history, training: training)
        dictation = DictationController(settings: settings, models: models, history: history, permissions: permissions,
                                        pending: pending)
        micTest = MicTest(capture: dictation.capture)
        speedTest = SpeedTestController(dictation: dictation, history: history)
        hostStatus = HostStatus(settings: settings)
        // A model that failed to load leaves the previous one in use; the saved choice follows it.
        models.onFallback = { [weak settings] id in settings?.update { $0.model = id } }
        models.isDictating = { [weak dictation] in dictation?.phase.isActive ?? false }
        hostFinder = HostFinder(settings: settings, hostStatus: hostStatus)
        var updateConfig = UpdateController.Configuration(appName: AppInfo.displayName, version: AppInfo.version, build: AppInfo.build)
        #if DEBUG
        updateConfig.feedOverride = UpdateController.Configuration.debugFeedOverride()
        #endif
        updates = UpdateController(configuration: updateConfig)
        hotkeys = HotkeyController()
        dictation.hotkeys = hotkeys
        dictation.editWatcher = editWatcher
        editWatcher.onFix = { [weak learned] fix, model in learned?.learn(fix, model: model) }
        editWatcher.onEdit = { [weak training] id, edited in training?.attachEdit(id, edited: edited) }

        // Carry an imported Tauri shortcut over once (KeyboardShortcuts owns it afterwards).
        if settings.importedFromTauri { HotkeyController.adoptAccelerator(settings.settings.recordingShortcut) }

        // Every recording takes the microphone from the setup guide's test.
        dictation.onWillStart = { [weak self] in self?.micTest.stop() }
        // In Bark's own window, a dictation is a note only on Home, where its composer takes it.
        dictation.shownInAppIsNote = { [weak self] in
            guard let self else { return false }
            return self.section == .home && self.selectedDictationID == nil
                && NSApp.keyWindow?.identifier == NSUserInterfaceItemIdentifier("dashboard")
        }
        hotkeys.onPress = { [weak self] in self?.dictation.hotkeyPressed() }
        hotkeys.onRelease = { [weak self] in self?.dictation.hotkeyReleased() }
        hotkeys.onCancel = { [weak self] in self?.dictation.cancel() }
        hotkeys.onFnPress = { [weak self] in self?.dictation.fnPressed() }
        hotkeys.onFnRelease = { [weak self] in self?.dictation.fnReleased() }
        hotkeys.onPasteLast = { [weak self] in self?.pasteLast() }

        pending.onRecovered = { [weak self] words, copied, placement in
            self?.dictation.announceRecovered(words: words, copied: copied, placement: placement)
        }
        // The host answering again is the moment to send it what it missed.
        hostStatus.onConnected = { [weak self] in
            Task { await self?.pending.retryAll(manual: false) }
        }
    }

    /// Launch-time work: warm the engine so the first dictation is instant, start Fn if enabled.
    func startServices() {
        if settings.settings.transcriptionLocation != .remoteHost || SpeechModels.isInstalled(settings.settings.model) {
            models.use(settings.settings.model)
        }
        applyFnSetting()
        pending.start()
        if settings.settings.transcriptionLocation == .remoteHost { hostStatus.refresh() }
        #if DEBUG
        // -FAIRSPOKEN_UPDATE_STATE available|checking|downloading|ready|error|idle shows that state
        // without Sparkle (README › Updates).
        if updates.simulateFromDefaults() { return }
        #endif
        updates.start()
    }

    func applyFnSetting() {
        if settings.settings.fnPushToTalk {
            permissions.refresh()
            hotkeys.setFnEnabled(true)
        } else {
            hotkeys.setFnEnabled(false)
        }
    }

    /// The model whose detail sheet is open in the Models library.
    var modelDetailID: String?

    /// Makes `id` the dictation model: saved in settings, then downloaded if needed (a tracked,
    /// cancellable library download) and loaded once no dictation is running
    /// (`ModelLibrary.use`). With a network device chosen it is still loaded, ready for when
    /// dictation is local again.
    func useModel(_ id: String) {
        guard SpeechModelCatalog.model(id: id) != nil else { return }
        settings.update { $0.model = id }
        models.use(id)
    }

    /// Stars or unstars a model in the Models library (favourites are listed first).
    func toggleFavourite(_ id: String) {
        settings.update { s in
            if let i = s.favoriteModels.firstIndex(of: id) { s.favoriteModels.remove(at: i) } else { s.favoriteModels.append(id) }
        }
    }

    /// The model whose "Download from Link…" field is open, and what it holds.
    var linkEditorModel: String?
    var linkDraft = ""

    func openLinkEditor(for id: String) {
        linkDraft = settings.settings.modelLinks[id] ?? ""
        linkEditorModel = id
    }

    /// Saves `text` as `id`'s download link and downloads the model from it (the model in use
    /// that failed to load is loaded too). Returns why `text` can't be a link, or nil.
    func downloadFromLink(_ id: String, _ text: String) -> String? {
        let value: String
        do { value = try ModelLink.normalize(text) } catch { return error.localizedDescription }
        settings.update { $0.modelLinks[id] = value }
        ParakeetModels.setLinks(settings.settings.modelLinks)
        linkEditorModel = nil
        models.clearDownloadError(id)
        if id == models.activeModelID, case .failed = models.engineState, settings.settings.transcriptionLocation == .local {
            models.use(id)
        } else {
            models.download(id)
        }
        return nil
    }

    /// Back to the standard download for `id`.
    func removeModelLink(_ id: String) {
        settings.update { $0.modelLinks[id] = nil }
        ParakeetModels.setLinks(settings.settings.modelLinks)
        models.clearDownloadError(id)
    }

    /// Keep `recordingShortcut` in settings.json meaningful for the shared schema.
    func mirrorShortcut() {
        if let accelerator = HotkeyController.currentAccelerator(), accelerator != settings.settings.recordingShortcut {
            settings.update { $0.recordingShortcut = accelerator }
        }
    }

    var needsOnboarding: Bool {
        !UserDefaults.standard.bool(forKey: "onboardingCompleted")
            || !permissions.microphone.isGranted
    }

    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "onboardingCompleted")
    }

    /// Where the chosen speech model is, as the setup guide and Home show it: its tracked library
    /// download (progress, failure), then loading on the engine.
    var modelProgress: SetupGuide.ModelProgress {
        let chosen = SpeechModelCatalog.resolve(settings.settings.model).id
        let engine: SetupGuide.EngineStatus = switch models.engineState {
        case .idle: .idle
        case .downloading(let f): .downloading(f)
        case .unpacking, .compiling, .loading, .warming: .busy
        case .ready: .ready
        case .failed(let message): .failed(message)
        }
        let item: SetupGuide.ItemStatus = switch models.state(of: chosen) {
        case .available: .available
        case .downloading(let f): .downloading(f)
        case .unpacking, .compiling: .preparing
        case .installed: .installed
        }
        return SetupGuide.modelProgress(remote: settings.settings.transcriptionLocation == .remoteHost, chosenID: chosen,
                                        activeID: models.activeModelID, activeName: models.activeModel.shortName,
                                        engine: engine, chosenItem: item, downloadError: models.downloadErrors[chosen])
    }

    static func permission(_ status: Permissions.Status) -> SetupGuide.Permission {
        switch status {
        case .granted: .granted
        case .denied: .denied
        case .notDetermined: .notDetermined
        }
    }

    /// What is set up right now: the microphone, the model, typing into apps (and, in the guide,
    /// whether the microphone test heard anything).
    func setupChecklist(micHeard: Bool? = nil) -> [SetupGuide.ChecklistItem] {
        SetupGuide.checklist(microphone: Self.permission(permissions.microphone), accessibility: permissions.accessibility.isGranted,
                             model: modelProgress, micHeard: micHeard)
    }

    /// Engine summary used across the UI.
    var engineSummary: (title: String, detail: String, placement: ComputePlacement) {
        if settings.settings.transcriptionLocation == .remoteHost {
            let host = URL(string: settings.settings.remoteUrl)?.host() ?? "your host"
            return ("Your transcription host", host, .remoteHost)
        }
        return (models.activeModel.name, "\(models.activeModel.engine.runtime) · Neural Engine · on this device", .neuralEngine)
    }
}
