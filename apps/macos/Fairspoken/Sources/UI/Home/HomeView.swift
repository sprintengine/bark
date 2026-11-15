import FairspokenUI
import FairspokenCore
import SwiftUI

/// Home: the microphone in use, what dictation has done for you, and the latest dictations.
/// Before the first dictation it leads with one thing to do instead: finish setting up, or try
/// the shortcut.
struct HomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.homeShowsAllDictations {
            AllDictationsView()
        } else {
            overview
        }
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageTitle("Home") { MicDeviceChip() }
                // First: a dictation that hasn't been transcribed is the one thing that can be lost.
                if !model.pending.items.isEmpty { PendingDictationsCard() }
                if model.history.items.isEmpty {
                    FirstUseCard()
                    // The test needs dictation to work; before that, setup comes first.
                    if SetupGuide.isReady(model.setupChecklist()) { SpeedTestCard() }
                    EmptyRecent()
                } else {
                    StatsStrip()
                    DictateBar()
                    SpeedTestCard()
                    RecentDictations()
                }
            }
            .frame(maxWidth: Layout.readable, alignment: .leading)
            .padding(.horizontal, Layout.pageH)
            .padding(.vertical, Layout.pageTop)
            .frame(maxWidth: .infinity)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .sheet(isPresented: Binding(get: { model.speedTest.isPresented }, set: { model.speedTest.isPresented = $0 })) {
            SpeedTestSheet().environment(model)
        }
    }
}

// MARK: - Microphone

/// The microphone dictation listens on, as a chip that switches it.
struct MicDeviceChip: View {
    @Environment(AppModel.self) private var model
    @State private var names: [String] = []

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
                Image(systemName: "mic.fill").foregroundStyle(Crystal.ink2)
                Text(Microphones.displayName(for: current)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Crystal.ink3)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Crystal.ink)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Crystal.card, in: .capsule)
            .overlay(Capsule().strokeBorder(Crystal.hairline))
            .contentShape(.capsule)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Microphone")
        .accessibilityLabel("Microphone, \(Microphones.displayName(for: current))")
        .onAppear { names = Microphones.names() }
    }
}

// MARK: - First use

/// Before any dictation: one action. Finish setup if something required is missing, otherwise
/// the real shortcut and a place to try it.
private struct FirstUseCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let checklist = model.setupChecklist()
        let ready = SetupGuide.isReady(checklist)
        Card(padding: 24) {
            VStack(alignment: .leading, spacing: 16) {
                if ready {
                    Text("Dictate in any app").font(TypeScale.heading).foregroundStyle(Crystal.ink)
                    HStack(spacing: 10) {
                        Text(model.settings.settings.recordingShortcutMode == .pushToTalk ? "Hold" : "Press")
                        ShortcutCaps(description: HotkeyController.currentShortcutSymbols, large: true)
                        Text(model.settings.settings.recordingShortcutMode == .pushToTalk ? "and speak. Let go to insert." : "and speak. Press again to insert.")
                    }
                    .font(TypeScale.body)
                    .foregroundStyle(Crystal.ink2)
                    Divider().overlay(Crystal.hairline)
                    DictateBarContent(showsShortcut: false)
                } else {
                    HStack(alignment: .top, spacing: 14) {
                        IconTile("checklist", color: Crystal.Tile.orange, size: 36)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Finish setting up").font(TypeScale.heading).foregroundStyle(Crystal.ink)
                            Text(missing(checklist)).font(TypeScale.body).foregroundStyle(Crystal.ink2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 12)
                        Button("Continue Setup") { model.openOnboarding?() }
                            .buttonStyle(PrimaryButtonStyle(large: true))
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
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

/// Where dictations will appear, before there are any.
private struct EmptyRecent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading("Recent dictations")
            VStack(spacing: 6) {
                Image(systemName: "text.bubble").font(.system(size: 20)).foregroundStyle(Crystal.ink3)
                Text("Your dictations appear here, with the app each one went to.")
                    .font(TypeScale.body).foregroundStyle(Crystal.ink2)
                Text("Usage stats start after your first dictation.")
                    .font(TypeScale.meta).foregroundStyle(Crystal.ink3)
            }
            .frame(maxWidth: .infinity, minHeight: 150)
            .background {
                RoundedRectangle(cornerRadius: CardMetrics.radius, style: .continuous)
                    .strokeBorder(Crystal.hairline, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            }
        }
    }
}

// MARK: - Stats

/// What dictation has done, lifetime: the words spoken, the time spent speaking them, how long
/// typing them would have taken (at the speed test's typing speed when there is one) and the time
/// saved, with the two times as bars.
struct StatsStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let usage = model.history.usage
        let wpm = Int(usage.typingWPMInUse.rounded())
        let faster = usage.totalRecordingSeconds > 0 ? usage.typingSeconds / usage.totalRecordingSeconds : 0
        Card(padding: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    StatTile(title: "Words spoken", value: Format.number(usage.totalWords), unit: nil,
                             footnote: "\(Format.number(usage.totalDictations)) dictations · \(model.history.items.appsUsed) apps")
                        .help("Apps counted from recent dictations")
                    divider
                    StatTile(title: "Time speaking", value: Format.duration(usage.totalRecordingSeconds), unit: nil,
                             footnote: usage.speakingWPM.map { "Average \(Int($0.rounded())) wpm" } ?? "Pace after a minute of speech")
                    divider
                    StatTile(title: "Typing would take", value: Format.duration(usage.typingSeconds), unit: nil,
                             footnote: usage.measuredTypingWpm == nil ? "At \(wpm) wpm, a typical pace" : "At \(wpm) wpm, your speed test")
                    divider
                    StatTile(title: "Time saved", value: Format.duration(usage.timeSavedSeconds), unit: nil,
                             footnote: faster >= 1.05 ? "\(SpeedTestFormat.multiplier(faster)) faster than typing" : "Against typing",
                             accent: true)
                }
                .fixedSize(horizontal: false, vertical: true)
                if usage.typingSeconds > 0 {
                    Rectangle().fill(Crystal.hairline).frame(height: 1)
                    SpeakingVersusTyping(speaking: usage.totalRecordingSeconds, typing: usage.typingSeconds)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(Crystal.hairline).frame(width: 1).padding(.vertical, 14)
    }
}

/// The time spent speaking beside the time typing would have taken, on one scale.
private struct SpeakingVersusTyping: View {
    var speaking: Double
    var typing: Double

    var body: some View {
        let longest = max(speaking, typing, 1)
        VStack(spacing: 6) {
            row("Speaking", speaking / longest, Crystal.clientAccent, speaking)
            row("Typing", typing / longest, Crystal.Tile.gray, typing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Speaking took \(Format.duration(speaking)); typing would take \(Format.duration(typing))")
    }

    private func row(_ label: String, _ fraction: Double, _ color: Color, _ seconds: Double) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(Crystal.ink2).frame(width: 56, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Crystal.well)
                    Capsule().fill(color).frame(width: max(4, geo.size.width * min(1, fraction)))
                }
            }
            .frame(height: 8)
            Text(Format.duration(seconds)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Crystal.ink2)
                .frame(width: 64, alignment: .trailing)
        }
    }
}

private struct StatTile: View {
    var title: String
    var value: String
    var unit: String?
    var footnote: String
    var accent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Crystal.ink2)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.mvNumber(22)).foregroundStyle(accent ? Crystal.clientAccent : Crystal.ink)
                    .lineLimit(1).minimumScaleFactor(0.7)
                if let unit { Text(unit).font(TypeScale.meta).foregroundStyle(Crystal.ink2) }
            }
            Text(footnote).font(.system(size: 11)).foregroundStyle(Crystal.ink3).lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Dictate here

/// A slim card to dictate into this window: the shortcut, a mic button, the words.
private struct DictateBar: View {
    var body: some View {
        Card(padding: 14) { DictateBarContent() }
    }
}

private struct DictateBarContent: View {
    /// The idle hint names the shortcut, unless the card above already shows it.
    var showsShortcut = true
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var copied = false

    var body: some View {
        let dictation = model.dictation
        HStack(alignment: .center, spacing: 12) {
            DictateButton(dictation: dictation, size: 34) { dictation.toggleFromUI() }
                .keyboardShortcut(.space, modifiers: [])
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(Motion.unlessReduced(Motion.normal, reduceMotion), value: dictation.phase.isListening)
    }

    @ViewBuilder private var content: some View {
        let dictation = model.dictation
        switch dictation.phase {
        case .listening:
            HStack(spacing: 12) {
                LevelBars(meter: dictation.meter, active: true, bars: 28, color: Crystal.live)
                    .frame(width: 150, height: 22)
                Text(dictation.liveText.isEmpty ? "Listening…" : LiveTranscript.displayTail(dictation.liveText, maxCharacters: 90))
                    .font(TypeScale.body).foregroundStyle(dictation.liveText.isEmpty ? Crystal.ink2 : Crystal.ink)
                    .lineLimit(1).truncationMode(.head)
            }
        case .transcribing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(dictation.transcribingNote.map { "\($0)…" } ?? "Transcribing…").font(TypeScale.body).foregroundStyle(Crystal.ink2)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(TypeScale.body).foregroundStyle(Crystal.warn)
        default:
            if let result = dictation.lastInAppResult {
                HStack(spacing: 10) {
                    Text(result.text).font(TypeScale.body).foregroundStyle(Crystal.ink)
                        .lineLimit(2).textSelection(.enabled)
                    Spacer(minLength: 8)
                    Text("\(result.words) words · \(Format.ms(Double(result.latencyMs)))")
                        .font(.system(size: 11)).foregroundStyle(Crystal.ink3).monospacedDigit().fixedSize()
                    Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        TextInserter.copy(result.text)
                        copied = true
                        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Copy")
                }
            } else {
                HStack(spacing: 5) {
                    if showsShortcut {
                        Text("Click to try it here, or \(model.settings.settings.recordingShortcutMode == .pushToTalk ? "hold" : "press")")
                        ShortcutCaps(description: HotkeyController.currentShortcutSymbols)
                        Text("in any app")
                    } else {
                        Text("Click to try it here")
                    }
                }
                .font(TypeScale.body)
                .foregroundStyle(Crystal.ink2)
            }
        }
    }
}

/// The round dictate button: accent at rest, the live colour with a stop glyph while listening,
/// a ring that follows the voice.
struct DictateButton: View {
    var dictation: DictationController
    var size: CGFloat = 34
    var action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let listening = dictation.phase.isListening
        let busy = dictation.phase == .transcribing
        Button(action: action) {
            ZStack {
                if busy {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: listening ? "stop.fill" : "mic.fill")
                        .font(.system(size: size * 0.4, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .foregroundStyle(listening ? Color.white : Crystal.onAccent)
            .frame(width: size, height: size)
            .background {
                let base = listening ? Crystal.live : Crystal.clientAccent
                Circle().fill(LinearGradient(colors: [base.mix(with: .white, by: 0.08), base.mix(with: .black, by: 0.10)],
                                             startPoint: .top, endPoint: .bottom))
                    .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                    .shadow(color: base.opacity(0.25), radius: 3, y: 1)
            }
            .background {
                if listening && !reduceMotion {
                    TimelineView(.animation(minimumInterval: 1 / 30)) { _ in
                        let level = CGFloat(dictation.meter.snapshot().level)
                        Circle().stroke(Crystal.live.opacity(0.35), lineWidth: 2)
                            .frame(width: size + 4 + level * 8, height: size + 4 + level * 8)
                    }
                }
            }
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityLabel(listening ? "Stop dictation" : "Start dictation")
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

// MARK: - Recent

/// The latest dictations as cards: the words, the app they went to, and when; copy on hover.
private struct RecentDictations: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let items = Array(model.history.items.prefix(6))
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading("Recent dictations") {
                Button("See all") { model.homeShowsAllDictations = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Crystal.clientAccent)
                    .accessibilityLabel("See all dictations")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 8, alignment: .top)], spacing: 8) {
                ForEach(items) { item in DictationCard(item: item) }
            }
        }
    }
}

private struct DictationCard: View {
    var item: TranscriptHistoryItem
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    @State private var copied = false

    var body: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text(item.text)
                    .font(TypeScale.body)
                    .foregroundStyle(Crystal.ink)
                    .lineLimit(3, reservesSpace: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    AppIconView(bundleID: item.appBundleId, size: 16)
                    Text(item.appName ?? AppInfo.displayName).foregroundStyle(Crystal.ink2).lineLimit(1)
                    Text("·").foregroundStyle(Crystal.ink3)
                    Text(Format.relative(item.date)).foregroundStyle(Crystal.ink3).monospacedDigit().lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(TypeScale.meta)
            }
        }
        .overlay(alignment: .topTrailing) {
            if hovered || copied {
                Button { copy() } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(copied ? Crystal.ok : Crystal.ink2)
                        .frame(width: 26, height: 26)
                        .background(Crystal.card, in: .rect(cornerRadius: 7, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Crystal.hairline))
                }
                .buttonStyle(.plain)
                .padding(8)
                .help("Copy")
                .accessibilityLabel("Copy dictation")
                .transition(.opacity)
            }
        }
        .onHover { hovered = $0 }
        .help(item.text.count > 300 ? String(item.text.prefix(300)) + "…" : item.text)
        .animation(Motion.unlessReduced(Motion.fast, reduceMotion), value: hovered)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Copy") { copy() }
        .contextMenu {
            Button("Copy") { copy() }
            Button("Delete", role: .destructive) { model.history.delete(item.id) }
        }
    }

    private func copy() {
        TextInserter.copy(item.text)
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.4)); copied = false }
    }
}

// MARK: - All dictations

/// "See all": every kept dictation by day, searchable.
private struct AllDictationsView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""

    var body: some View {
        let items = model.history.items.filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query)
            || ($0.appName ?? "").localizedCaseInsensitiveContains(query) }
        let days = Dictionary(grouping: items) { Calendar.current.startOfDay(for: $0.date) }
            .sorted { $0.key > $1.key }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Button { model.homeShowsAllDictations = false } label: {
                        Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                            .frame(width: 26, height: 26)
                            .background(Crystal.card, in: .rect(cornerRadius: 7, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Crystal.hairline))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .help("Back to Home")
                    .accessibilityLabel("Back to Home")
                    PageTitle("Dictations", subtitle: "\(model.history.items.count) kept on this Mac")
                    ContentSearchField(text: $query, prompt: "Search dictations").frame(width: 220)
                }
                if days.isEmpty {
                    ContentUnavailableView.search(text: query).frame(maxWidth: .infinity, minHeight: 200)
                }
                ForEach(days, id: \.key) { day, entries in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(Self.dayTitle(day)).font(.system(size: 12, weight: .semibold)).foregroundStyle(Crystal.ink2)
                        Card(padding: 4) {
                            VStack(spacing: 0) {
                                ForEach(Array(entries.enumerated()), id: \.element.id) { index, item in
                                    if index > 0 { Rectangle().fill(Crystal.hairline).frame(height: 1).padding(.leading, 44) }
                                    DictationRow(item: item)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: Layout.readable, alignment: .leading)
            .padding(.horizontal, Layout.pageH)
            .padding(.vertical, Layout.pageTop)
            .frame(maxWidth: .infinity)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
    }

    static func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}

private struct DictationRow: View {
    var item: TranscriptHistoryItem
    @Environment(AppModel.self) private var model
    @State private var hovered = false
    @State private var copied = false
    /// Clicking a row shows the whole dictation.
    @State private var expanded = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            AppIconView(bundleID: item.appBundleId, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.text).font(TypeScale.body).foregroundStyle(Crystal.ink).lineLimit(expanded ? nil : 2)
                Text("\(item.appName ?? AppInfo.displayName) · \(item.wordCount) words")
                    .font(.system(size: 11)).foregroundStyle(Crystal.ink3).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(item.date.formatted(date: .omitted, time: .shortened))
                .font(TypeScale.meta).foregroundStyle(Crystal.ink3).monospacedDigit()
            Button {
                TextInserter.copy(item.text)
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.4)); copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(copied ? Crystal.ok : Crystal.ink2)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .opacity(hovered || copied ? 1 : 0)
            .allowsHitTesting(hovered || copied)
            .help("Copy")
            .accessibilityLabel("Copy dictation")
        }
        .contentShape(.rect)
        .onTapGesture { expanded.toggle() }
        .accessibilityAction(named: expanded ? "Show less" : "Show all") { expanded.toggle() }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(hovered ? Crystal.rowHover : .clear, in: .rect(cornerRadius: 8, style: .continuous))
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Copy") { TextInserter.copy(item.text) }
            Button("Delete", role: .destructive) { model.history.delete(item.id) }
        }
    }
}

struct AppIconView: View {
    var bundleID: String?
    var size: CGFloat = 28
    var body: some View {
        Group {
            if let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
            } else {
                Image(systemName: "text.bubble.fill").resizable().scaledToFit().padding(size * 0.2)
                    .foregroundStyle(Crystal.ink2)
                    .background(Crystal.well, in: .rect(cornerRadius: size * 0.25, style: .continuous))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
