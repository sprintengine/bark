import FairspokenUI
import FairspokenCore
import FairspokenUpdates
import SwiftUI

/// Main window: a native sidebar beside a plain ground. The sidebar runs the full height of the
/// window, under the traffic lights, on the system's translucent sidebar material (opaque with
/// Reduce Transparency); it collapses with the toolbar's sidebar button, View › Hide Sidebar or
/// ⌃⌘S. Each screen sets its cards straight on the ground (`SurfaceStyle.plain`): near-black in
/// dark mode, white in light, with pink as the one colour.
struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let sidebarWidth: CGFloat = 228

    var body: some View {
        HStack(spacing: 0) {
            if model.sidebarVisible {
                Sidebar()
                    .frame(width: Self.sidebarWidth)
                    .frame(maxHeight: .infinity)
                    .background(SidebarBackground())
                    // The sidebar's edge: one hairline, as a native sidebar has.
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(Crystal.hairline).frame(width: 1).ignoresSafeArea()
                    }
                    .ignoresSafeArea(edges: [.top, .bottom])
                    .transition(.move(edge: .leading))
            }
            // The content starts under the toolbar and scrolls beneath it.
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .updateToast(model.updates, style: .client)
        }
        .background(PlainBackground())
        .environment(\.surfaceStyle, .plain)
        .animation(Motion.unlessReduced(Motion.normal, reduceMotion), value: model.sidebarVisible)
        .screenshotActive()
        .frame(minWidth: 960, minHeight: 640)
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
            case .home: HomeView()
            case .models: ModelsView()
            case .training: PostTrainingView()
            case .settings: SettingsView()
            }
        }
        .id(model.section)
        .transition(.opacity)
        .animation(Motion.unlessReduced(Motion.normal, reduceMotion), value: model.section)
    }
}

extension AppModel.Section {
    /// The section's glyph in the sidebar, in one neutral colour.
    /// Its key with ⌘ (View menu): 1 for Home through 4 for Settings.
    var shortcutNumber: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }

    var sidebarSymbol: String {
        switch self {
        case .home: "waveform"
        case .models: "square.stack.3d.up"
        case .training: "waveform.badge.mic"
        case .settings: "gearshape"
        }
    }
}

/// The Bark lockup (the dog tile and the Fraunces wordmark) under the traffic lights, the
/// sections as plain rows, and the engine status at the bottom, straight on the sidebar material.
private struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Room for the traffic lights and the toolbar, then the lockup.
            HStack(spacing: 10) {
                BrandMark(size: 30)
                Text(AppInfo.displayName)
                    .font(.barkWordmark(22))
                    .tracking(-0.55)
                    .foregroundStyle(Crystal.ink)
            }
            .padding(.horizontal, 8)
            .padding(.top, 58)
            .padding(.bottom, 18)
            .accessibilityElement(children: .combine)

            VStack(spacing: 2) {
                ForEach(AppModel.Section.allCases) { section in
                    SidebarRow(section: section)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .leading, spacing: 10) {
                SidebarStatus()
                UpdateSidebarButton(updates: model.updates, style: .client, compact: true)
                    .padding(.horizontal, 8)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 14)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct SidebarRow: View {
    var section: AppModel.Section
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    var body: some View {
        let selected = model.section == section
        let updatePending = section == .settings && model.updates.isUpdatePending
        Button {
            model.section = section
        } label: {
            HStack(spacing: 10) {
                Image(systemName: section.sidebarSymbol)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(selected ? Crystal.ink : Crystal.ink2)
                    .frame(width: 22)
                Text(section.title)
                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                    .foregroundStyle(Crystal.ink)
                Spacer(minLength: 4)
                if updatePending {
                    Circle().fill(Crystal.clientAccent).frame(width: 7, height: 7).accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? Crystal.chromeSelected : hovered ? Crystal.chromeHover : .clear)
            }
            .contentShape(.rect(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(Motion.unlessReduced(Motion.fast, reduceMotion), value: hovered)
        // ⌘1…⌘4 live in the View menu, so they work with the sidebar hidden too.
        .help("\(section.title) (⌘\(section.shortcutNumber))")
        .accessibilityLabel(updatePending ? "\(section.title), update available" : section.title)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

/// The one engine status in the window: what transcribes, whether it's ready, and the shortcut,
/// on a small card at the foot of the sidebar.
private struct SidebarStatus: View {
    @Environment(AppModel.self) private var model
    @State private var hovered = false

    var body: some View {
        let state = model.models.engineState
        let remote = model.engineSummary.placement == .remoteHost
        let host = model.hostStatus
        Button {
            if remote { model.settingsTab = .transcription; model.section = .settings } else { model.section = .models }
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Image(systemName: remote ? "server.rack" : "brain")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Crystal.ink2)
                        .frame(width: 20)
                    Text(remote ? "Network device" : model.models.activeModel.shortName)
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Crystal.ink).lineLimit(1)
                    Spacer(minLength: 4)
                    if case .listening = model.dictation.phase {
                        StatusDot(color: Crystal.live, pulsing: true)
                    } else {
                        StatusDot(color: remote ? host.tint : state.tint, pulsing: remote ? host.state == .checking : state.isBusy)
                    }
                }
                statusLine(state: state, remote: remote, host: host)
                    .font(.system(size: 11)).foregroundStyle(Crystal.ink2).lineLimit(1)
                HStack(spacing: 4) {
                    Text(model.settings.settings.recordingShortcutMode == .pushToTalk ? "Hold to dictate" : "Dictate")
                        .font(.system(size: 11)).foregroundStyle(Crystal.ink2)
                    Spacer(minLength: 0)
                    ShortcutCaps(description: HotkeyController.currentShortcutSymbols)
                }
            }
            .padding(12)
            .background(hovered ? Crystal.chromeSelected : Crystal.chromeHover, in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Crystal.hairline))
            .contentShape(.rect(cornerRadius: 14))
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(remote ? "Host settings" : "Models")
        .accessibilityHint(remote ? "Opens host settings" : "Opens Models")
    }

    /// "Ready", "Downloading 40%", or "Listening 0:07" while a dictation records.
    @ViewBuilder private func statusLine(state: ModelLibrary.EngineState, remote: Bool, host: HostStatus) -> some View {
        switch model.dictation.phase {
        case .listening(let since):
            TimelineView(.periodic(from: since, by: 1)) { ctx in
                Text("Listening \(PillView.clock(ctx.date.timeIntervalSince(since)))").monospacedDigit()
            }
        case .transcribing:
            Text("Transcribing…")
        default:
            Text(remote ? host.stateLabel : state.isReady ? "Neural Engine · ready" : state.label)
        }
    }
}

extension UpdateStyle {
    /// The client's pink, with the Crystal warning colour.
    static let client = UpdateStyle(accent: Crystal.clientAccent, warning: Crystal.warn)
}
