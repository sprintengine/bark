import FairspokenCore
import FairspokenUI
import SwiftUI

/// Home: the new-dictation screen. How to dictate, a composer to try it in (type, or dictate into
/// it, and save it as a note), the keyboard hints, the week in four numbers and the model. Before
/// setup is finished, what's missing takes the numbers' place; a dictation that hasn't been
/// transcribed yet comes first.
struct HomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !model.pending.items.isEmpty {
                    PendingDictationsCard().padding(.bottom, 28)
                }
                HomeHeading()
                HomeComposer().padding(.top, 22)
                if !SetupGuide.isReady(model.setupChecklist()) {
                    SetupCard().padding(.top, 32)
                } else if model.history.usage.totalDictations > 0 {
                    WeekStats().padding(.top, 32)
                }
                ModelSection().padding(.top, 28)
            }
            .frame(maxWidth: 688, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 56)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
    }
}

// MARK: - Heading

private struct HomeHeading: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.settings.settings
        let push = s.recordingShortcutMode == .pushToTalk
        let key = s.fnPushToTalk ? "fn" : HotkeyController.currentShortcutSymbols
        Text(s.fnPushToTalk || push ? "Hold \(key) and speak." : "Press \(key) and speak.")
            .font(TypeScale.title)
            .tracking(-0.33)
            .foregroundStyle(Crystal.ink)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Composer

/// "Try it here": type, or dictate into it (the words land here because Bark's own window is in
/// front), then save it as a note in history.
private struct HomeComposer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var savedID: String?
    @FocusState private var focused: Bool

    /// What's typed, kept on the app model so it survives moving to another screen.
    private var draft: String {
        get { model.homeDraft }
        nonmutating set { model.homeDraft = newValue }
    }

    var body: some View {
        @Bindable var app = model
        let dictation = model.dictation
        let listening = dictation.phase.isListening
        let hasDraft = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                if !hasDraft && !listening && !focused { placeholder.allowsHitTesting(false) }
                TextEditor(text: $app.homeDraft)
                    .font(.system(size: 15))
                    .foregroundStyle(Crystal.ink)
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
                    .focused($focused)
                    .frame(minHeight: 48, maxHeight: 220)
                    .fixedSize(horizontal: false, vertical: true)
                    .onKeyPress(.return, phases: .down) { press in
                        guard press.modifiers.contains(.command) else { return .ignored }
                        save()
                        return .handled
                    }
                    .accessibilityLabel("Try it here")
                    .accessibilityHint("Type or dictate, then press Command Return to save it as a note")
                    .opacity(listening ? 0 : 1)
                if listening { liveWords(dictation) }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 2)
            .contentShape(.rect)
            .onTapGesture { focused = true }

            HStack(spacing: 4) {
                if listening {
                    ListeningStatus(dictation: dictation)
                } else if case .transcribing = dictation.phase {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(dictation.transcribingNote.map { "\($0)…" } ?? "Cleaning up…")
                    }
                    .font(.system(size: 13)).foregroundStyle(Crystal.ink2).padding(.leading, 8)
                } else if let savedID {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                        Text("Saved to history")
                        Button("Open") { model.open(dictation: savedID) }.buttonStyle(.plain).foregroundStyle(Crystal.info)
                    }
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Crystal.ink2).padding(.leading, 8)
                } else {
                    HStack(spacing: 6) {
                        TypeGlyph(size: 13, color: Crystal.ink2)
                        Text("Note")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Crystal.ink)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .help("What you type or dictate here is kept in history as a note")
                }
                Spacer(minLength: 8)
                EngineChip()
                if hasDraft && !listening {
                    IconButton(symbol: "mic", label: "Dictate into the note") { focused = false; dictation.toggleFromUI() }
                    Button(action: save) {
                        Image(systemName: "arrow.up").font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Crystal.onAccent)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Crystal.primary))
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Save as a note (⌘⏎)")
                    .accessibilityLabel("Save as a note")
                } else {
                    DictateButton(dictation: dictation, size: 32) { focused = false; dictation.toggleFromUI() }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
        .background(Crystal.card, in: .rect(cornerRadius: Radius.composer, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.composer, style: .continuous)
            .strokeBorder(focused ? Crystal.input : Crystal.hairline))
        .composerShadow()
        .onChange(of: dictation.lastInAppHistoryID) { _, id in
            guard let id, let item = model.history.item(id) else { return }
            draft = draft.isEmpty ? item.text : draft.trimmingCharacters(in: .whitespacesAndNewlines) + " " + item.text
            model.homeDraftSources.append(id)
            savedID = nil
        }
        .onChange(of: model.homeDraft) {
            if model.homeDraft.isEmpty { model.homeDraftSources = [] } else { savedID = nil }
        }
        .animation(Motion.unlessReduced(Motion.fast, reduceMotion), value: hasDraft)
    }

    private var placeholder: some View {
        let s = model.settings.settings
        return FlowLayout(spacing: 4, lineSpacing: 2) {
            Text("Try it here.")
            if s.fnPushToTalk {
                Text("Hold")
                Keycap(label: "fn", outline: true)
                Text("or press")
            } else {
                Text(s.recordingShortcutMode == .pushToTalk ? "Hold" : "Press")
            }
            Keycap(label: HotkeyController.currentShortcutSymbols, outline: true)
            Text("and say:")
            ForEach(Array("“Can you send the revised quote to Aoife by Thursday?”".split(separator: " ").enumerated()), id: \.offset) { _, word in
                Text(word).foregroundStyle(Crystal.ink).fontWeight(.medium)
            }
            Text("Or type a note.")
        }
        .font(.system(size: 15))
        .foregroundStyle(Crystal.ink2)
        .frame(minHeight: 24)
        .padding(.leading, 5)
        .padding(.top, 0)
        .accessibilityHidden(true)
    }

    private func liveWords(_ dictation: DictationController) -> some View {
        Text(dictation.liveText.isEmpty ? "Listening…" : LiveTranscript.displayTail(dictation.liveText, maxCharacters: 220))
            .font(.system(size: 15))
            .foregroundStyle(dictation.liveText.isEmpty ? Crystal.ink2 : Crystal.ink)
            .lineSpacing(4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 5)
            .accessibilityLabel("Heard so far: \(dictation.liveText)")
    }

    private func save() {
        guard let id = model.saveNote(draft, replacing: model.homeDraftSources) else { return }
        draft = ""
        model.homeDraftSources = []
        savedID = id
    }
}

/// While listening: the red dot, the time and the level.
private struct ListeningStatus: View {
    var dictation: DictationController

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Crystal.recording).frame(width: 8, height: 8)
            if case .listening(let since) = dictation.phase {
                TimelineView(.periodic(from: since, by: 1)) { ctx in
                    Text(PillView.clock(ctx.date.timeIntervalSince(since))).monospacedDigit()
                }
                .font(.system(size: 12)).foregroundStyle(Crystal.ink2)
            }
            LevelBars(meter: dictation.meter, active: true, bars: 24, color: Crystal.ink)
                .frame(width: 96, height: 16)
        }
        .padding(.leading, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Listening")
    }
}

/// Where dictation runs: this Mac's model or Bark Server, as a menu to switch.
private struct EngineChip: View {
    @Environment(AppModel.self) private var model
    @State private var hovered = false

    var body: some View {
        let s = model.settings.settings
        let remote = s.transcriptionLocation == .remoteHost
        Menu {
            Button {
                model.settings.update { $0.transcriptionLocation = .local }
            } label: {
                Label("\(model.models.activeModel.shortName) on this Mac", systemImage: remote ? "" : "checkmark")
            }
            if !s.remoteUrl.isEmpty {
                Button {
                    model.settings.update { $0.transcriptionLocation = .remoteHost }
                    model.hostStatus.refresh()
                } label: {
                    Label("Bark Server", systemImage: remote ? "checkmark" : "")
                }
            }
            Divider()
            Button("Manage Models…") { model.section = .models }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: remote ? "server.rack" : "laptopcomputer").font(.system(size: 12)).foregroundStyle(Crystal.ink2)
                Text(remote ? "Bark Server" : model.models.activeModel.shortName).foregroundStyle(Crystal.ink)
                if !remote { Text("This Mac").foregroundStyle(Crystal.ink2).fontWeight(.regular) }
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(Crystal.ink2)
            }
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(hovered ? Crystal.rowHover : .clear, in: .rect(cornerRadius: Radius.control, style: .continuous))
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovered = $0 }
        .help("Where dictation runs")
        .accessibilityLabel(remote ? "Transcribing on Bark Server" : "Transcribing with \(model.models.activeModel.shortName) on this Mac")
    }
}

// MARK: - The week

/// Words this week, time saved, average pace and how much cleanup took out.
private struct WeekStats: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let usage = model.history.usage
        let week = (0..<7).map { usage.bucket(daysAgo: $0) }
        let lastWeek = (7..<14).map { usage.bucket(daysAgo: $0) }
        let words = week.reduce(0) { $0 + $1.words }
        let dictations = week.reduce(0) { $0 + $1.dictations }
        let seconds = week.reduce(0) { $0 + $1.recordingSeconds }
        let typing = Double(words) / usage.typingWPMInUse * 60
        let saved = max(0, typing - seconds)
        let pace = seconds > 30 ? Double(words) / (seconds / 60) : nil
        let lastSeconds = lastWeek.reduce(0) { $0 + $1.recordingSeconds }
        let lastPace = lastSeconds > 30 ? Double(lastWeek.reduce(0) { $0 + $1.words }) / (lastSeconds / 60) : nil
        let cleaned = Self.cleanedShare(model.history.items)
        HStack(spacing: 0) {
            tile("Words this week", Format.number(words), unit: nil, note: Text("\(dictations) dictation\(dictations == 1 ? "" : "s")"))
            SoftDivider(vertical: true)
            Button { model.speedTest.isPresented = true } label: {
                tile("Time saved", Self.hoursMinutes(saved), unit: nil,
                     note: Text("vs typing at \(Int(usage.typingWPMInUse.rounded())) wpm \(Image(systemName: "chevron.right"))"))
            }
            .buttonStyle(.plain)
            .help(usage.measuredTypingWpm == nil ? "A typical typing pace. Take the speed test to use your own."
                                                 : "Your typing speed from the speed test. Take it again.")
            .accessibilityHint("Opens the speed test")
            SoftDivider(vertical: true)
            tile("Average pace", pace.map { "\(Int($0.rounded()))" } ?? "–", unit: pace == nil ? nil : "wpm",
                 note: Text(Self.paceNote(pace, lastPace)))
            SoftDivider(vertical: true)
            tile("Cleaned up", cleaned.map { "\(Int(($0 * 100).rounded()))%" } ?? "–", unit: nil,
                 note: Text(cleaned == nil ? "once cleanup has run" : "of words were filler"))
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(Crystal.card.opacity(0.4), in: .rect(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Crystal.hairlineSoft))
    }

    private func tile(_ label: String, _ value: String, unit: String?, note: Text) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.system(size: 12)).foregroundStyle(Crystal.ink3)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.mvNumber(20, weight: .semibold)).tracking(-0.2).foregroundStyle(Crystal.ink)
                if let unit { Text(unit).font(.system(size: 13)).foregroundStyle(Crystal.ink2) }
            }
            .padding(.top, 6)
            note.font(.system(size: 12)).foregroundStyle(Crystal.ink3).lineLimit(1).padding(.top, 3)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    static func hoursMinutes(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    static func paceNote(_ pace: Double?, _ last: Double?) -> String {
        guard let pace else { return "speak a little more" }
        guard let last else { return "this week" }
        let change = Int((pace - last).rounded())
        if abs(change) < 3 { return "steady on last week" }
        return change > 0 ? "up \(change) on last week" : "down \(-change) on last week"
    }

    /// The share of words heard in the last 7 days that cleanup took out (fillers, repeats,
    /// restarts, corrections), from dictations that recorded their edits.
    static func cleanedShare(_ items: [TranscriptHistoryItem], now: Date = .now) -> Double? {
        let since = now.addingTimeInterval(-7 * 86_400)
        var heard = 0, removed = 0
        for item in items where item.date >= since {
            guard let edits = item.cleanupEdits, let raw = item.rawText else { continue }
            heard += WordCounter.count(raw)
            for edit in edits where [.filler, .repetition, .restart, .selfCorrection].contains(edit.kind) {
                removed += max(0, WordCounter.count(edit.removed) - WordCounter.count(edit.inserted))
            }
        }
        return heard > 0 ? Double(removed) / Double(heard) : nil
    }
}

// MARK: - Model

/// The model in use, and Bark Server when one is set up.
private struct ModelSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.settings.settings
        let remote = s.transcriptionLocation == .remoteHost
        let info = model.models.activeModel
        let state = model.models.engineState
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Model").font(.system(size: 16, weight: .semibold)).foregroundStyle(Crystal.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button { model.section = .models } label: {
                    HStack(spacing: 4) {
                        Text("Manage models")
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    }
                }
                .buttonStyle(GhostButtonStyle())
            }
            .padding(.horizontal, 16)
            GroupCard {
                row(title: info.name,
                    badge: Badge(state.isReady ? "Ready" : state.label,
                                 style: state.isReady ? .neutral : { if case .failed = state { return .error } else { return .neutral } }()),
                    detail: "Runs on this Mac. \(info.summary)") {
                    Text(Format.bytes(model.models.shownBytes(info))).font(.mono(12)).foregroundStyle(Crystal.ink3)
                }
                if case .downloading(let f) = state {
                    ProgressView(value: f).tint(Crystal.primary).padding(.horizontal, 16).padding(.bottom, 12)
                }
                if !s.remoteUrl.isEmpty {
                    SoftDivider()
                    row(title: "Bark Server", badge: Badge(serverBadge, style: serverStyle),
                        detail: "\(model.hostStatus.hostName). \(remote ? "Dictation runs there now." : "Used when you choose it.")") {
                        Button(remote ? "Use This Mac" : "Use Bark Server") {
                            model.settings.update { $0.transcriptionLocation = remote ? .local : .remoteHost }
                            if !remote { model.hostStatus.refresh() }
                        }
                        .buttonStyle(OutlineButtonStyle())
                    }
                }
            }
        }
    }

    private var serverBadge: String {
        switch model.hostStatus.state {
        case .connected: "Reachable"
        case .checking: "Checking"
        case .failed: "Not reachable"
        case .notConfigured: "Not set"
        }
    }

    private var serverStyle: Badge.Style {
        switch model.hostStatus.state {
        case .connected: .info
        case .failed: .error
        default: .neutral
        }
    }

    private func row<Control: View>(title: String, badge: Badge, detail: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 32) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(Crystal.ink)
                    badge
                }
                Text(detail).font(.system(size: 12)).foregroundStyle(Crystal.ink2).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 520, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - First use

/// Before setup is finished: what's missing, and the way to finish.
private struct SetupCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let checklist = model.setupChecklist()
        GroupCard {
            HStack(alignment: .center, spacing: 32) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("Finish setting up").font(.system(size: 14, weight: .medium)).foregroundStyle(Crystal.ink)
                        Badge("\(checklist.filter { $0.required && !$0.isDone }.count) left", style: .warn)
                    }
                    Text(missing(checklist)).font(.system(size: 12)).foregroundStyle(Crystal.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // No Return shortcut: the composer above takes Return for new lines.
                Button("Continue Setup") { model.openOnboarding?() }
                    .buttonStyle(PrimaryButtonStyle())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private func missing(_ items: [SetupGuide.ChecklistItem]) -> String {
        let names = items.filter { $0.required && !$0.isDone }.map { item -> String in
            switch item.kind {
            case .microphone: "allow the microphone"
            case .model: "get the speech model"
            case .accessibility: "allow typing into apps"
            case .micHeard: "test the microphone"
            }
        }
        return "To dictate, \(ListFormatter.localizedString(byJoining: names))."
    }
}

// MARK: - Flow layout

/// Lays its children out in lines, wrapping like words in a sentence.
struct FlowLayout: SwiftUI.Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: min(width, proposal.width ?? width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(i)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

// MARK: - Not transcribed yet

/// Dictations every attempt failed on. Their audio stays on this Mac until one is transcribed;
/// the app retries on its own, and here they can be retried now, exported or moved to the Trash.
struct PendingDictationsCard: View {
    @Environment(AppModel.self) private var model
    @State private var confirmDelete: PendingDictation?

    var body: some View {
        let pending = model.pending
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading("Not transcribed yet") {
                if pending.items.count > 1 {
                    Button("Retry All") { Task { await pending.retryAll(manual: true) } }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Crystal.clientAccent)
                        .disabled(!pending.retrying.isEmpty)
                        .help("Transcribe them all now; the text goes to Recent")
                }
            }
            Card(padding: 4) {
                VStack(spacing: 0) {
                    ForEach(Array(pending.items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Rectangle().fill(Crystal.hairline).frame(height: 1).padding(.leading, 48) }
                        PendingDictationRow(item: item, retrying: pending.retrying.contains(item.id)) { confirmDelete = item }
                    }
                }
            }
            Text("Kept on this Mac until transcribed. \(AppInfo.displayName) keeps retrying.")
                .font(TypeScale.meta).foregroundStyle(Crystal.ink3)
        }
        .confirmationDialog("Delete this recording?",
                            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            presenting: confirmDelete) { item in
            Button("Move to Trash", role: .destructive) { model.pending.delete(item.id) }
        } message: { _ in
            Text("It hasn't been transcribed. The audio moves to the Trash.")
        }
        // Only reached when the Trash couldn't be used: nothing is gone yet.
        .confirmationDialog("Delete permanently?",
                            isPresented: Binding(get: { pending.needsPermanentDeletion != nil },
                                                 set: { if !$0 { pending.keepAfterTrashFailed() } }),
                            presenting: pending.needsPermanentDeletion) { id in
            Button("Delete Permanently", role: .destructive) { pending.deletePermanently(id) }
        } message: { _ in
            Text("The recording couldn't be moved to the Trash, so nothing was deleted. Deleting it permanently can't be undone; export the audio first to keep it.")
        }
    }
}

private struct PendingDictationRow: View {
    var item: PendingDictation
    var retrying: Bool
    var onDelete: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            IconTile("waveform.badge.exclamationmark", color: Crystal.Tile.orange, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(item.appName ?? "Dictation") · \(PillView.clock(item.durationSeconds))")
                    .font(TypeScale.body).foregroundStyle(Crystal.ink).lineLimit(1)
                Text(retrying ? "Transcribing…" : item.lastError ?? "Not transcribed yet")
                    .font(.system(size: 11)).foregroundStyle(Crystal.ink3).lineLimit(2).truncationMode(.tail)
                    .help(item.lastError ?? "")
            }
            Spacer(minLength: 8)
            Text(Format.relative(item.date)).font(TypeScale.meta).foregroundStyle(Crystal.ink3).monospacedDigit()
            if retrying {
                ProgressView().controlSize(.small).frame(width: 52)
            } else {
                Button("Retry") { Task { await model.pending.retry(item.id, manual: true) } }
                    .cardButton()
                    .controlSize(.small)
                    .help("Transcribe it now; the text goes to the clipboard and Recent")
            }
            Menu {
                actions
            } label: {
                Image(systemName: "ellipsis").foregroundStyle(Crystal.ink2).frame(width: 20, height: 20)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(retrying)
            .help("More")
            .accessibilityLabel("More")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .contextMenu { if !retrying { actions } }
    }

    @ViewBuilder private var actions: some View {
        Button("Export Audio…") { model.pending.export(item.id) }
        Button("Move to Trash…", role: .destructive) { onDelete() }
    }
}

