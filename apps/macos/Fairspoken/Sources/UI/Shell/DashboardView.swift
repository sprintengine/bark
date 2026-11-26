import FairspokenCore
import FairspokenUI
import FairspokenUpdates
import SwiftUI

/// The main window: the dictation history as a thread list down the left, and the main area
/// beside it under a breadcrumb top bar. Both sit on the same opaque true-black (or near-white)
/// ground, divided by one hairline. The sidebar collapses with its button, View › Hide Sidebar
/// or ⌃⌘S. With nothing selected the main area is Home, the new-dictation screen; a selected row
/// opens that dictation; Models, Post-training and Settings come from the sidebar's foot.
struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let sidebarWidth: CGFloat = 276

    var body: some View {
        HStack(spacing: 0) {
            if model.sidebarVisible {
                HistorySidebar()
                    .frame(width: Self.sidebarWidth)
                    .frame(maxHeight: .infinity)
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(Crystal.hairline).frame(width: 1)
                    }
                    .transition(.move(edge: .leading))
            }
            VStack(spacing: 0) {
                TopBar()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .updateToast(model.updates, style: .client)
        }
        // The top bar and the sidebar's header take the title bar's place, beside the traffic lights.
        .ignoresSafeArea(.container, edges: .top)
        .background(PlainBackground())
        .environment(\.surfaceStyle, .plain)
        .tint(Crystal.primary)
        .animation(Motion.unlessReduced(Motion.normal, reduceMotion), value: model.sidebarVisible)
        .screenshotActive()
        .frame(minWidth: 960, minHeight: 640)
        .overlay {
            if model.paletteOpen {
                CommandPalette().transition(.opacity)
            }
        }
        .animation(Motion.unlessReduced(Motion.fast, reduceMotion), value: model.paletteOpen)
        .background {
            // ⌘K: the search-and-commands palette.
            Button("Search and Commands") { model.paletteOpen.toggle() }
                .keyboardShortcut("k", modifiers: .command)
                .hidden()
                .accessibilityHidden(true)
            // ⌘F: the thread list's own search field.
            Button("Find") {
                if !model.sidebarVisible { model.sidebarVisible = true }
                model.searchFocusPending = true
            }
            .keyboardShortcut("f", modifiers: .command)
            .hidden()
            .accessibilityHidden(true)
        }
        .onAppear { if model.settings.settings.transcriptionLocation == .remoteHost { model.hostStatus.refresh() } }
        // On the dashboard rather than Home, so moving to another section never drops the test
        // without ending it.
        .sheet(isPresented: Binding(get: { model.speedTest.isPresented }, set: { model.speedTest.isPresented = $0 })) {
            SpeedTestSheet().environment(model)
        }
    }

    @ViewBuilder private var detail: some View {
        Group {
            switch model.section {
            case .home:
                if let item = model.history.item(model.selectedDictationID) {
                    DictationDetailView(item: item).id(item.id)
                } else {
                    HomeView()
                }
            case .models: ModelsView()
            case .training: PostTrainingView()
            case .settings: SettingsView()
            }
        }
        .transition(.opacity)
        .animation(Motion.unlessReduced(Motion.fast, reduceMotion), value: model.section)
    }
}

extension AppModel.Section {
    /// Its key with ⌘ (View menu): 1 for Home through 4 for Settings.
    var shortcutNumber: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }

    /// The section's glyph at the sidebar's foot.
    var sidebarSymbol: String {
        switch self {
        case .home: "house"
        case .models: "square.3.layers.3d"
        case .training: "waveform.path.ecg"
        case .settings: "slider.horizontal.3"
        }
    }
}

/// Room for the traffic lights at the window's top leading corner.
enum WindowChrome {
    /// Where the first control after the traffic lights starts.
    static let afterLights: CGFloat = 90
}

// MARK: - Top bar

/// The main area's top bar: where you are as a breadcrumb, and the tools for that screen (the
/// microphone on Home; the actions card's toggle on a dictation). Dragging its empty space moves
/// the window, as a title bar does.
private struct TopBar: View {
    @Environment(AppModel.self) private var model
    @AppStorage("DictationPanelHidden") private var panelHidden = false

    var body: some View {
        HStack(spacing: 10) {
            if !model.sidebarVisible {
                SidebarToggle().padding(.leading, WindowChrome.afterLights - 24)
            }
            Breadcrumb()
            Spacer(minLength: 12)
            tools
        }
        .padding(.leading, model.sidebarVisible ? 24 : 0)
        .padding(.trailing, 12)
        .frame(height: Layout.topBar)
        .background {
            Color.clear.contentShape(.rect).gesture(WindowDragGesture())
        }
    }

    @ViewBuilder private var tools: some View {
        switch model.section {
        case .home:
            if model.history.item(model.selectedDictationID) != nil {
                IconButton(symbol: "sidebar.right", label: panelHidden ? "Show actions" : "Hide actions", on: !panelHidden) {
                    panelHidden.toggle()
                }
            } else {
                MicPicker()
            }
        default:
            EmptyView()
        }
    }
}

/// "Home", "Mail / Revised quote for Aoife", "Settings / Transcription".
private struct Breadcrumb: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            switch model.section {
            case .home:
                if let item = model.history.item(model.selectedDictationID) {
                    AppMonogram(appName: DictationText.monogramName(item), bundleID: item.appBundleId, isNote: item.isBarkNote, size: 20)
                    Button(DictationText.appName(item)) { model.open(dictation: nil) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Crystal.ink2)
                        .help("Back to Home (esc)")
                    separator
                    Text(DictationText.title(item)).foregroundStyle(Crystal.ink).fontWeight(.medium)
                        .lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: 440, alignment: .leading)
                } else {
                    current("Home")
                }
            case .settings:
                Button("Settings") { model.settingsTab = .general }.buttonStyle(.plain).foregroundStyle(Crystal.ink2)
                separator
                current(model.settingsTab.title)
            default:
                current(model.section.title)
            }
        }
        .font(.system(size: 15))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var separator: some View {
        Text("/").foregroundStyle(Crystal.ink3.opacity(0.6)).accessibilityHidden(true)
    }

    private func current(_ title: String) -> some View {
        Text(title).fontWeight(.medium).foregroundStyle(Crystal.ink).lineLimit(1)
    }
}

/// The sidebar's button, beside the traffic lights.
struct SidebarToggle: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        IconButton(symbol: "sidebar.left", label: model.sidebarVisible ? "Hide sidebar" : "Show sidebar",
                   help: model.sidebarVisible ? "Hide sidebar (⌃⌘S)" : "Show sidebar (⌃⌘S)") {
            model.sidebarVisible.toggle()
        }
    }
}

// MARK: - Microphone

/// The microphone dictation listens on: an outline button that opens the list.
struct MicPicker: View {
    @Environment(AppModel.self) private var model
    @State private var names: [String] = []
    @State private var hovered = false

    var body: some View {
        let current = model.settings.settings.audioDevice
        Menu {
            Picker("Microphone", selection: Binding(get: { current }, set: { v in model.settings.update { $0.audioDevice = v } })) {
                Text("System default\(Microphones.defaultName().map { " (\($0))" } ?? "")").tag("")
                ForEach(names, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Audio Settings…") { model.settingsTab = .audio; model.section = .settings }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "mic").font(.system(size: 12)).foregroundStyle(Crystal.ink2)
                Text(Microphones.displayName(for: current)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Crystal.ink2)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Crystal.ink)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(hovered ? Crystal.rowHover : Crystal.well, in: .rect(cornerRadius: Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Crystal.input))
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovered = $0 }
        .help("Microphone")
        .accessibilityLabel("Microphone, \(Microphones.displayName(for: current))")
        .onAppear { names = Microphones.names() }
    }
}

extension UpdateStyle {
    /// The client's blue, with the warning colour.
    static let client = UpdateStyle(accent: Crystal.primary, warning: Crystal.warn)
}
