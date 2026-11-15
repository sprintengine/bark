import AppKit
import FairspokenCore
import FairspokenUI
import SwiftUI

/// The speed test, in a sheet over Home: type the passage, say it, see the two compared. Its own
/// views, so it can be restyled without touching the rest of Home.
struct SpeedTestSheet: View {
    static let size = CGSize(width: 700, height: 640)

    @Environment(AppModel.self) private var model

    var body: some View {
        let test = model.speedTest
        VStack(spacing: 0) {
            header(test)
                .padding(.horizontal, 28)
                .padding(.top, 22)
                .padding(.bottom, 14)
            Group {
                switch test.step {
                case .typing: TypingStep(test: test)
                case .speaking: SpeakingStep(test: test, dictation: model.dictation, shortcutMode: model.settings.settings.recordingShortcutMode)
                case .results: ResultsStep(test: test)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Crystal.canvas)
        // Names the sheet's window: only a recording started here is measured.
        .background(WindowIdentifier(DictationController.measuredWindow))
        .screenshotActive()
    }

    private func header(_ test: SpeedTestController) -> some View {
        HStack(alignment: .center, spacing: 12) {
            IconTile("gauge.with.needle.fill", color: Crystal.Tile.teal, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Speed test").font(TypeScale.heading).foregroundStyle(Crystal.ink)
                Text("How much faster is your voice than your keyboard?").font(TypeScale.meta).foregroundStyle(Crystal.ink2)
            }
            Spacer(minLength: 12)
            StepDots(step: test.step)
        }
    }
}

/// "1 Type · 2 Speak · 3 Results", the current one in the accent.
private struct StepDots: View {
    var step: SpeedTestController.Step

    var body: some View {
        let steps: [(SpeedTestController.Step, String)] = [(.typing, "Type"), (.speaking, "Speak"), (.results, "Results")]
        let index = steps.firstIndex { $0.0 == step } ?? 0
        HStack(spacing: 10) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, item in
                HStack(spacing: 5) {
                    ZStack {
                        Circle().fill(i <= index ? Crystal.clientAccent : Crystal.well)
                        if i < index {
                            Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Crystal.onAccent)
                        } else {
                            Text("\(i + 1)").font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(i == index ? Crystal.onAccent : Crystal.ink3)
                        }
                    }
                    .frame(width: 16, height: 16)
                    Text(item.1).font(.system(size: 12, weight: i == index ? .semibold : .regular))
                        .foregroundStyle(i == index ? Crystal.ink : Crystal.ink3)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(index + 1) of 3, \(steps[index].1)")
    }
}

// MARK: - Shared pieces

/// Gives the window this view is in an identifier.
private struct WindowIdentifier: NSViewRepresentable {
    var identifier: NSUserInterfaceItemIdentifier
    init(_ identifier: NSUserInterfaceItemIdentifier) { self.identifier = identifier }

    func makeNSView(context: Context) -> NSView { Marker(identifier: identifier) }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class Marker: NSView {
        let mark: NSUserInterfaceItemIdentifier
        init(identifier: NSUserInterfaceItemIdentifier) {
            mark = identifier
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("not used") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.identifier = mark
        }
    }
}

enum SpeedTestFormat {
    /// "1:48".
    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    /// "3.4×".
    static func multiplier(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1))) + "×"
    }

    static func modelName(_ id: String) -> String {
        SpeechModelCatalog.model(id: id)?.shortName ?? id
    }
}

/// The step's footer: secondary actions on the left, the step's actions on the right.
private struct Footer<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Crystal.hairline).frame(height: 1)
            HStack(spacing: 10) {
                leading
                Spacer(minLength: 12)
                trailing
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
        }
        .background(Crystal.card)
    }
}

/// A quiet text button (New passage, Retype, Show times anyway).
private struct LinkButton: View {
    var title: String
    var action: () -> Void
    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Crystal.clientAccent)
    }
}

/// One live number in the typing step.
private struct LiveFigure: View {
    var value: String
    var label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.mvNumber(22)).foregroundStyle(Crystal.ink).monospacedDigit()
            Text(label).font(TypeScale.micro).foregroundStyle(Crystal.ink3)
        }
        .frame(minWidth: 72, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 1 Type

private struct TypingStep: View {
    var test: SpeedTestController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let analysis = SpeedTest.analyzeTyping(test.typed, passage: test.passage)
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Type this passage").font(TypeScale.title).foregroundStyle(Crystal.ink)
                        Text(test.typingStartedAt == nil ? "The clock starts at your first key. Type as you normally would."
                             : "Keep going to the end of the passage.")
                            .font(TypeScale.body).foregroundStyle(Crystal.ink2)
                    }
                    Spacer(minLength: 12)
                    TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                        let seconds = test.typingSeconds()
                        HStack(spacing: 14) {
                            LiveFigure(value: SpeedTestFormat.clock(seconds), label: "elapsed")
                            LiveFigure(value: "\(SpeedTest.netWPM(correctCharacters: analysis.correctCharacters, seconds: seconds))",
                                       label: "wpm")
                            LiveFigure(value: "\(SpeedTest.accuracyPercent(typed: test.typed.count, errors: analysis.errors))%",
                                       label: "accuracy")
                        }
                    }
                }
                // The passage sets the size; the keys go to the invisible field over it.
                Text(Self.styled(analysis))
                    .font(.system(size: 17))
                    .lineSpacing(7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(test.passage)
                    .overlay {
                        TypingField(text: test.typed, onChange: { test.typedChanged($0) },
                                    onPasteRefused: { test.refusedPaste() }, onEscape: { dismiss() })
                    }
                .padding(18)
                .cardSurface()
                if test.pasteRefused {
                    Label("Pasting is off for the test: type it, so the time is real.", systemImage: "hand.raised")
                        .font(TypeScale.meta).foregroundStyle(Crystal.warn)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 4)
            Spacer(minLength: 0)
            Footer {
                LinkButton("New passage") { test.newPassage() }
            } trailing: {
                Button("Cancel") { dismiss() }
                    .cardButton()
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    /// The passage as typed so far: done in ink, mistakes in red (a skipped space as a red gap),
    /// the rest faint, the caret underlined.
    static func styled(_ analysis: SpeedTest.TypingAnalysis) -> AttributedString {
        var out = AttributedString()
        var run = ""
        var runStyle: (SpeedTest.CellState, Bool)?

        func flush() {
            guard let style = runStyle, !run.isEmpty else { return }
            var piece = AttributedString(run)
            switch style.0 {
            case .done: piece.foregroundColor = Crystal.ink
            case .wrong:
                piece.foregroundColor = Crystal.error
                piece.backgroundColor = Crystal.error.opacity(0.16)
            case .pending: piece.foregroundColor = Crystal.ink3.opacity(0.75)
            }
            if style.1 {
                piece.underlineStyle = .init(pattern: .solid, color: Crystal.clientAccent)
                piece.backgroundColor = Crystal.clientAccent.opacity(0.16)
            }
            out += piece
            run = ""
        }

        for (i, cell) in analysis.cells.enumerated() {
            let style = (cell.state, i == analysis.cursor)
            if runStyle.map({ $0.0 != style.0 || $0.1 != style.1 }) ?? true {
                flush()
                runStyle = style
            }
            run.append(cell.character)
        }
        flush()
        return out
    }
}

// MARK: - 2 Speak

private struct SpeakingStep: View {
    var test: SpeedTestController
    var dictation: DictationController
    var shortcutMode: RecordingShortcutMode
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                if let typing = test.typing {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Crystal.ok)
                        Text("Typed in **\(SpeedTestFormat.clock(typing.seconds))** · **\(typing.wpm)** wpm · **\(typing.accuracy)%** accurate")
                            .foregroundStyle(Crystal.ink2)
                    }
                    .font(TypeScale.meta)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Now read it aloud").font(TypeScale.title).foregroundStyle(Crystal.ink)
                    Text("At your natural pace. It's recorded and transcribed with your speech model, then thrown away: nothing is inserted or kept.")
                        .font(TypeScale.body).foregroundStyle(Crystal.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(test.passage)
                    .font(.system(size: 17))
                    .lineSpacing(7)
                    .foregroundStyle(test.isRecording ? Crystal.ink : Crystal.ink.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .cardSurface(selected: test.isRecording ? Crystal.live.opacity(0.55) : nil)
                recorder
                if let error = test.speakingError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(TypeScale.meta).foregroundStyle(Crystal.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 4)
            Spacer(minLength: 0)
            Footer {
                LinkButton("Retype") { test.restartTyping() }
                    .disabled(test.isRecording || test.isTranscribing)
            } trailing: {
                Button("Cancel") { dismiss() }
                    .cardButton()
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    /// The record button and what it is doing: how to start, the level and clock while listening,
    /// the words so far, then transcribing.
    private var recorder: some View {
        HStack(alignment: .center, spacing: 14) {
            DictateButton(dictation: dictation, size: 44) { test.toggleRecording() }
                .disabled(dictation.phase.isActive && !dictation.isMeasuring)
            VStack(alignment: .leading, spacing: 4) {
                if test.isRecording, case .listening(let since) = dictation.phase {
                    HStack(spacing: 10) {
                        LevelBars(meter: dictation.meter, active: true, bars: 24, color: Crystal.live)
                            .frame(width: 130, height: 20)
                        TimelineView(.periodic(from: since, by: 1)) { ctx in
                            Text(SpeedTestFormat.clock(ctx.date.timeIntervalSince(since)))
                                .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                                .foregroundStyle(Crystal.ink)
                        }
                        Text(stopHint).font(TypeScale.meta).foregroundStyle(Crystal.ink3)
                    }
                    if !dictation.liveText.isEmpty {
                        Text(LiveTranscript.displayTail(dictation.liveText, maxCharacters: 110))
                            .font(TypeScale.meta).foregroundStyle(Crystal.ink2)
                            .lineLimit(2).truncationMode(.head)
                    }
                } else if test.isTranscribing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Transcribing…").font(TypeScale.body).foregroundStyle(Crystal.ink2)
                    }
                } else {
                    HStack(spacing: 5) {
                        Text(shortcutMode == .pushToTalk ? "Click the button, or hold" : "Click the button, or press")
                        ShortcutCaps(description: HotkeyController.currentShortcutSymbols)
                        Text(shortcutMode == .pushToTalk ? "while you read." : "to start.")
                    }
                    .font(TypeScale.body).foregroundStyle(Crystal.ink)
                    Text("Stop when you reach the end; the time runs from start to stop.")
                        .font(TypeScale.meta).foregroundStyle(Crystal.ink3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .well(cornerRadius: CardMetrics.radius)
    }

    private var stopHint: String {
        dictation.trigger == .button || shortcutMode == .toggle ? "Click or press the shortcut to stop · esc to cancel"
            : "Let go to stop · esc to cancel"
    }
}

// MARK: - 3 Results

private struct ResultsStep: View {
    var test: SpeedTestController
    @Environment(\.dismiss) private var dismiss
    @State private var showsHeard = false

    var body: some View {
        if let outcome = test.outcome {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let reason = outcome.notKept {
                            // Not a fair run: say why first; the times only on request.
                            notKeptHeadline(reason, outcome)
                            if test.showsGatedTimes { comparison(outcome) }
                            if reason == .roughTranscript { HeardComparison(comparison: outcome.comparison) }
                        } else {
                            headline(outcome)
                            comparison(outcome)
                            notes(outcome)
                            DisclosureGroup(isExpanded: $showsHeard) {
                                HeardComparison(comparison: outcome.comparison).padding(.top, 8)
                            } label: {
                                Text("What was heard").font(.system(size: 12, weight: .medium)).foregroundStyle(Crystal.ink2)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.top, 4)
                    .padding(.bottom, 18)
                }
                .scrollBounceBehavior(.basedOnSize)
                Footer {
                    if outcome.notKept != nil && !test.showsGatedTimes {
                        LinkButton("Show times anyway") { test.showGatedTimes() }
                    } else {
                        LinkButton("Try another passage") { test.newPassage() }
                    }
                } trailing: {
                    if let reason = outcome.notKept {
                        Button("Close") { dismiss() }.cardButton().keyboardShortcut(.cancelAction)
                        Group {
                            if reason == .roughTranscript {
                                Button("Read It Again") { test.speakAgain() }
                            } else {
                                Button("Type It Again") { test.restartTyping() }
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle(large: true))
                        .keyboardShortcut(.defaultAction)
                    } else {
                        Button("Done") { dismiss() }
                            .buttonStyle(PrimaryButtonStyle(large: true))
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
    }

    private func headline(_ o: SpeedTest.Outcome) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("You spoke \(Text(SpeedTestFormat.multiplier(o.multiplier)).foregroundStyle(Crystal.clientAccent)) \(o.multiplier >= 1 ? "faster than you typed" : "as fast as you typed")")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Crystal.ink)
                if test.isNewBest && SpeedTest.isKeepable(o) {
                    Text("New best").font(.system(size: 11, weight: .semibold)).foregroundStyle(Crystal.onAccent)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Crystal.clientAccent, in: .capsule)
                }
            }
            if o.secondsSaved >= 1 {
                Text("Speaking saved \(SpeedTestFormat.clock(o.secondsSaved)) on these \(o.words) words.")
                    .font(TypeScale.body).foregroundStyle(Crystal.ink2)
            }
        }
    }

    /// Why a run isn't kept, in place of the result.
    private func notKeptHeadline(_ reason: SpeedTest.NotKept, _ o: SpeedTest.Outcome) -> some View {
        let (symbol, title, detail): (String, String, String) = switch reason {
        case .roughTranscript:
            ("exclamationmark.bubble.fill", "Only \(o.comparison.hits) of \(o.comparison.total) words came through",
             "A fast time on a rough transcript isn't a real result, so this run isn't kept. Read it again a little more clearly, or check the microphone in Settings.")
        case .inaccurateTyping:
            ("keyboard.fill", "Only \(o.typing.accuracy)% of the typing was accurate",
             "Under \(SpeedTest.typingAccuracyGate)%, the time isn't a fair measure of your typing, so this run isn't kept. Type it again at a pace you can keep accurate.")
        case .typingPaused:
            ("pause.circle.fill", "Your typing paused for over \(Int(SpeedTest.typingPauseLimit)) s",
             "A pause that long isn't typing speed, so this run isn't kept. Type the passage again in one go.")
        case .unmeasured:
            ("clock.badge.exclamationmark", "This run couldn't be timed",
             "One of the two legs has no time, so this run isn't kept. Try again.")
        }
        return HStack(alignment: .top, spacing: 12) {
            IconTile(symbol, color: Crystal.Tile.orange, size: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 20, weight: .semibold)).foregroundStyle(Crystal.ink)
                Text(detail).font(TypeScale.body).foregroundStyle(Crystal.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Typed beside spoken: the time each took, the pace, the accuracy, then the times as bars.
    private func comparison(_ o: SpeedTest.Outcome) -> some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    LegColumn(title: "Typed", swatch: Crystal.Tile.gray, seconds: o.typing.seconds, words: o.words,
                              wpm: o.typing.wpm, accuracy: "\(o.typing.accuracy)% accurate")
                    Rectangle().fill(Crystal.hairline).frame(width: 1).padding(.vertical, 14)
                    LegColumn(title: "Spoke", swatch: Crystal.clientAccent, seconds: o.speakingSeconds, words: o.words,
                              wpm: o.speakingWPM, accuracy: "\(o.comparison.accuracy)% heard correctly")
                }
                .fixedSize(horizontal: false, vertical: true)
                Rectangle().fill(Crystal.hairline).frame(height: 1)
                TimeBars(typed: o.typing.seconds, spoken: o.speakingSeconds)
                    .padding(16)
                if let reason = o.notKept {
                    Text(Self.notKeptText(reason, o))
                        .font(TypeScale.micro).foregroundStyle(Crystal.ink3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.bottom, 12)
                }
            }
        }
    }

    static func notKeptText(_ reason: SpeedTest.NotKept, _ o: SpeedTest.Outcome) -> String {
        switch reason {
        case .roughTranscript: "Not kept: the transcript was too rough to count."
        case .inaccurateTyping: "Not kept: under \(SpeedTest.typingAccuracyGate)% of the typing was accurate."
        case .typingPaused: "Not kept: the typing paused for over \(Int(SpeedTest.typingPauseLimit)) s, so its time isn't your typing speed."
        case .unmeasured: "Not kept: a leg had no time."
        }
    }

    /// Whether Home's time saved should use this typing speed (the user's choice), and how the
    /// reading was transcribed.
    private func notes(_ o: SpeedTest.Outcome) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if SpeedTest.isKeepable(o) {
                if test.typingSpeedAdopted || test.typingSpeedInUse == o.typing.wpm {
                    Label("Time saved on Home counts typing at \(o.typing.wpm) wpm, your speed.", systemImage: "checkmark.circle")
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "house")
                        LinkButton("Use \(o.typing.wpm) wpm for time saved on Home") { test.adoptTypingSpeed() }
                        Text("now \(test.typingSpeedInUse.map { "\($0) wpm, an earlier test" } ?? "\(Int(UsageStats.typingWPM)) wpm, a typical pace")")
                            .foregroundStyle(Crystal.ink3)
                    }
                }
            }
            if let m = test.measured {
                Label(m.placement == .remoteHost
                      ? "Transcribed in \(Format.ms(Double(m.transcribeMs))) by your transcription host. Nothing was inserted or kept on this Mac."
                      : "Transcribed in \(Format.ms(Double(m.transcribeMs))) by \(SpeedTestFormat.modelName(m.model)) on this Mac. Nothing was inserted or kept.",
                      systemImage: "waveform")
            }
        }
        .font(TypeScale.meta)
        .foregroundStyle(Crystal.ink2)
    }
}

private struct LegColumn: View {
    var title: String
    var swatch: Color
    var seconds: Double
    var words: Int
    var wpm: Int
    var accuracy: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(swatch).frame(width: 10, height: 10)
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Crystal.ink2)
            }
            Text(SpeedTestFormat.clock(seconds)).font(.mvNumber(30)).foregroundStyle(Crystal.ink)
            Text("\(words) words · \(wpm) wpm").font(TypeScale.body).foregroundStyle(Crystal.ink).monospacedDigit()
            Text(accuracy).font(TypeScale.meta).foregroundStyle(Crystal.ink3)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The two times as bars on one scale.
private struct TimeBars: View {
    var typed: Double
    var spoken: Double

    var body: some View {
        let longest = max(typed, spoken, 0.001)
        VStack(spacing: 8) {
            bar("Typed", typed / longest, SpeedTestFormat.clock(typed), Crystal.Tile.gray)
            bar("Spoke", spoken / longest, SpeedTestFormat.clock(spoken), Crystal.clientAccent)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Typed in \(SpeedTestFormat.clock(typed)), spoke in \(SpeedTestFormat.clock(spoken))")
    }

    private func bar(_ label: String, _ fraction: Double, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 10) {
            Text(label).font(TypeScale.meta).foregroundStyle(Crystal.ink2).frame(width: 42, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Crystal.well)
                    Capsule().fill(color).frame(width: max(6, geo.size.width * min(1, fraction)))
                }
            }
            .frame(height: 10)
            Text(value).font(TypeScale.meta.monospacedDigit()).foregroundStyle(Crystal.ink).frame(width: 40, alignment: .trailing)
        }
    }
}

/// The passage marked by what came through (dropped words struck through, words heard
/// differently highlighted), and the transcript itself with its extra and changed words marked.
struct HeardComparison: View {
    var comparison: TranscriptComparison

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("The passage").font(.system(size: 11, weight: .semibold)).foregroundStyle(Crystal.ink3)
            Text(Self.passage(comparison)).font(TypeScale.body).lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("What was heard").font(.system(size: 11, weight: .semibold)).foregroundStyle(Crystal.ink3).padding(.top, 4)
            if comparison.heard.isEmpty {
                Text("Nothing came back from the transcription.").font(TypeScale.body).foregroundStyle(Crystal.ink3)
            } else {
                Text(Self.heard(comparison)).font(TypeScale.body).lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            HStack(spacing: 14) {
                legend(Crystal.error, "Not heard", strike: true)
                legend(Crystal.warn, "Heard differently or extra", strike: false)
            }
            .padding(.top, 2)
        }
        .padding(14)
        .well(cornerRadius: CardMetrics.radius)
    }

    private func legend(_ color: Color, _ text: String, strike: Bool) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.35)).frame(width: 12, height: 8)
            Text(text)
        }
        .font(TypeScale.micro).foregroundStyle(Crystal.ink3)
    }

    static func passage(_ c: TranscriptComparison) -> AttributedString {
        join(c.target) { token, piece in
            switch token.state {
            case .hit: piece.foregroundColor = Crystal.ink
            case .miss:
                piece.foregroundColor = Crystal.error
                piece.strikethroughStyle = .single
                piece.backgroundColor = Crystal.error.opacity(0.12)
            case .substituted, .inserted:
                piece.foregroundColor = Crystal.warn
                piece.backgroundColor = Crystal.warn.opacity(0.14)
            }
        }
    }

    static func heard(_ c: TranscriptComparison) -> AttributedString {
        join(c.heard) { token, piece in
            if token.state == .hit {
                piece.foregroundColor = Crystal.ink2
            } else {
                piece.foregroundColor = Crystal.warn
                piece.backgroundColor = Crystal.warn.opacity(0.14)
            }
        }
    }

    private static func join(_ tokens: [TranscriptComparison.Token],
                             style: (TranscriptComparison.Token, inout AttributedString) -> Void) -> AttributedString {
        var out = AttributedString()
        for (i, token) in tokens.enumerated() {
            if i > 0 { out += AttributedString(" ") }
            var piece = AttributedString(token.raw)
            style(token, &piece)
            out += piece
        }
        return out
    }
}
