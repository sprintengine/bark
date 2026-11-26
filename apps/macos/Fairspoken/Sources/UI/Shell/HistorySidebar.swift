import FairspokenCore
import FairspokenUI
import FairspokenUpdates
import SwiftUI

/// The sidebar: Bark's name beside the traffic lights, search, the dictation history as a thread
/// list grouped by day, the model's status, and Home, Models, Post-training and Settings at the
/// foot. ↑ and ↓ move through the list, ⏎ edits the open dictation, ⌫ deletes it (after asking)
/// and esc goes back to Home.
struct HistorySidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                SidebarToggle()
                Wordmark()
                Spacer(minLength: 0)
            }
            .padding(.leading, WindowChrome.afterLights)
            .frame(height: Layout.topBar)
            .background { Color.clear.contentShape(.rect).gesture(WindowDragGesture()) }

            SearchField()
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .padding(.bottom, 6)
            ThreadList()
            if model.updates.isUpdatePending {
                UpdateSidebarButton(updates: model.updates, style: .client, compact: true)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
            }
            ModelStatusRow()
                .padding(.horizontal, 8)
            FootNav()
        }
        .background(Crystal.canvas)
    }
}

/// Bark's glyph on a light tile, and its name in the system face.
private struct Wordmark: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Crystal.canvas)
                .frame(width: 20, height: 20)
                .background(Crystal.ink, in: .rect(cornerRadius: 6, style: .continuous))
            Text(AppInfo.displayName)
                .font(.system(size: 15, weight: .semibold))
                .tracking(-0.15)
                .foregroundStyle(Crystal.ink)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AppInfo.displayName)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Search

private struct SearchField: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool
    @State private var hovered = false

    var body: some View {
        @Bindable var app = model
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium)).foregroundStyle(Crystal.ink2)
                .accessibilityHidden(true)
            TextField("Search", text: $app.historyQuery, prompt: Text("Search").foregroundStyle(Crystal.ink2))
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Crystal.ink)
                .focused($focused)
                .onKeyPress(.escape) {
                    if model.historyQuery.isEmpty { focused = false } else { model.historyQuery = "" }
                    return .handled
                }
                .accessibilityLabel("Search dictations")
            if !model.historyQuery.isEmpty {
                IconButton(symbol: "xmark.circle.fill", label: "Clear search", size: 24) { model.historyQuery = "" }
            }
            FilterMenu()
            if !focused && model.historyQuery.isEmpty {
                // Opens the palette: search across dictations, actions and settings.
                Button { model.paletteOpen = true } label: { Keycap(label: "⌘K") }
                    .buttonStyle(.plain)
                    .help("Search and commands (⌘K)")
                    .accessibilityLabel("Search and commands")
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
        .onChange(of: model.searchFocusPending) { takeFocusIfAsked() }
        .onAppear { takeFocusIfAsked() }
    }

    private func takeFocusIfAsked() {
        guard model.searchFocusPending else { return }
        model.searchFocusPending = false
        focused = true
    }
}

/// Narrows the list to notes, or to dictations that went to the clipboard.
private struct FilterMenu: View {
    @Environment(AppModel.self) private var model
    @State private var hovered = false
    @State private var confirmClear = false

    var body: some View {
        let active = model.historyFilter != .all
        Menu {
            Picker("Show", selection: Binding(get: { model.historyFilter }, set: { model.historyFilter = $0 })) {
                ForEach(AppModel.HistoryFilter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Delete All Dictations…", role: .destructive) { confirmClear = true }
                .disabled(model.history.items.isEmpty)
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(active ? Crystal.info : hovered ? Crystal.ink : Crystal.ink2)
                .frame(width: 24, height: 24)
                .background(active ? Crystal.info.opacity(0.14) : hovered ? Crystal.rowHover : .clear,
                            in: .rect(cornerRadius: 6, style: .continuous))
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovered = $0 }
        .help("Show: \(model.historyFilter.title)")
        .accessibilityLabel("Filter, \(model.historyFilter.title)")
        .confirmationDialog("Delete all \(model.history.items.count) dictations and notes?", isPresented: $confirmClear) {
            Button("Delete All", role: .destructive) {
                model.open(dictation: nil)
                model.history.deleteAll()
            }
        } message: {
            Text("Their text is removed from this Mac. Your usage stats and any kept recordings stay. This can't be undone.")
        }
    }
}

// MARK: - Thread list

private struct ThreadList: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool
    @State private var confirmDelete: TranscriptHistoryItem?

    var body: some View {
        let visible = model.history.visible(query: model.historyQuery, filter: model.historyFilter)
        let groups = HistoryGroups.make(visible)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if visible.isEmpty { empty }
                    ForEach(groups) { group in
                        HStack {
                            Text(group.title)
                            Spacer()
                            Text("\(group.items.count)").monospacedDigit()
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Crystal.ink3)
                        .padding(.horizontal, 10)
                        .padding(.top, 12)
                        .padding(.bottom, 4)
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isHeader)
                        ForEach(group.items) { item in
                            ThreadRow(item: item, selected: model.selectedDictationID == item.id, recede: group.title != "Today") {
                                model.open(dictation: item.id)
                                focused = true
                            } onDelete: {
                                confirmDelete = item
                            }
                            .id(item.id)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(keys: [.upArrow, .downArrow, .return, .delete, .escape]) { press in
                handle(press.key, visible: visible, proxy: proxy)
            }
            .onChange(of: model.selectedDictationID) { _, id in
                guard let id else { return }
                proxy.scrollTo(id)
            }
        }
        .accessibilityLabel("Dictations")
        .confirmationDialog("Delete this dictation?", isPresented: Binding(get: { confirmDelete != nil },
                                                                           set: { if !$0 { confirmDelete = nil } }),
                            presenting: confirmDelete) { item in
            Button("Delete", role: .destructive) { model.deleteDictation(item.id, visible: visible) }
        } message: { item in
            Text("“\(DictationText.title(item))” is removed from history. This can't be undone.")
        }
    }

    private func handle(_ key: KeyEquivalent, visible: [TranscriptHistoryItem], proxy: ScrollViewProxy) -> KeyPress.Result {
        let index = visible.firstIndex { $0.id == model.selectedDictationID }
        switch key {
        case .downArrow:
            let next = index.map { min($0 + 1, visible.count - 1) } ?? 0
            if visible.indices.contains(next) { model.open(dictation: visible[next].id) }
        case .upArrow:
            guard let index else { return .handled }
            if index == 0 { model.open(dictation: nil) } else { model.open(dictation: visible[index - 1].id) }
        case .return:
            guard index != nil else { return .ignored }
            model.editRequest += 1
        case .delete:
            guard let index else { return .ignored }
            confirmDelete = visible[index]
        case .escape:
            guard index != nil else { return .ignored }
            model.open(dictation: nil)
        default:
            return .ignored
        }
        return .handled
    }

    @ViewBuilder private var empty: some View {
        let searching = !model.historyQuery.isEmpty || model.historyFilter != .all
        VStack(alignment: .leading, spacing: 4) {
            Text(searching ? "Nothing matches" : "No dictations yet")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(Crystal.ink)
            Text(searching ? "Try other words, or show all dictations." : "Each one appears here, newest first, with the app it went to.")
                .font(.system(size: 12)).foregroundStyle(Crystal.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 16)
    }
}

/// One dictation: the app and when, the first line, and its style and length. Under the pointer
/// the time gives way to copy and retry.
private struct ThreadRow: View {
    var item: TranscriptHistoryItem
    var selected: Bool
    var recede: Bool
    var onOpen: () -> Void
    var onDelete: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    @State private var copied = false

    var body: some View {
        let retrying = model.retryingDictations.contains(item.id)
        let code = item.style == "code"
        let lit = hovered || model.showcaseHoveredRow == item.id
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                AppMonogram(appName: DictationText.monogramName(item), bundleID: item.appBundleId, isNote: item.isBarkNote)
                Text(DictationText.appName(item))
                    .font(.system(size: 13))
                    .foregroundStyle(Crystal.ink.opacity(0.75))
                    .lineLimit(1)
                Spacer(minLength: 4)
                trailing(retrying: retrying)
            }
            .frame(height: 18)
            Text(DictationText.title(item))
                .font(code ? .mono(12.5) : .system(size: 14, weight: recede && !selected ? .regular : .medium))
                .foregroundStyle(recede && !selected ? Crystal.ink.opacity(0.75) : Crystal.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(height: 20)
                .padding(.top, 4)
                .padding(.bottom, 3)
            HStack(spacing: 7) {
                TypeGlyph(size: 12)
                Text(DictationText.meta(item))
                Spacer(minLength: 4)
                if item.location == "remote-host" {
                    Image(systemName: "server.rack").font(.system(size: 10)).help("Ran on Bark Server")
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(Crystal.ink3)
            .frame(height: 16)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 9)
        .background(selected ? Crystal.selected : lit ? Crystal.rowHover : .clear,
                    in: .rect(cornerRadius: Radius.control, style: .continuous))
        .contentShape(.rect)
        .onTapGesture(perform: onOpen)
        .onHover { hovered = $0 }
        .animation(Motion.unlessReduced(Motion.fast, reduceMotion), value: hovered)
        // Built with every row, so only cheap checks here; Transcribe Again says so when no
        // recording was kept.
        .contextMenu {
            Button("Copy") { model.copy(item) }
            if !item.isBarkNote {
                if model.settings.settings.trainingCapture || item.recordingID != nil {
                    Button("Transcribe Again") { model.retry(item) }
                }
                if item.appBundleId != nil { Button("Open \(DictationText.appName(item))") { model.openApp(item) } }
            }
            Divider()
            Button("Delete…", role: .destructive, action: onDelete)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, onOpen)
        .accessibilityAction(named: "Copy") { model.copy(item) }
        .accessibilityAction(named: "Delete", onDelete)
    }

    @ViewBuilder private func trailing(retrying: Bool) -> some View {
        let lit = hovered || model.showcaseHoveredRow == item.id
        if retrying {
            ProgressView().controlSize(.mini).help("Transcribing again")
        } else if lit || copied {
            HStack(spacing: 2) {
                RowAction(symbol: copied ? "checkmark" : "doc.on.doc", label: "Copy") {
                    model.copy(item)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.4)); copied = false }
                }
                if model.canRetry(item) {
                    RowAction(symbol: "arrow.counterclockwise", label: "Transcribe again") { model.retry(item) }
                }
            }
            .padding(.trailing, -4)
        } else if item.clipboardOnly == true {
            Badge("Clipboard", symbol: "clipboard", style: .warn)
                .help("Nothing could take the paste, so it went to the clipboard")
        } else {
            Text(DictationText.age(item.date)).font(.system(size: 12)).foregroundStyle(Crystal.ink3).monospacedDigit()
        }
    }

    private var accessibilityText: String {
        var parts = [DictationText.appName(item), DictationText.spokenAge(item.date), DictationText.title(item), DictationText.meta(item)]
        if item.clipboardOnly == true { parts.append("copied to the clipboard") }
        return parts.joined(separator: ", ")
    }
}

/// A 22 pt action in a row's top line.
private struct RowAction: View {
    var symbol: String
    var label: String
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(hovered ? Crystal.ink : Crystal.ink2)
                .frame(width: 22, height: 22)
                .background(hovered ? Crystal.hairline : .clear, in: .rect(cornerRadius: 6, style: .continuous))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - Status and foot

/// The model in use and whether it's ready: a dot, its name, and where it runs.
private struct ModelStatusRow: View {
    @Environment(AppModel.self) private var model
    @State private var hovered = false

    var body: some View {
        let remote = model.settings.settings.transcriptionLocation == .remoteHost
        let state = model.models.engineState
        let listening = model.dictation.phase.isListening
        Button {
            if remote { model.settingsTab = .transcription; model.section = .settings } else { model.section = .models }
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(listening ? Crystal.recording : remote ? model.hostStatus.tint : state.isReady ? Crystal.ink : Crystal.ink3)
                    .frame(width: 6, height: 6)
                    .background(Circle().fill(Crystal.hairline).frame(width: 12, height: 12))
                    .frame(width: 12)
                Text(remote ? "Bark Server" : model.models.activeModel.shortName)
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Crystal.ink).lineLimit(1)
                Spacer(minLength: 6)
                status(remote: remote, state: state)
                    .font(.system(size: 12)).foregroundStyle(Crystal.ink3).lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(hovered ? Crystal.rowHover : .clear, in: .rect(cornerRadius: 6, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .overlay(alignment: .top) { Rectangle().fill(Crystal.hairlineSoft).frame(height: 1) }
        .help(remote ? "Transcription settings" : "Models")
        .accessibilityElement(children: .combine)
        .accessibilityHint(remote ? "Opens transcription settings" : "Opens Models")
    }

    @ViewBuilder private func status(remote: Bool, state: ModelLibrary.EngineState) -> some View {
        switch model.dictation.phase {
        case .listening(let since):
            TimelineView(.periodic(from: since, by: 1)) { ctx in
                Text("Listening \(PillView.clock(ctx.date.timeIntervalSince(since)))").monospacedDigit()
            }
        case .transcribing:
            Text("Transcribing…")
        default:
            if remote {
                Text(model.hostStatus.stateLabel)
            } else if state.isReady {
                Text("Ready on this Mac")
            } else {
                Text(state.label)
            }
        }
    }
}

/// Home, Models and Post-training on the left, Settings on the right.
private struct FootNav: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 4) {
            item(.home)
            item(.models)
            item(.training)
            Spacer()
            item(.settings)
                .overlay(alignment: .topTrailing) {
                    if model.updates.isUpdatePending {
                        Circle().fill(Crystal.primary).frame(width: 6, height: 6).offset(x: -4, y: 4).accessibilityHidden(true)
                    }
                }
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
    }

    private func item(_ section: AppModel.Section) -> some View {
        let on = model.section == section && (section != .home || model.selectedDictationID == nil)
        return IconButton(symbol: section.sidebarSymbol, label: section.title, on: on,
                          help: "\(section.title) (⌘\(section.shortcutNumber))") {
            if section == .home { model.open(dictation: nil) } else { model.section = section }
        }
    }
}
