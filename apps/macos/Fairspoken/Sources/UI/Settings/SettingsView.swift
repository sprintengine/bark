import FairspokenCore
import FairspokenUI
import SwiftUI

/// Settings in the main area: one page at a time, chosen in the settings sidebar, or every row
/// that matches the sidebar's search. Pages are grouped cards of divided rows; the rows come from
/// `SettingsCatalog`, so search sees exactly what the pages show.
struct SettingsView: View {
    /// A settings page. `shortcut` and `audio` were pages of their own and now live on General.
    enum Tab: String, CaseIterable, Identifiable {
        case general, history, transcription, appStyles, vocabulary, host, updates, about
        var id: String { rawValue }

        static let shortcut = Tab.general
        static let audio = Tab.general

        var title: String {
            switch self {
            case .general: "General"
            case .history: "History"
            case .transcription: "Transcription"
            case .appStyles: "App styles"
            case .vocabulary: "Dictionary"
            case .host: "Bark Server"
            case .updates: "Updates"
            case .about: "About"
            }
        }

        var symbol: String {
            switch self {
            case .general: "slider.horizontal.3"
            case .history: "clock.arrow.circlepath"
            case .transcription: "waveform"
            case .appStyles: "textformat"
            case .vocabulary: "book.closed"
            case .host: "server.rack"
            case .updates: "arrow.triangle.2.circlepath"
            case .about: "info.circle"
            }
        }

        /// The sidebar's groups. Bark Server sits with Dictation, where it is used: a heading of its
        /// own over its one row only repeated the row.
        static let groups: [(title: String?, tabs: [Tab])] = [
            ("Bark", [.general, .history]),
            ("Dictation", [.transcription, .appStyles, .vocabulary, .host]),
            (nil, [.updates, .about]),
        ]
    }

    @Environment(AppModel.self) private var model

    var body: some View {
        let query = model.settingsQuery.trimmingCharacters(in: .whitespaces)
        Group {
            if query.isEmpty {
                SettingsPageView(tab: model.settingsTab)
                    .id(model.settingsTab)
            } else {
                SettingsSearchResults(query: query)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { model.permissions.beginPolling() }
        .onDisappear { model.permissions.endPolling() }
        // Hold fn was turned on before Input Monitoring was allowed: the tap couldn't start then.
        .onChange(of: model.permissions.inputMonitoring) { _, status in
            if status.isGranted { model.applyFnSetting() }
        }
    }
}

/// One page: its title, then its sections.
private struct SettingsPageView: View {
    var tab: SettingsView.Tab
    @Environment(AppModel.self) private var model

    var body: some View {
        let sections = SettingsCatalog.sections(tab, model: model)
        SettingsPage(title: tab == .about ? nil : tab.title) {
            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                SectionView(section: section, first: index == 0)
            }
        }
    }
}

/// Every matching row from every page, under the page's name.
private struct SettingsSearchResults: View {
    var query: String
    @Environment(AppModel.self) private var model

    var body: some View {
        let results = SettingsCatalog.search(query, model: model)
        SettingsPage(title: "Results", subtitle: results.isEmpty ? "Nothing matches “\(query)”." : nil) {
            ForEach(results, id: \.tab) { result in
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        model.settingsQuery = ""
                        model.settingsTab = result.tab
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: result.tab.symbol).font(.system(size: 12)).foregroundStyle(Crystal.ink3)
                            Text(result.tab.title).font(.system(size: 12, weight: .medium)).foregroundStyle(Crystal.ink2)
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Crystal.ink3)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help("Open \(result.tab.title)")
                    .padding(.horizontal, SettingsMetrics.rowH)
                    .padding(.top, 28)
                    ForEach(Array(result.sections.enumerated()), id: \.element.id) { index, section in
                        SectionView(section: section, first: index == 0, compact: true)
                    }
                }
            }
        }
    }
}

private struct SectionView: View {
    var section: SettingsCatalog.Section
    var first: Bool
    var compact = false

    var body: some View {
        if let custom = section.custom {
            custom.padding(.top, first ? 20 : 28)
        } else {
            SettingsSection(section.title, footer: section.footer, first: first || compact) {
                section.trailing
            } content: {
                ForEach(section.rows) { row in row.view }
            }
            .padding(.top, compact && !first ? 8 : 0)
        }
    }
}

// MARK: - Catalogue

/// Every page's sections and rows, as data: the pages draw them and search filters them.
enum SettingsCatalog {
    struct Row: Identifiable {
        var id: String
        /// What search matches: the title, the description and any other words for it.
        var searchText: String
        var view: AnyView

        /// A standard row: title, description and control.
        init<Control: View>(_ title: String, detail: String? = nil, keywords: String = "", id: String? = nil,
                            @ViewBuilder control: () -> Control) {
            self.id = id ?? title
            searchText = [title, detail ?? "", keywords].joined(separator: " ")
            view = AnyView(SettingsRow(title, detail: detail, control: control))
        }

        /// A row drawn by its own view.
        init(id: String, searchText: String, view: some View) {
            self.id = id
            self.searchText = searchText
            self.view = AnyView(view)
        }
    }

    struct Section: Identifiable {
        var title: String?
        var footer: String?
        var trailing: AnyView?
        var rows: [Row]
        /// A section drawn by its own view (a preview, a header); never a search result.
        var custom: AnyView?
        var id: String { title ?? rows.first?.id ?? "section" }

        init(_ title: String?, footer: String? = nil, trailing: AnyView? = nil, rows: [Row]) {
            self.title = title
            self.footer = footer
            self.trailing = trailing
            self.rows = rows
        }

        static func custom(_ id: String, _ view: some View) -> Section {
            var s = Section(id, rows: [])
            s.title = id
            s.custom = AnyView(view)
            return s
        }
    }

    @MainActor
    static func sections(_ tab: SettingsView.Tab, model: AppModel) -> [Section] {
        switch tab {
        case .general: GeneralSettings.sections(model)
        case .history: HistorySettings.sections(model)
        case .transcription: TranscriptionSettings.sections(model)
        case .appStyles: AppStylesSettings.sections(model)
        case .vocabulary: DictionarySettings.sections(model)
        case .host: HostSettings.sections(model)
        case .updates: UpdatesSettings.sections(model)
        case .about: AboutSettings.sections(model)
        }
    }

    struct Result {
        var tab: SettingsView.Tab
        var sections: [Section]
        var count: Int { sections.reduce(0) { $0 + $1.rows.count } }
    }

    /// The rows whose words hold every word of `query` (the page and section names count too).
    @MainActor
    static func search(_ query: String, model: AppModel) -> [Result] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        return SettingsView.Tab.allCases.compactMap { tab in
            let sections = sections(tab, model: model).compactMap { section -> Section? in
                guard section.custom == nil else { return nil }
                var s = section
                s.rows = section.rows.filter { row in
                    let text = [tab.title, section.title ?? "", row.searchText].joined(separator: " ").lowercased()
                    return words.allSatisfy { text.contains($0) }
                }
                return s.rows.isEmpty ? nil : s
            }
            return sections.isEmpty ? nil : Result(tab: tab, sections: sections)
        }
    }
}

// MARK: - Shared pieces

extension AppModel {
    /// A binding to one Bool setting.
    func setting(_ key: WritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(get: { self.settings.settings[keyPath: key] }, set: { v in self.settings.update { $0[keyPath: key] = v } })
    }
}

/// A switch bound to a setting, labelled for VoiceOver by its row.
struct SettingSwitch: View {
    var label: String
    @Binding var isOn: Bool
    var body: some View {
        Toggle(label, isOn: $isOn).toggleStyle(.settingsSwitch).labelsHidden()
    }
}

/// Live permission status with an action button, as a settings row.
struct PermissionRow: View {
    var kind: Permissions.Kind
    var optional = false
    @Environment(AppModel.self) private var model

    var body: some View {
        let status = model.permissions.status(kind)
        SettingsRow(info.title, detail: info.why) {
            if optional { Badge("Optional") }
        } control: {
            if status.isGranted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Crystal.ink2)
            } else if kind == .microphone && status == .denied {
                // Only a microphone that was refused needs System Settings; Allow asks otherwise.
                Button("Open Settings") { model.permissions.openSettings(kind) }.cardButton()
            } else {
                Button("Allow") { model.permissions.request(kind) }.cardButton()
            }
        }
    }

    private var info: (title: String, why: String) {
        switch kind {
        case .microphone: ("Microphone", "Only while you dictate.")
        case .accessibility: ("Accessibility", "To type into the app you are in.")
        case .inputMonitoring: ("Input Monitoring", "To notice when you hold fn.")
        }
    }
}

/// The "Learned" marker beside an entry the app added from the user's corrections.
struct LearnedTag: View {
    var help: String
    var body: some View {
        Badge("Learned", symbol: "sparkles", style: .info)
            .help(help)
            .accessibilityLabel("Learned. \(help)")
    }
}

/// A small remove button at the end of a list row.
struct RemoveButton: View {
    var label: String
    var action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(hovered ? Crystal.ink : Crystal.ink3)
                .frame(width: 24, height: 24)
                .background(hovered ? Crystal.rowHover : .clear, in: .rect(cornerRadius: 6, style: .continuous))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}
