import FairspokenUI
import FairspokenCore
import FairspokenUpdates
import SwiftUI

/// Main window: the sidebar stands on the window's frost (the desktop blurred behind the window,
/// tinted once); the content is one opaque card beside it, inset by `CardMetrics.gap` so a thin
/// line of frost frames it.
struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let sidebarWidth: CGFloat = 220

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
                .frame(width: Self.sidebarWidth)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Crystal.canvas)
                .clipShape(.rect(cornerRadius: CardMetrics.radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: CardMetrics.radius, style: .continuous).strokeBorder(Crystal.hairline))
                .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
                .updateToast(model.updates, style: .client)
                .padding([.top, .bottom, .trailing], CardMetrics.gap + 2)
        }
        .background(WindowFrost())
        .ignoresSafeArea()
        .screenshotActive()
        .frame(minWidth: 960, minHeight: 640)
        .onAppear { if model.settings.settings.transcriptionLocation == .remoteHost { model.hostStatus.refresh() } }
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
    /// The section's tile colour in the sidebar.
    var tile: Color {
        switch self {
        case .home: Crystal.Tile.orange
        case .models: Crystal.Tile.indigo
        case .training: Crystal.Tile.purple
        case .settings: Crystal.Tile.gray
        }
    }
}

/// Brand, the sections as rows with coloured icon tiles, and the engine status at the bottom.
private struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Room for the traffic lights, then the brand.
            HStack(spacing: 8) {
                BrandMark(size: 22)
                Text(AppInfo.displayName).font(.system(size: 13, weight: .semibold)).foregroundStyle(Crystal.ink)
            }
            .padding(.horizontal, 6)
            .padding(.top, 44)
            .padding(.bottom, 14)
            .accessibilityElement(children: .combine)

            VStack(spacing: 2) {
                ForEach(Array(AppModel.Section.allCases.enumerated()), id: \.element) { index, section in
                    SidebarRow(section: section, index: index)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .leading, spacing: 6) {
                SidebarStatus()
                UpdateSidebarButton(updates: model.updates, style: .client, compact: true)
                    .padding(.horizontal, 6)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
    }
}

private struct SidebarRow: View {
    var section: AppModel.Section
    var index: Int
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    var body: some View {
        let selected = model.section == section
        let updatePending = section == .settings && model.updates.isUpdatePending
        Button {
            model.section = section
        } label: {
            HStack(spacing: 9) {
                IconTile(section.symbol, color: section.tile, size: 22)
                Text(section.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(Crystal.ink)
                Spacer(minLength: 4)
                if updatePending {
                    Circle().fill(Crystal.clientAccent).frame(width: 7, height: 7).accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 32)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Crystal.chromeSelected : hovered ? Crystal.chromeHover : .clear)
            }
            .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(Motion.unlessReduced(Motion.fast, reduceMotion), value: hovered)
        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
        .help("\(section.title) (⌘\(index + 1))")
        .accessibilityLabel(updatePending ? "\(section.title), update available" : section.title)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

/// The one engine status in the window: what transcribes, whether it's ready, and the shortcut.
/// It sits on the frost, so it is one translucent step, not a card.
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
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 9) {
                    // The dot sits in the tile column, so the text lines up with the sections'.
                    Group {
                        if case .listening = model.dictation.phase {
                            StatusDot(color: Crystal.live, pulsing: true)
                        } else {
                            StatusDot(color: remote ? host.tint : state.tint, pulsing: remote ? host.state == .checking : state.isBusy)
                        }
                    }
                    .frame(width: 22)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(remote ? "Network device" : model.models.activeModel.shortName)
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(Crystal.ink).lineLimit(1)
                        statusLine(state: state, remote: remote, host: host)
                            .font(.system(size: 11)).foregroundStyle(Crystal.ink2).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 4) {
                    Text(model.settings.settings.recordingShortcutMode == .pushToTalk ? "Hold to dictate" : "Dictate")
                        .font(.system(size: 11)).foregroundStyle(Crystal.ink2)
                    Spacer(minLength: 0)
                    ShortcutCaps(description: HotkeyController.currentShortcutSymbols)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 6)
            .background(hovered ? Crystal.chromeSelected : Crystal.chromeHover, in: .rect(cornerRadius: 10, style: .continuous))
            .contentShape(.rect(cornerRadius: 10))
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
            Text(remote ? host.stateLabel : state.label)
        }
    }
}

extension UpdateStyle {
    /// The client's Crystal green, with the Crystal warning colour.
    static let client = UpdateStyle(accent: Crystal.clientAccent, warning: Crystal.warn)
}
