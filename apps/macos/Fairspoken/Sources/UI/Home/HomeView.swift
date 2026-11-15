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
                if model.history.items.isEmpty {
                    FirstUseCard()
                    EmptyRecent()
                } else {
                    StatsStrip()
                    DictateBar()
                    RecentDictations()
                }
            }
            .frame(maxWidth: Layout.readable, alignment: .leading)
            .padding(.horizontal, Layout.pageH)
            .padding(.vertical, Layout.pageTop)
            .frame(maxWidth: .infinity)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
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
                    DictateBarContent()
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

/// Pace, words, apps and time saved, in one card.
struct StatsStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let usage = model.history.usage
        Card(padding: 0) {
            HStack(spacing: 0) {
                StatTile(title: "Average pace", value: usage.speakingWPM.map { "\(Int($0.rounded()))" } ?? "—", unit: "wpm",
                         footnote: "Typing is about \(Int(UsageStats.typingWPM))")
                divider
                StatTile(title: "Words", value: Format.number(usage.totalWords), unit: nil,
                         footnote: "\(Format.number(usage.totalDictations)) dictations")
                divider
                StatTile(title: "Apps used", value: "\(model.history.items.appsUsed)", unit: nil,
                         footnote: "In recent dictations")
                divider
                StatTile(title: "Time saved", value: Format.duration(usage.timeSavedSeconds), unit: nil,
                         footnote: "Against typing")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var divider: some View {
        Rectangle().fill(Crystal.hairline).frame(width: 1).padding(.vertical, 14)
    }
}

private struct StatTile: View {
    var title: String
    var value: String
    var unit: String?
    var footnote: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Crystal.ink2)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.mvNumber(22)).foregroundStyle(Crystal.ink).lineLimit(1).minimumScaleFactor(0.7)
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
        Card(padding: 12) { DictateBarContent() }
    }
}

private struct DictateBarContent: View {
    @Environment(AppModel.self) private var model
    @State private var copied = false

    var body: some View {
        let dictation = model.dictation
        HStack(alignment: .center, spacing: 12) {
            DictateButton(dictation: dictation, size: 34) { dictation.toggleFromUI() }
                .keyboardShortcut(.space, modifiers: [])
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(Motion.normal, value: dictation.phase.isListening)
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
                Text("Transcribing…").font(TypeScale.body).foregroundStyle(Crystal.ink2)
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
                HStack(spacing: 6) {
                    Text("Click to try it here, or")
                    Text(model.settings.settings.recordingShortcutMode == .pushToTalk ? "hold" : "press")
                    ShortcutCaps(description: HotkeyController.currentShortcutSymbols)
                    Text("in any app")
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
                            .frame(width: size + 4 + level * 14, height: size + 4 + level * 14)
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

// MARK: - Recent

/// The latest dictations as cards: the words, the app they went to, and when; copy on hover.
private struct RecentDictations: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let items = Array(model.history.items.prefix(6))
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading("Recent dictations") {
                Button("See all") { model.homeShowsAllDictations = true }
                    .buttonStyle(.link)
                    .font(TypeScale.meta)
                    .tint(Crystal.clientAccent)
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

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            AppIconView(bundleID: item.appBundleId, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.text).font(TypeScale.body).foregroundStyle(Crystal.ink).lineLimit(2)
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
            .help("Copy")
            .accessibilityLabel("Copy dictation")
        }
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
