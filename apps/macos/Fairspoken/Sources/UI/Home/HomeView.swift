import Charts
import FairspokenUI
import FairspokenCore
import SwiftUI

/// Home: the dog banner with the greeting, the date, how to dictate and the
/// status; a dictation card with the big microphone beside the time saved; four stat tiles; the
/// recent dictations beside the speech engine and the speed test. Before the first dictation it
/// leads with one thing to do instead: finish setting up, or try the shortcut.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    /// Wide enough for the side column beside the main one.
    @State private var wide = true

    var body: some View {
        if model.homeShowsAllDictations {
            AllDictationsView()
        } else {
            overview
        }
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HomeBanner()
                // First: a dictation that hasn't been transcribed is the one thing that can be lost.
                if !model.pending.items.isEmpty { PendingDictationsCard() }
                if model.history.items.isEmpty {
                    firstUse
                } else {
                    pair { DictationCard() } side: { TimeSavedCard() }
                    StatsRow(wide: wide)
                    pair {
                        RecentDictationsCard()
                    } side: {
                        VStack(spacing: 18) {
                            EngineCard()
                            SpeedTestCard()
                        }
                    }
                }
            }
            .frame(maxWidth: Layout.readable, alignment: .leading)
            .onGeometryChange(for: Bool.self) { $0.size.width >= 780 } action: { wide = $0 }
            .padding(.horizontal, Layout.pageH)
            .padding(.top, 8)
            .padding(.bottom, Layout.pageH)
            .frame(maxWidth: .infinity)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
    }

    /// Before any dictation: finish setup if something required is missing; otherwise the
    /// dictation card, with the speed test beside it.
    @ViewBuilder private var firstUse: some View {
        if SetupGuide.isReady(model.setupChecklist()) {
            pair { DictationCard() } side: { SpeedTestCard() }
        } else {
            SetupCard()
        }
        EmptyRecent()
    }

    /// A main card and a 300 pt side column, or one above the other in a narrow window.
    @ViewBuilder private func pair<Main: View, Side: View>(@ViewBuilder _ main: () -> Main,
                                                           @ViewBuilder side: () -> Side) -> some View {
        if wide {
            HStack(alignment: .top, spacing: 18) {
                main().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                side().frame(width: 300)
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            main()
            side()
        }
    }
}

// MARK: - Banner

/// The first thing on Home: the dog on black, with the greeting, the date, how to dictate and
/// whether dictation is ready. Black in both themes, as the app icon is.
private struct HomeBanner: View {
    @Environment(AppModel.self) private var model
    @State private var width: CGFloat = 900

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Plain.radius, style: .continuous)
        ZStack(alignment: .leading) {
            Color.black
            GeometryReader { geo in
                // The photo's face on the right, its black fur fading into the banner's.
                let side = geo.size.height * 1.32
                Image("HomeBanner")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: side, height: side)
                    .offset(x: geo.size.width - side * 0.9, y: -side * 0.12)
                    .mask {
                        LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.32)],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: side, height: side)
                            .offset(x: geo.size.width - side * 0.9, y: -side * 0.12)
                    }
                    .opacity(geo.size.width > 560 ? 1 : 0)
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(Self.greeting())
                    .font(.barkWordmark(36))
                    .tracking(-0.7)
                    .foregroundStyle(.white)
                    .accessibilityAddTraits(.isHeader)
                Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.68))
                    .padding(.top, 2)
                howTo.padding(.top, 16)
                HStack(spacing: 8) {
                    BannerStatus()
                    MicDeviceChip()
                }
                .padding(.top, 16)
            }
            // The words stop short of the dog's face.
            .frame(maxWidth: max(320, width - 250), alignment: .leading)
            .padding(.horizontal, 30)
            .padding(.vertical, 26)
        }
        .frame(minHeight: 210)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
        // Keycaps, chips and menus drawn for a dark surface in both themes.
        .environment(\.colorScheme, .dark)
    }

    private var howTo: some View {
        let push = model.settings.settings.recordingShortcutMode == .pushToTalk
        return HStack(spacing: 6) {
            Text(push ? "Hold" : "Press")
            ShortcutCaps(description: HotkeyController.currentShortcutSymbols)
            Text(push ? "in any app and talk. Let go, and \(AppInfo.displayName) types it where your cursor is."
                      : "in any app and talk. Press it again, and \(AppInfo.displayName) types it where your cursor is.")
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 14))
        .foregroundStyle(.white.opacity(0.78))
    }

    static func greeting(at date: Date = .now) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        return hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
    }
}

/// "Ready", or what dictation is waiting for, as a pill on the banner.
private struct BannerStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let remote = model.settings.settings.transcriptionLocation == .remoteHost
        let state = model.models.engineState
        let host = model.hostStatus
        let (text, color, busy): (String, Color, Bool) = {
            if case .listening = model.dictation.phase { return ("Listening", Crystal.live, true) }
            if remote { return ("Network device · \(host.stateLabel.lowercased())", host.tint, host.state == .checking) }
            if state.isReady { return ("\(model.models.activeModel.shortName) is ready", Crystal.ok, false) }
            return ("\(model.models.activeModel.shortName) · \(state.label.lowercased())", state.tint, state.isBusy)
        }()
        HStack(spacing: 7) {
            StatusDot(color: color, pulsing: busy)
            Text(text).lineLimit(1)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 11)
        .frame(height: 26)
        .background(.white.opacity(0.10), in: .capsule)
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status: \(text)")
    }
}

// MARK: - Microphone

/// The microphone dictation listens on, as a pill that switches it (on the banner).
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
                Image(systemName: "mic.fill").foregroundStyle(.white.opacity(0.7))
                Text(Microphones.displayName(for: current)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(.white.opacity(0.10), in: .capsule)
            .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
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

/// Before any dictation, when something required is missing: what, and the way to finish.
private struct SetupCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let checklist = model.setupChecklist()
        Card(cornerRadius: 28, padding: 26) {
            HStack(alignment: .center, spacing: 16) {
                IconTile("checklist", color: Crystal.clientAccent, size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Finish setting up").font(.system(size: 20, weight: .semibold)).foregroundStyle(Crystal.ink)
                    Text(missing(checklist)).font(.system(size: 14)).foregroundStyle(Crystal.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button("Continue Setup") { model.openOnboarding?() }
                    .buttonStyle(PrimaryButtonStyle(large: true))
                    .keyboardShortcut(.defaultAction)
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
        Card(cornerRadius: 26, padding: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Recent dictations").font(.system(size: 15, weight: .semibold)).foregroundStyle(Crystal.ink)
                    .accessibilityAddTraits(.isHeader)
                VStack(spacing: 6) {
                    Image(systemName: "text.bubble").font(.system(size: 22)).foregroundStyle(Crystal.ink3)
                    Text("Your dictations appear here, with the app each one went to.")
                        .font(TypeScale.body).foregroundStyle(Crystal.ink2)
                    Text("Usage stats start after your first dictation.")
                        .font(TypeScale.meta).foregroundStyle(Crystal.ink3)
                }
                .frame(maxWidth: .infinity, minHeight: 130)
            }
        }
    }
}

// MARK: - Dictation

/// "Here's what you said": the shortcut, the last dictation made in this window with its
/// words, time to text and Copy, and the big microphone to try it here.
private struct DictationCard: View {
    @Environment(AppModel.self) private var model
    @State private var copied = false

    var body: some View {
        let dictation = model.dictation
        Card(cornerRadius: 28, padding: 26, fillHeight: true) {
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    Eyebrow(text: "Dictation", symbol: "mic")
                    Text(title).font(.system(size: 26, weight: .semibold)).tracking(-0.3)
                        .foregroundStyle(Crystal.ink)
                        .contentTransition(.opacity)
                    instructions
                    resultArea
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                MicButton(dictation: dictation) { dictation.toggleFromUI() }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var title: String {
        switch model.dictation.phase {
        case .listening: "Listening…"
        case .transcribing: "Transcribing…"
        case .failed: "Let's try that again"
        default: model.dictation.lastInAppResult == nil ? "Ready when you are" : "Here's what you said"
        }
    }

    private var instructions: some View {
        let s = model.settings.settings
        return HStack(spacing: 6) {
            Text(s.recordingShortcutMode == .pushToTalk ? "Hold" : "Press")
            ShortcutCaps(description: HotkeyController.currentShortcutSymbols)
            if s.fnPushToTalk {
                Text("or hold")
                Keycap(label: "fn")
            }
            // Wraps beside the keys rather than truncating.
            Text("in any app, or click the mic.")
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 2)
        }
        .font(.system(size: 14))
        .foregroundStyle(Crystal.ink2)
    }

    @ViewBuilder private var resultArea: some View {
        let dictation = model.dictation
        switch dictation.phase {
        case .listening:
            VStack(alignment: .leading, spacing: 10) {
                LevelBars(meter: dictation.meter, active: true, bars: 40, color: Crystal.live)
                    .frame(height: 30)
                    .frame(maxWidth: 420)
                if !dictation.liveText.isEmpty {
                    Text(LiveTranscript.displayTail(dictation.liveText, maxCharacters: 160))
                        .font(.system(size: 16)).foregroundStyle(Crystal.ink)
                        .lineLimit(2).truncationMode(.head)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 2)
        case .transcribing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(dictation.transcribingNote.map { "\($0)…" } ?? "Turning your words into text…")
                    .font(.system(size: 14)).foregroundStyle(Crystal.ink2)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 14)).foregroundStyle(Crystal.warn)
                .fixedSize(horizontal: false, vertical: true)
        default:
            if let result = dictation.lastInAppResult {
                VStack(alignment: .leading, spacing: 10) {
                    Text(result.text)
                        .font(.system(size: 17))
                        .foregroundStyle(Crystal.ink)
                        .textSelection(.enabled)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Tag(text: "\(result.words) words", symbol: "text.word.spacing", color: Crystal.ink2)
                        Tag(text: "\(Format.ms(Double(result.latencyMs))) to text", symbol: "bolt.fill", color: Crystal.ink2)
                        Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                            TextInserter.copy(result.text)
                            copied = true
                            Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                        }
                        .cardButton()
                        .controlSize(.small)
                    }
                }
            } else {
                Text("Your words appear at the cursor. Try a sentence here first: the text shows up in this card.")
                    .font(.system(size: 14)).foregroundStyle(Crystal.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The big microphone: a flat pink disc inside one quiet ring at rest; a stop glyph while
/// listening, with rings that spread with the voice.
private struct MicButton: View {
    var dictation: DictationController
    var size: CGFloat = 104
    var action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let listening = dictation.phase.isListening
        let busy = dictation.phase == .transcribing
        // The button's footprint includes its resting rings; the spreading rings while listening
        // draw past it, behind the card's text.
        let ring = size + 64
        let canvas = size + 120
        ZStack {
            Button(action: action) {
                ZStack {
                    if busy {
                        ProgressView().controlSize(.large).tint(Crystal.onAccent)
                    } else {
                        Image(systemName: listening ? "stop.fill" : "mic.fill")
                            .font(.system(size: size * 0.3, weight: .semibold))
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .foregroundStyle(Crystal.onAccent)
                .frame(width: size, height: size)
                .background {
                    // A flat pink disc: no gradient, no glow.
                    Circle().fill(Crystal.live)
                }
                .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .keyboardShortcut(.space, modifiers: [])
            .help(listening ? "Stop" : "Dictate here (Space)")
            .accessibilityLabel(listening ? "Stop dictation" : "Start dictation")
        }
        .frame(width: ring, height: ring)
        .background {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !listening || reduceMotion)) { ctx in
                let level = CGFloat(listening ? dictation.meter.snapshot().level : 0)
                Canvas { gc, sz in
                    _ = ctx.date
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
                    func circle(_ r: CGFloat) -> Path { Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)) }
                    if listening && !reduceMotion {
                        for i in 0..<3 {
                            let phase = (t * 0.6 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                            let r = size / 2 + CGFloat(phase) * (20 + level * 36)
                            gc.stroke(circle(r), with: .color(Crystal.live.opacity((1 - phase) * (0.25 + Double(level) * 0.5))), lineWidth: 2)
                        }
                    } else {
                        // One quiet ring at rest.
                        gc.stroke(circle(size / 2 + 12), with: .color(Crystal.live.opacity(0.22)), lineWidth: 1)
                    }
                }
            }
            .frame(width: canvas, height: canvas)
            .allowsHitTesting(false)
        }
        .animation(Motion.unlessReduced(Motion.deliberate, reduceMotion), value: listening)
    }
}

// MARK: - Time saved

/// The lifetime time saved against typing the same words, at the speed test's typing speed when
/// there is one; the time spent speaking beside typing's; then the totals.
private struct TimeSavedCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let usage = model.history.usage
        let wpm = Int(usage.typingWPMInUse.rounded())
        let saved = usage.timeSavedSeconds
        let faster = usage.totalRecordingSeconds > 0 ? usage.typingSeconds / usage.totalRecordingSeconds : 0
        Card(cornerRadius: 28, padding: 24, fillHeight: true) {
            VStack(alignment: .leading, spacing: 10) {
                Eyebrow(text: "Time saved", symbol: "hourglass")
                HoursMinutes(seconds: saved)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Time saved, \(Format.duration(saved))")
                Text(usage.measuredTypingWpm == nil ? "compared with typing at \(wpm) wpm"
                                                    : "compared with your typing, \(wpm) wpm")
                    .font(.system(size: 13)).foregroundStyle(Crystal.ink2)
                    .help(usage.measuredTypingWpm == nil ? "A typical typing pace; take the speed test to use your own"
                                                         : "Your typing speed from the speed test")
                if faster >= 1.05 {
                    Text("Speaking is \(SpeedTestFormat.multiplier(faster)) faster than typing")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Crystal.clientAccent)
                }
                if usage.typingSeconds > 0 {
                    SpeakingVersusTyping(speaking: usage.totalRecordingSeconds, typing: usage.typingSeconds)
                        .padding(.top, 2)
                }
                Divider().overlay(Crystal.hairline).padding(.vertical, 4)
                row("Words dictated", Format.number(usage.totalWords))
                row("Dictations", Format.number(usage.totalDictations))
                row("Apps used", "\(model.history.items.appsUsed)")
                    .help("Apps counted from recent dictations")
                if let pace = usage.speakingWPM {
                    row("Speaking pace", "\(Int(pace.rounded())) wpm")
                }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Crystal.ink2)
            Spacer(minLength: 8)
            Text(value).foregroundStyle(Crystal.ink).monospacedDigit()
        }
        .font(.system(size: 13))
        .accessibilityElement(children: .combine)
    }
}

/// "132 h 12 m" in big rounded numerals (minutes alone under an hour).
private struct HoursMinutes: View {
    var seconds: Double

    var body: some View {
        let total = Int(seconds) / 60
        let h = total / 60, m = total % 60
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            if h > 0 {
                Text("\(h)").font(.mvNumber(52, weight: .bold))
                Text("h").font(.system(size: 20, weight: .semibold)).foregroundStyle(Crystal.ink2)
                    .padding(.trailing, 8)
            }
            Text("\(m)").font(.mvNumber(52, weight: .bold))
            Text("m").font(.system(size: 20, weight: .semibold)).foregroundStyle(Crystal.ink2)
        }
        .foregroundStyle(Crystal.ink)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
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
            row("Typing", typing / longest, Crystal.ink3.opacity(0.7), typing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Speaking took \(Format.duration(speaking)); typing would take \(Format.duration(typing))")
    }

    private func row(_ label: String, _ fraction: Double, _ color: Color, _ seconds: Double) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(Crystal.ink2).frame(width: 54, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Crystal.well)
                    Capsule().fill(color).frame(width: max(4, geo.size.width * min(1, fraction)))
                }
            }
            .frame(height: 6)
            Text(Format.duration(seconds)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Crystal.ink2)
                .frame(width: 58, alignment: .trailing)
        }
    }
}

// MARK: - Stat tiles

/// Today, this week (with the days as bars), release → text, and the streak.
private struct StatsRow: View {
    var wide: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        let usage = model.history.usage
        let today = usage.bucket(daysAgo: 0)
        let week = usage.words(lastDays: 7)
        let lastWeek = usage.words(lastDays: 14) - week
        let streak = usage.streak()
        let todayTile = StatTile(title: "Today", symbol: "sun.max", value: Format.number(today.words), unit: "words",
                                 footnote: "\(today.dictations) dictation\(today.dictations == 1 ? "" : "s")")
        let weekTile = WeekTile(usage: usage, words: week, previous: lastWeek)
        let latencyTile = StatTile(title: "Release → text", symbol: "bolt", value: model.history.typicalLatencyMs.map { "\($0)" } ?? "–",
                                   unit: "ms", footnote: "median of recent dictations")
        let streakTile = StatTile(title: "Streak", symbol: "flame", value: "\(streak)", unit: streak == 1 ? "day" : "days",
                                  footnote: "days in a row with a dictation")
        if wide {
            HStack(spacing: 18) { todayTile; weekTile; latencyTile; streakTile }
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Grid(horizontalSpacing: 18, verticalSpacing: 18) {
                GridRow { todayTile; weekTile }
                GridRow { latencyTile; streakTile }
            }
        }
    }
}

private struct StatTile: View {
    var title: String
    var symbol: String
    var value: String
    var unit: String
    var footnote: String

    var body: some View {
        Card(cornerRadius: Plain.radius, padding: 18, fillHeight: true) {
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow(text: title, symbol: symbol)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value).font(.mvNumber(32, weight: .bold)).foregroundStyle(Crystal.ink)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Text(unit).font(.system(size: 13, weight: .medium)).foregroundStyle(Crystal.ink2)
                }
                Text(footnote).font(.system(size: 11)).foregroundStyle(Crystal.ink2).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct WeekTile: View {
    var usage: UsageStats
    var words: Int
    var previous: Int

    var body: some View {
        let series = usage.series(days: 7)
        Card(cornerRadius: Plain.radius, padding: 18, fillHeight: true) {
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow(text: "This week", symbol: "calendar")
                HStack(alignment: .bottom, spacing: 8) {
                    Text(Format.number(words)).font(.mvNumber(32, weight: .bold)).foregroundStyle(Crystal.ink)
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .layoutPriority(1)
                    Spacer(minLength: 0)
                    Chart(Array(series.enumerated()), id: \.offset) { i, day in
                        BarMark(x: .value("Day", day.date, unit: .day), y: .value("Words", day.bucket.words), width: 5)
                            .foregroundStyle(i == series.count - 1 ? Crystal.clientAccent : Crystal.ink3.opacity(0.4))
                            .clipShape(Capsule())
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .frame(width: 54, height: 36)
                    .accessibilityLabel("Words per day this week")
                }
                if previous > 0 {
                    let change = Double(words - previous) / Double(previous) * 100
                    Label("\(Int(abs(change).rounded()))% vs last week", systemImage: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(change >= 0 ? Crystal.ok : Crystal.ink2)
                        .lineLimit(1)
                } else {
                    Text("words in the last 7 days").font(.system(size: 11)).foregroundStyle(Crystal.ink2)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Recent

/// The latest dictations as rows: the app, the words, how long they took to text, when; copy.
private struct RecentDictationsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card(cornerRadius: 26, padding: 20, fillHeight: true) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Recent dictations").font(.system(size: 15, weight: .semibold)).foregroundStyle(Crystal.ink)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    Text("\(model.history.items.count) kept on this Mac").font(.system(size: 11)).foregroundStyle(Crystal.ink3)
                    Button("See all") { model.homeShowsAllDictations = true }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Crystal.clientAccent)
                        .padding(.leading, 6)
                        .accessibilityLabel("See all dictations")
                }
                VStack(spacing: 2) {
                    ForEach(model.history.items.prefix(6)) { item in RecentRow(item: item) }
                }
            }
        }
    }
}

private struct RecentRow: View {
    var item: TranscriptHistoryItem
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            AppIconView(bundleID: item.appBundleId, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.text).font(.system(size: 13)).foregroundStyle(Crystal.ink).lineLimit(1).truncationMode(.tail)
                Text(meta).font(.system(size: 11)).foregroundStyle(Crystal.ink3).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(Format.relative(item.date)).font(.system(size: 11)).foregroundStyle(Crystal.ink3).monospacedDigit()
            Button { copy() } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(copied ? Crystal.ok : Crystal.ink2)
                    .frame(width: 26, height: 24)
                    .background(Crystal.well, in: .rect(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .opacity(hovered || copied ? 1 : 0.5)
            .help("Copy")
            .accessibilityLabel("Copy dictation")
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .background(hovered ? Crystal.rowHover : .clear, in: .rect(cornerRadius: 12, style: .continuous))
        .onHover { hovered = $0 }
        .animation(Motion.unlessReduced(Motion.fast, reduceMotion), value: hovered)
        .help(item.text.count > 300 ? String(item.text.prefix(300)) + "…" : item.text)
        .contextMenu {
            Button("Copy") { copy() }
            Button("Delete", role: .destructive) { model.history.delete(item.id) }
        }
    }

    private var meta: String {
        var parts = [item.appName ?? AppInfo.displayName, "\(item.wordCount) words"]
        if let ms = item.timings?.totalMs, ms > 0 { parts.append("\(ms) ms") }
        return parts.joined(separator: " · ")
    }

    private func copy() {
        TextInserter.copy(item.text)
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.4)); copied = false }
    }
}

// MARK: - Speech engine

/// The model in use, where it runs, whether it's ready, its memory and load time.
private struct EngineCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let summary = model.engineSummary
        let state = model.models.engineState
        Card(cornerRadius: 26, padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Speech engine").font(.system(size: 15, weight: .semibold)).foregroundStyle(Crystal.ink)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button("Models") { model.section = .models }
                        .cardButton().controlSize(.small)
                }
                HStack(spacing: 12) {
                    IconTile(summary.placement == .remoteHost ? "server.rack" : "brain", color: Crystal.ink2, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Crystal.ink).lineLimit(1)
                        Text(summary.detail).font(.system(size: 11)).foregroundStyle(Crystal.ink2).lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if summary.placement == .neuralEngine {
                    HStack(spacing: 8) {
                        StatusDot(color: state.tint, pulsing: state.isBusy)
                        Text(state.label).font(.system(size: 13)).foregroundStyle(Crystal.ink)
                    }
                    if case .downloading(let f) = state { ProgressView(value: f).tint(Crystal.clientAccent) }
                    VStack(alignment: .leading, spacing: 6) {
                        detail("Memory while loaded", "≈ \(Format.bytes(model.models.activeModel.memoryBytes))")
                        if let load = model.models.lastLoadSeconds {
                            detail("Loaded in", String(format: "%.1f s", load))
                        }
                    }
                } else {
                    HStack(spacing: 8) {
                        StatusDot(color: model.hostStatus.tint, pulsing: model.hostStatus.state == .checking)
                        Text(model.hostStatus.summary).font(.system(size: 13)).foregroundStyle(Crystal.ink).lineLimit(1)
                    }
                    Button("Host Settings") {
                        model.settingsTab = .transcription
                        model.section = .settings
                    }
                    .cardButton().controlSize(.small)
                }
            }
        }
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Crystal.ink2)
            Spacer(minLength: 8)
            Text(value).foregroundStyle(Crystal.ink).monospacedDigit()
        }
        .font(.system(size: 12))
        .accessibilityElement(children: .combine)
    }
}

/// The round dictate button: a flat pink disc, with a stop glyph and a ring that follows the
/// voice while listening.
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
                    ProgressView().controlSize(.small).tint(Crystal.onAccent)
                } else {
                    Image(systemName: listening ? "stop.fill" : "mic.fill")
                        .font(.system(size: size * 0.4, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .foregroundStyle(Crystal.onAccent)
            .frame(width: size, height: size)
            .background(Circle().fill(Crystal.live))
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
