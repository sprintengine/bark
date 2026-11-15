import FairspokenUI
import FairspokenCore
import SwiftUI

/// The floating recording pill: listening (live level, timer and the keys that stop or cancel)
/// → transcribing → inserted / error. One small glass piece that morphs between states. With
/// "Show text while speaking" it grows to show the newest line or two of the words so far, over
/// the level and keys. Callers place it (it takes only the room it needs).
struct PillView: View {
    var dictation: DictationController
    var shortcut: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    /// Width of the live text, and how many characters of it the pill shows (two lines of
    /// 13 pt text at this width, so the newest words are never cut off).
    static let liveTextWidth: CGFloat = 400
    static let liveTextCharacters = 104
    static let height: CGFloat = 44

    var body: some View {
        content
            .padding(.horizontal, showsLiveText ? 16 : 14)
            .padding(.vertical, showsLiveText ? 12 : 0)
            .frame(minHeight: Self.height)
            // A light wash under the glass keeps the hints legible over any desktop.
            .background(Crystal.card.opacity(scheme == .dark ? 0.35 : 0.55),
                        in: RoundedRectangle(cornerRadius: showsLiveText ? 20 : Self.height / 2, style: .continuous))
            .glassEffect(dictation.phase.isListening ? .regular.tint(Crystal.live.opacity(0.06)) : .regular,
                         in: RoundedRectangle(cornerRadius: showsLiveText ? 20 : Self.height / 2, style: .continuous))
            .animation(Motion.unlessReduced(Motion.deliberate, reduceMotion), value: stateKey)
            .animation(Motion.unlessReduced(Motion.normal, reduceMotion), value: liveText)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.updatesFrequently)
    }

    private var liveText: String {
        LiveTranscript.displayTail(dictation.liveText, maxCharacters: Self.liveTextCharacters)
    }

    private var showsLiveText: Bool {
        switch dictation.phase {
        case .listening, .transcribing: !liveText.isEmpty
        default: false
        }
    }

    @ViewBuilder private var content: some View {
        switch dictation.phase {
        case .listening(let since):
            VStack(alignment: .leading, spacing: 10) {
                liveTextView
                HStack(spacing: 10) {
                    StatusDot(color: Crystal.live, pulsing: true)
                    LevelBars(meter: dictation.meter, active: true, bars: 18, color: Crystal.live)
                        .frame(width: 84, height: 20)
                    TimelineView(.periodic(from: since, by: 1)) { ctx in
                        Text(Self.clock(ctx.date.timeIntervalSince(since)))
                            .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(Crystal.ink2)
                    }
                    if showsLiveText { Spacer(minLength: 12) } else { divider }
                    hints
                }
                .accessibilityLabel("Listening")
            }
        case .transcribing:
            VStack(alignment: .leading, spacing: 10) {
                liveTextView
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("Transcribing").font(.system(size: 13, weight: .semibold)).foregroundStyle(Crystal.ink)
                }
                .accessibilityLabel("Transcribing")
            }
        case .done(let result):
            HStack(spacing: 8) {
                Image(systemName: icon(for: result.delivery)).foregroundStyle(Crystal.ok)
                    .symbolEffect(.bounce, value: result.text)
                Text(headline(for: result)).font(.system(size: 13, weight: .semibold)).foregroundStyle(Crystal.ink).lineLimit(1)
                // A copy-only message tells the user what to do; it gets the room.
                if case .copied = result.delivery {} else {
                    Text("\(result.words) words · \(Format.ms(Double(result.latencyMs)))")
                        .font(.system(size: 12)).foregroundStyle(Crystal.ink2).lineLimit(1).monospacedDigit()
                }
            }
        case .failed(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Crystal.warn)
                Text(message.count > 64 ? message.prefix(62) + "…" : message)
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Crystal.ink).lineLimit(1)
            }
        case .idle:
            HStack(spacing: 8) {
                Image(systemName: "waveform").foregroundStyle(Crystal.clientAccent)
                Text("Ready").font(.system(size: 13, weight: .medium)).foregroundStyle(Crystal.ink)
                ShortcutCaps(description: HotkeyController.currentShortcutSymbols)
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(Crystal.hairline).frame(width: 1, height: 18)
    }

    /// "Stop ⇧⌘1 · Cancel esc", from the person's own keys and how this recording started.
    private var hints: some View {
        let list = SetupGuide.listeningHints(mode: dictation.shortcutMode, trigger: Self.trigger(dictation.trigger),
                                             shortcut: HotkeyController.currentShortcutSymbols,
                                             cancel: HotkeyController.cancelShortcutSymbols ?? "⎋")
        return HStack(spacing: 6) {
            ForEach(Array(list.enumerated()), id: \.offset) { index, hint in
                if index > 0 { Text("·").foregroundStyle(Crystal.ink3) }
                Text(hint.action).foregroundStyle(Crystal.ink2)
                if let keys = hint.keys { ShortcutCaps(description: keys) }
            }
        }
        .font(.system(size: 12, weight: .medium))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(list.map { [$0.action, $0.keys].compactMap { $0 }.joined(separator: " ") }.joined(separator: ", "))
    }

    static func trigger(_ trigger: DictationController.Trigger) -> SetupGuide.Trigger {
        switch trigger {
        case .hotkey: .shortcut
        case .fn: .fn
        case .button: .button
        }
    }

    @ViewBuilder private var liveTextView: some View {
        if showsLiveText {
            Text(liveText)
                .font(.system(size: 13))
                .foregroundStyle(Crystal.ink)
                .lineLimit(2)
                .truncationMode(.head)
                .multilineTextAlignment(.leading)
                .frame(width: Self.liveTextWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
                .accessibilityLabel(dictation.liveText)
        }
    }

    private var stateKey: Int {
        switch dictation.phase {
        case .idle: 0
        case .listening: 1
        case .transcribing: 2
        case .done: 3
        case .failed: 4
        }
    }

    private func icon(for delivery: DictationController.Delivery) -> String {
        switch delivery {
        case .pasted: "checkmark.circle.fill"
        case .copied: "doc.on.clipboard.fill"
        case .shownInApp: "text.badge.checkmark"
        }
    }

    private func headline(for result: DictationController.Result) -> String {
        switch result.delivery {
        case .pasted(let app): app.map { "Inserted into \($0)" } ?? "Inserted"
        case .copied(let reason): reason
        case .shownInApp: "Done"
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
