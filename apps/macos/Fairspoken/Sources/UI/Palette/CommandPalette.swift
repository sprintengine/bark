import FairspokenCore
import FairspokenUI
import SwiftUI

/// One thing the palette can do: open a dictation, run an action, open a Settings page, switch
/// the model, set the default style.
struct PaletteEntry: Identifiable {
    enum Group: Int, CaseIterable {
        case dictations, actions, settings, models, styles

        var title: String {
            switch self {
            case .dictations: "Dictations"
            case .actions: "Actions"
            case .settings: "Settings"
            case .models: "Speech model"
            case .styles: "Default style"
            }
        }
    }

    enum Leading {
        case dictation(TranscriptHistoryItem)
        case symbol(String)
    }

    var id: String
    var group: Group
    var title: String
    var subtitle: String?
    var leading: Leading
    var shortcut: String?
    var checked = false
    /// Searched beside the title, counting for less.
    var keywords: [String] = []
    /// What ⌘C copies (a dictation's text).
    var copyText: String?
    var run: () -> Void
}

/// ⌘K inside Bark: one field, results grouped under small labels (dictations by their words and
/// app, then actions, Settings pages, the speech model and the default style), shortcut hints on
/// the right, and the keys along the foot. Keyboard first: ↑↓ move, ↵ opens, ⌘C copies a
/// dictation's text, esc closes. A solid card over the window, never translucent.
struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    static let width: CGFloat = 600

    var body: some View {
        let groups = sections
        let flat = groups.flatMap(\.entries)
        ZStack(alignment: .top) {
            Color.black.opacity(scheme == .dark ? 0.4 : 0.12)
                .contentShape(.rect)
                .onTapGesture { close() }
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                field(flat)
                Rectangle().fill(Crystal.hairline).frame(height: 1)
                results(groups, flat: flat)
                Rectangle().fill(Crystal.hairline).frame(height: 1)
                footer
            }
            .frame(width: Self.width)
            .background(Crystal.card, in: .rect(cornerRadius: Radius.card, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Crystal.hairline) }
            .shadow(color: .black.opacity(scheme == .dark ? 0.6 : 0.18), radius: 22, y: 14)
            .padding(.top, 96)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Search and commands")
            .accessibilityAddTraits(.isModal)
        }
        .onAppear {
            if let showcase = model.showcasePaletteQuery { query = showcase }
            focused = true
        }
        .onChange(of: query) { selected = 0 }
    }

    // MARK: Field

    private func field(_ flat: [PaletteEntry]) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 15)).foregroundStyle(Crystal.ink2).accessibilityHidden(true)
            TextField("Search dictations, actions and settings", text: $query,
                      prompt: Text("Search dictations, actions and settings").foregroundStyle(Crystal.ink3))
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(Crystal.ink)
                .focused($focused)
                .onKeyPress(.downArrow) { move(1, count: flat.count); return .handled }
                .onKeyPress(.upArrow) { move(-1, count: flat.count); return .handled }
                .onKeyPress(.return) {
                    if flat.indices.contains(selected) { run(flat[selected]) }
                    return .handled
                }
                .onKeyPress(.escape) { close(); return .handled }
                .onKeyPress(characters: ["c"], phases: .down) { press in
                    guard press.modifiers == .command, flat.indices.contains(selected), let text = flat[selected].copyText else {
                        return .ignored
                    }
                    TextInserter.copy(text)
                    model.notify("Copied")
                    close()
                    return .handled
                }
                .accessibilityLabel("Search dictations, actions and settings")
            Keycap(label: "esc")
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
    }

    // MARK: Results

    private struct Section: Identifiable {
        var group: PaletteEntry.Group
        var entries: [PaletteEntry]
        var id: Int { group.rawValue }
    }

    private func results(_ groups: [Section], flat: [PaletteEntry]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if flat.isEmpty {
                        Text("Nothing matches “\(query)”")
                            .font(.system(size: 13))
                            .foregroundStyle(Crystal.ink2)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
                    }
                    ForEach(groups) { section in
                        Text(section.group.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Crystal.ink3)
                            .padding(.horizontal, 8)
                            .padding(.top, 6)
                            .padding(.bottom, 2)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(section.entries) { entry in
                            let index = flat.firstIndex { $0.id == entry.id } ?? 0
                            PaletteRow(entry: entry, query: query, highlighted: index == selected)
                                .id(entry.id)
                                .onTapGesture { run(entry) }
                                .onHover { if $0 { selected = index } }
                        }
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 460)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: selected) { _, index in
                guard flat.indices.contains(index) else { return }
                proxy.scrollTo(flat[index].id)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            hint("↑↓", "move")
            hint("↵", "open")
            hint("⌘C", "copy text")
            Spacer()
        }
        .font(.system(size: 12))
        .foregroundStyle(Crystal.ink3)
        .padding(.horizontal, 14)
        .frame(height: 36)
        .accessibilityHidden(true)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 6) {
            Keycap(label: key)
            Text(label)
        }
    }

    // MARK: Keys

    private func move(_ step: Int, count: Int) {
        guard count > 0 else { return }
        selected = (selected + step + count) % count
    }

    private func run(_ entry: PaletteEntry) {
        close()
        entry.run()
    }

    private func close() {
        model.paletteOpen = false
        model.showcasePaletteQuery = nil
    }

    // MARK: Entries

    private var sections: [Section] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let empty = q.isEmpty
        var out: [Section] = []
        let dictations = PaletteSearch.rank(model.history.items, query: q, limit: empty ? 4 : 6) { item in
            PaletteSearch.Fields(title: item.text, other: [DictationText.appName(item), DictationText.styleName(item.style) ?? ""])
        }.map(dictationEntry)
        if !dictations.isEmpty { out.append(Section(group: .dictations, entries: dictations)) }
        for group in [PaletteEntry.Group.actions, .settings, .models, .styles] {
            let all = commands(group)
            let ranked = PaletteSearch.rank(all, query: q, limit: empty && group != .actions ? 3 : nil, allowScattered: true) {
                PaletteSearch.Fields(title: $0.title, other: $0.keywords + [$0.subtitle ?? ""])
            }
            if !ranked.isEmpty { out.append(Section(group: group, entries: ranked)) }
        }
        return out
    }

    private func dictationEntry(_ item: TranscriptHistoryItem) -> PaletteEntry {
        var meta = [DictationText.appName(item)]
        // The style, unless it only repeats the app ("Notes · Notes").
        if item.isBarkNote { meta.append("Note") } else if let style = DictationText.styleName(item.style), style != meta[0] { meta.append(style) }
        let age = DictationText.age(item.date)
        meta.append(age == "now" ? "just now" : "\(age) ago")
        return PaletteEntry(id: "dictation-\(item.id)", group: .dictations, title: DictationText.title(item),
                            subtitle: meta.joined(separator: " · "), leading: .dictation(item), copyText: item.text) { [model] in
            model.open(dictation: item.id)
        }
    }

    private func commands(_ group: PaletteEntry.Group) -> [PaletteEntry] {
        switch group {
        case .dictations: return []
        case .actions: return actions
        case .settings:
            return SettingsView.Tab.allCases.map { tab in
                PaletteEntry(id: "settings-\(tab.rawValue)", group: .settings, title: tab.title, subtitle: nil,
                             leading: .symbol(tab.symbol), shortcut: tab == .general ? "⌘," : nil,
                             keywords: ["settings", "preferences", tab.rawValue]) { [model] in
                    model.settingsTab = tab
                    model.section = .settings
                }
            }
        case .models:
            let active = model.settings.settings.model
            let ids = (model.models.installedIDs.union([active])).sorted()
            return ids.compactMap { SpeechModelCatalog.model(id: $0) }.map { info in
                PaletteEntry(id: "model-\(info.id)", group: .models, title: "Use \(info.name)", subtitle: nil,
                             leading: .symbol("square.3.layers.3d"), checked: info.id == active,
                             keywords: ["model", "switch", "speech", info.shortName]) { [model] in
                    model.useModel(info.id)
                    model.notify("Using \(info.shortName)")
                }
            }
        case .styles:
            let current = model.settings.settings.styleRules.defaultStyle
            return DictationStyle.ID.allCases.map { style in
                PaletteEntry(id: "style-\(style.rawValue)", group: .styles, title: "Default style: \(style.displayName)",
                             subtitle: nil, leading: .symbol("textformat"), checked: style == current,
                             keywords: ["style", "default", "format", style.summary]) { [model] in
                    model.settings.update { $0.styleRules.defaultStyle = style }
                }
            }
        }
    }

    private var actions: [PaletteEntry] {
        var out: [PaletteEntry] = [
            PaletteEntry(id: "new-dictation", group: .actions, title: "New dictation", subtitle: nil, leading: .symbol("mic"),
                         shortcut: HotkeyController.hasShortcut ? HotkeyController.currentShortcutSymbols : nil,
                         keywords: ["dictate", "record", "start", "note", "home"]) { [model] in
                model.open(dictation: nil)
                Task { @MainActor in
                    // Once the palette has gone, so the words land in Home's composer.
                    try? await Task.sleep(for: .milliseconds(150))
                    if !model.dictation.phase.isActive { model.dictation.toggleFromUI() }
                }
            },
        ]
        if let last = model.lastDictation {
            out.append(PaletteEntry(id: "paste-last", group: .actions, title: "Paste last dictation",
                                    subtitle: nil, leading: .symbol("doc.on.clipboard"),
                                    shortcut: HotkeyController.pasteLastShortcutSymbols,
                                    keywords: ["again", "insert", DictationText.appName(last)]) { [model] in
                model.pasteLast()
            })
            out.append(PaletteEntry(id: "copy-last", group: .actions, title: "Copy last dictation", subtitle: nil,
                                    leading: .symbol("doc.on.doc"), keywords: ["clipboard"], copyText: last.text) { [model] in
                TextInserter.copy(last.text)
                model.notify("Copied")
            })
        }
        out.append(PaletteEntry(id: "models", group: .actions, title: "Browse speech models", subtitle: nil,
                                leading: .symbol("square.3.layers.3d"), keywords: ["models", "download", "library"]) { [model] in
            model.section = .models
        })
        return out
    }
}

private struct PaletteRow: View {
    var entry: PaletteEntry
    var query: String
    var highlighted: Bool

    var body: some View {
        HStack(alignment: entry.subtitle == nil ? .center : .top, spacing: 8) {
            leading.frame(width: 16).padding(.top, entry.subtitle == nil ? 0 : 2)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 14))
                    .foregroundStyle(Crystal.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let subtitle = entry.subtitle {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(Crystal.ink2).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if entry.checked {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Crystal.ink2)
            }
            if highlighted, case .dictation = entry.leading {
                Keycap(label: "↵")
            } else if let shortcut = entry.shortcut {
                Keycap(label: shortcut)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(minHeight: 32)
        .background(highlighted ? Crystal.selected : .clear, in: .rect(cornerRadius: 4, style: .continuous))
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(highlighted ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder private var leading: some View {
        switch entry.leading {
        case .dictation(let item):
            AppMonogram(appName: DictationText.monogramName(item), bundleID: item.appBundleId, isNote: item.isBarkNote)
        case .symbol(let name):
            Image(systemName: name).font(.system(size: 13)).foregroundStyle(Crystal.ink2)
        }
    }

    /// The title with the words searched for underlined.
    private var title: AttributedString {
        var text = AttributedString(entry.title)
        guard case .dictation = entry.leading else { return text }
        for range in PaletteSearch.matchRanges(query, in: entry.title) {
            if let r = Range(range, in: text) {
                text[r].underlineStyle = .single
            }
        }
        return text
    }
}
