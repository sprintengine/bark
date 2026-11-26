import FairspokenUI
import FairspokenCore
import SwiftUI

/// The floating recording pill: listening (a recording dot and bars that follow the voice, and
/// a timer) → transcribing → inserted / error. One small glass piece that morphs between states.
/// With "Show text while speaking" it grows to show the whole dictation so far, up to
/// `maxLines` lines, following the newest words; the person can scroll up to read earlier ones.
/// Callers place it (it takes only the room it needs).
struct PillView: View {
    var dictation: DictationController
    var shortcut: String
    /// Lines of live text shown before it scrolls (fewer on small screens).
    var maxLines = PillView.defaultMaxLines
    /// The pill's frame (in the window's SwiftUI global space) while it shows live text, which
    /// can be scrolled; nil while it can't. The panel takes the mouse only over that frame.
    var onScrollableFrame: ((CGRect?) -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var follow = ScrollFollow()
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    @State private var textHeight: CGFloat = 0
    @State private var moreAbove = false
    @State private var pillFrame: CGRect = .zero

    /// Width of the live text.
    static let liveTextWidth: CGFloat = 400
    static let liveTextFont = Font.system(size: 13)
    /// One line of `liveTextFont`, with its leading.
    static let liveTextLineHeight: CGFloat = 16
    static let defaultMaxLines = 4
    static let height: CGFloat = 44

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: showsLiveText ? 20 : Self.height / 2, style: .continuous)
    }

    var body: some View {
        content
            .padding(.horizontal, showsLiveText ? 16 : 14)
            .padding(.vertical, showsLiveText ? 12 : 0)
            .frame(minHeight: Self.height)
            // A neutral wash under the glass keeps the text legible over any desktop.
            .background(Plain.card.opacity(scheme == .dark ? 0.45 : 0.6), in: shape)
            .glassEffect(dictation.phase.isListening ? .regular.tint(Crystal.live.opacity(0.08)) : .regular, in: shape)
            // While listening, a fine pink edge: the app's one colour says the microphone is on.
            .overlay {
                if dictation.phase.isListening {
                    shape.strokeBorder(Crystal.live.opacity(scheme == .dark ? 0.55 : 0.45), lineWidth: 1).allowsHitTesting(false)
                }
            }
            .animation(Motion.unlessReduced(Motion.deliberate, reduceMotion), value: stateKey)
            .animation(Motion.unlessReduced(Motion.normal, reduceMotion), value: showsLiveText)
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: { frame in
                pillFrame = frame
                onScrollableFrame?(showsLiveText ? frame : nil)
            }
            .onChange(of: showsLiveText) { _, scrollable in
                onScrollableFrame?(scrollable ? pillFrame : nil)
            }
            .onChange(of: liveText.isEmpty) { _, empty in
                // A new dictation starts following its newest words again.
                if empty {
                    follow.reset()
                    scrollPosition = ScrollPosition(edge: .bottom)
                    moreAbove = false
                    textHeight = 0
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.updatesFrequently)
    }

    private var liveText: String {
        dictation.liveText.split(whereSeparator: \.isWhitespace).joined(separator: " ")
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
                HStack(spacing: 8) {
                    VoiceDot(meter: dictation.meter, active: true)
                    LevelBars(meter: dictation.meter, active: true, bars: 16, color: Crystal.live)
                        .frame(width: 84, height: 22)
                    TimelineView(.periodic(from: since, by: 1)) { ctx in
                        Text(Self.clock(ctx.date.timeIntervalSince(since)))
                            .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(Crystal.ink2)
                            .padding(.leading, 2)
                    }
                    if showsLiveText { Spacer(minLength: 0) }
                    cancelHint
                }
                .accessibilityLabel("Listening")
            }
        case .transcribing:
            VStack(alignment: .leading, spacing: 10) {
                liveTextView
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    // "Retrying the host (1 of 2)" once the first attempt has failed.
                    Text(dictation.transcribingNote ?? "Transcribing").font(.system(size: 13, weight: .semibold)).foregroundStyle(Crystal.ink)
                    if showsLiveText { Spacer(minLength: 0) }
                    cancelHint
                }
                .accessibilityLabel(dictation.transcribingNote ?? "Transcribing")
            }
        case .done(let result):
            HStack(spacing: 8) {
                Image(systemName: icon(for: result.delivery)).foregroundStyle(Crystal.ok)
                    .symbolEffect(.bounce, value: result.text)
                Text(headline(for: result)).font(.system(size: 13, weight: .semibold)).foregroundStyle(Crystal.ink).lineLimit(1)
                // A copy-only message tells the user what to do; it gets the room.
                if case .copied = result.delivery {} else {
                    Text(result.delivery.isRecovered ? "\(result.words) words · in Recent" : "\(result.words) words · \(Format.ms(Double(result.latencyMs)))")
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

    /// A quiet reminder that the cancel key (Escape unless changed) ends the dictation, while
    /// listening and while transcribing.
    @ViewBuilder private var cancelHint: some View {
        if let key = HotkeyController.cancelShortcutSymbols {
            Text(key == "⎋" ? "esc to cancel" : "\(key) to cancel")
                .font(.system(size: 11))
                .foregroundStyle(Crystal.ink3)
                .lineLimit(1)
                .fixedSize()
                .padding(.leading, 2)
                .accessibilityHidden(true)
        }
    }

    /// The words so far, in a few lines that follow the newest words. Scrolling up pauses the
    /// following (a fade at the top says there is more above); scrolling back down resumes it.
    @ViewBuilder private var liveTextView: some View {
        if showsLiveText {
            let maxHeight = Self.liveTextLineHeight * CGFloat(max(1, maxLines))
            ScrollView(.vertical) {
                Text(liveText)
                    .font(Self.liveTextFont)
                    .foregroundStyle(Crystal.ink)
                    .multilineTextAlignment(.leading)
                    .frame(width: Self.liveTextWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .scrollPosition($scrollPosition)
            .scrollIndicators(.never)
            .frame(width: Self.liveTextWidth, height: min(maxHeight, max(Self.liveTextLineHeight, textHeight)))
            // The pill grows a line at a time until it is full, then the text scrolls.
            .animation(Motion.unlessReduced(Motion.normal, reduceMotion), value: min(maxHeight, textHeight))
            .onScrollGeometryChange(for: TextScroll.self) { geometry in
                TextScroll(offset: geometry.visibleRect.minY, content: geometry.contentSize.height,
                           viewport: geometry.containerSize.height)
            } action: { _, scroll in
                textHeight = scroll.content
                moreAbove = ScrollFollow.hasMoreAbove(offset: scroll.offset)
                if follow.update(offset: scroll.offset, contentHeight: scroll.content, viewportHeight: scroll.viewport) {
                    scrollPosition.scrollTo(edge: .bottom)
                }
            }
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(moreAbove ? 0 : 1), .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: 14)
                    Color.black
                }
            }
            .transition(.opacity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(liveText)
        }
    }

    private struct TextScroll: Equatable {
        var offset: CGFloat
        var content: CGFloat
        var viewport: CGFloat
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
        case .recovered: "arrow.clockwise.circle.fill"
        }
    }

    private func headline(for result: DictationController.Result) -> String {
        switch result.delivery {
        case .pasted(let app): app.map { "Inserted into \($0)" } ?? "Inserted"
        case .copied(let reason): reason
        case .shownInApp: "Done"
        case .recovered(let copied): copied ? "Recovered dictation copied" : "Recovered a dictation"
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
