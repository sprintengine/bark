import FairspokenUI
import FairspokenCore
import SwiftUI

/// The floating recording pill: listening (live level + timer) → transcribing → inserted / error.
/// One Liquid Glass capsule that morphs between states. With "Show text while speaking" it
/// grows to show the newest line or two of the words so far, under the level bars.
/// Callers place it (it takes only the room it needs).
struct PillView: View {
    var dictation: DictationController
    var shortcut: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Width of the live text, and how many characters of it the pill shows (two lines of
    /// callout text at this width, so the newest words are never cut off).
    static let liveTextWidth: CGFloat = 380
    static let liveTextCharacters = 104
    static let height: CGFloat = 46

    var body: some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, showsLiveText ? 11 : 0)
            .frame(minHeight: Self.height)
            .glassEffect(dictation.phase.isListening ? .regular.tint(Crystal.live.opacity(0.08)) : .regular,
                         in: RoundedRectangle(cornerRadius: Self.height / 2, style: .continuous))
        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.82), value: stateKey)
        .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: liveText)
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
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    StatusDot(color: Crystal.live, pulsing: true)
                    LevelBars(meter: dictation.meter, active: true, bars: 22, color: Crystal.live)
                        .frame(width: 118, height: 24)
                    TimelineView(.periodic(from: since, by: 1)) { ctx in
                        Text(Self.clock(ctx.date.timeIntervalSince(since)))
                            .font(.system(.callout, design: .rounded).weight(.semibold).monospacedDigit())
                            .foregroundStyle(Crystal.ink2)
                    }
                }
                .accessibilityLabel("Listening")
                liveTextView
            }
        case .transcribing:
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Transcribing").font(.callout.weight(.semibold))
                }
                .accessibilityLabel("Transcribing")
                liveTextView
            }
        case .done(let result):
            HStack(spacing: 9) {
                Image(systemName: icon(for: result.delivery)).foregroundStyle(Crystal.ok)
                    .symbolEffect(.bounce, value: result.text)
                Text(headline(for: result)).font(.callout.weight(.semibold)).lineLimit(1)
                Text("\(result.words) words · \(Format.ms(Double(result.latencyMs)))")
                    .font(.callout).foregroundStyle(Crystal.ink2).lineLimit(1)
            }
        case .failed(let message):
            HStack(spacing: 9) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Crystal.warn)
                Text(message.count > 64 ? message.prefix(62) + "…" : message)
                    .font(.callout.weight(.medium)).lineLimit(1)
            }
        case .idle:
            HStack(spacing: 8) {
                Image(systemName: "waveform").foregroundStyle(Crystal.clientAccent)
                Text("Ready").font(.callout.weight(.medium))
                Text(shortcut).font(.callout).foregroundStyle(Crystal.ink2)
            }
        }
    }

    @ViewBuilder private var liveTextView: some View {
        if showsLiveText {
            Text(liveText)
                .font(.callout)
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
