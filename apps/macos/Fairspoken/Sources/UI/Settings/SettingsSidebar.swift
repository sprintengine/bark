import FairspokenCore
import FairspokenUI
import FairspokenUpdates
import SwiftUI

/// The sidebar while Settings is open: search (⌘F), the pages in groups, and the way back to the
/// dictations (esc). ↑ and ↓ move between pages. While searching, only pages with a match are
/// listed, each with how many rows match.
struct SettingsSidebar: View {
    @Environment(AppModel.self) private var model
    @FocusState private var listFocused: Bool

    var body: some View {
        let query = model.settingsQuery.trimmingCharacters(in: .whitespaces)
        let results = query.isEmpty ? nil : SettingsCatalog.search(query, model: model)
        VStack(spacing: 0) {
            SidebarHeader()
            SettingsSearchField()
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .padding(.bottom, 2)
            ScrollView {
                VStack(spacing: 2) {
                    if let results {
                        SettingsNavLabel(results.isEmpty ? "No matches" : "Matches")
                        ForEach(results, id: \.tab) { result in
                            SettingsNavItem(result.tab.title, symbol: result.tab.symbol, count: "\(result.count)", selected: false) {
                                model.settingsQuery = ""
                                model.settingsTab = result.tab
                            }
                        }
                    } else {
                        ForEach(Array(SettingsView.Tab.groups.enumerated()), id: \.offset) { _, group in
                            if let title = group.title {
                                SettingsNavLabel(title)
                            } else {
                                Rectangle().fill(Crystal.hairlineSoft).frame(height: 1).padding(.horizontal, 10).padding(.vertical, 10)
                            }
                            ForEach(group.tabs) { tab in
                                SettingsNavItem(tab.title, symbol: tab.symbol, count: count(tab), selected: model.settingsTab == tab,
                                                badge: tab == .updates && model.updates.isUpdatePending) {
                                    model.settingsTab = tab
                                    listFocused = true
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                move(press.key == .downArrow ? 1 : -1)
                return .handled
            }
            .accessibilityLabel("Settings pages")
            BackToBark()
                .padding(.horizontal, 8)
            HStack {
                Button {
                    model.settingsQuery = ""
                    model.settingsTab = .updates
                } label: {
                    Text("\(AppInfo.displayName) \(AppInfo.version) · \(model.updates.channel.title)")
                        .font(.system(size: 12))
                        .foregroundStyle(Crystal.ink3)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Updates")
                Spacer()
            }
            .padding(.horizontal, 20)
            .frame(height: 44)
        }
        .background(Crystal.canvas)
    }

    private func count(_ tab: SettingsView.Tab) -> String? {
        let s = model.settings.settings
        switch tab {
        case .appStyles:
            let n = s.styleRules.apps.count + s.styleRules.sites.count
            return n > 0 ? "\(n)" : nil
        case .vocabulary:
            let n = s.vocabularyHints.count + s.transcriptCorrections.count
            return n > 0 ? "\(n)" : nil
        default:
            return nil
        }
    }

    private func move(_ step: Int) {
        let order = SettingsView.Tab.groups.flatMap(\.tabs)
        guard let i = order.firstIndex(of: model.settingsTab) else { return }
        let next = min(max(i + step, 0), order.count - 1)
        model.settingsTab = order[next]
    }
}

/// The sidebar's header beside the traffic lights: the sidebar button and Bark's name.
struct SidebarHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            SidebarToggle()
            Wordmark()
            Spacer(minLength: 0)
        }
        .padding(.leading, WindowChrome.afterLights)
        .frame(height: Layout.topBar)
        .background { Color.clear.contentShape(.rect).gesture(WindowDragGesture()) }
    }
}

private struct SettingsSearchField: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool
    @State private var hovered = false

    var body: some View {
        @Bindable var app = model
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium)).foregroundStyle(Crystal.ink2)
                .accessibilityHidden(true)
            TextField("Search settings", text: $app.settingsQuery, prompt: Text("Search settings").foregroundStyle(Crystal.ink2))
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Crystal.ink)
                .focused($focused)
                .onKeyPress(.escape) {
                    if model.settingsQuery.isEmpty { focused = false } else { model.settingsQuery = "" }
                    return .handled
                }
                .accessibilityLabel("Search settings")
            if !model.settingsQuery.isEmpty {
                IconButton(symbol: "xmark.circle.fill", label: "Clear search", size: 24) { model.settingsQuery = "" }
            } else if !focused {
                Keycap(label: "⌘F").accessibilityHidden(true)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 32)
        .background(focused ? Crystal.selected : hovered ? Crystal.rowHover : .clear,
                    in: .rect(cornerRadius: 6, style: .continuous))
        .contentShape(.rect)
        .onTapGesture { focused = true }
        .onHover { hovered = $0 }
        .onChange(of: model.settingsSearchFocusPending) { takeFocusIfAsked() }
        .onAppear { takeFocusIfAsked() }
    }

    private func takeFocusIfAsked() {
        guard model.settingsSearchFocusPending else { return }
        model.settingsSearchFocusPending = false
        focused = true
    }
}

/// "Back to Bark", with esc.
private struct BackToBark: View {
    @Environment(AppModel.self) private var model
    @State private var hovered = false

    var body: some View {
        Button {
            model.settingsQuery = ""
            model.open(dictation: nil)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.left").font(.system(size: 12, weight: .medium))
                Text("Back to \(AppInfo.displayName)").font(.system(size: 14, weight: .medium))
                Spacer()
                Keycap(label: "esc")
            }
            .foregroundStyle(hovered ? Crystal.ink : Crystal.ink2)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(hovered ? Crystal.rowHover : .clear, in: .rect(cornerRadius: 6, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .overlay(alignment: .top) { Rectangle().fill(Crystal.hairlineSoft).frame(height: 1).offset(y: -6) }
        .padding(.top, 6)
        .help("Back to your dictations (esc)")
    }
}
