import FairspokenUI
import FairspokenCore
import SwiftUI

/// The floating recording pill: an opaque voice capsule (a solid card, a hairline ring and a
/// soft shadow; nothing behind it shows through). Listening: cancel, the recording dot, a timer,
/// the style this dictation will get, a waveform that follows the voice, and finish. Then
/// transcribing, and what happened: where the words went, a clipboard fallback, nothing heard,
/// a microphone that wouldn't start, or a recording saved to retry.
///
/// With "Show text while speaking" it grows to show the whole dictation so far, up to
/// `maxLines` lines, following the newest words; the person can scroll up to read earlier ones.
/// Callers place it (it takes only the room it needs).
struct PillView: View {
    var dictation: DictationController
    var shortcut: String
    /// Lines of live text shown before it scrolls (fewer on small screens).
    var maxLines = PillView.defaultMaxLines
    /// The floating panel's side of things: frames for the mouse, the style menu. Nil in a
    /// window of Bark's own (screenshots), where the pill is only drawn.
    var interaction: PillInteraction?
    /// Where a dictation on Bark Server ran ("build-box"), said once when it lands.
    var serverName: String?
    /// Screenshots: draw the style chip as if under the pointer.
    var showcaseChipHover = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.showcaseReduceMotion) private var showcaseReduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var follow = ScrollFollow()
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    @State private var textHeight: CGFloat = 0
    @State private var moreAbove = false

    private var reduceMotion: Bool { systemReduceMotion || showcaseReduceMotion }

    /// Width of the pill while it shows live text, and of the text in it.
    static let liveWidth: CGFloat = 404
    static let liveTextWidth: CGFloat = liveWidth - 28
    static let liveTextFont = Font.system(size: 14)
    /// One line of `liveTextFont`, with its leading.
    static let liveTextLineHeight: CGFloat = 20
    static let defaultMaxLines = 4
    static let height: CGFloat = 36
    /// Whether the cancel button stays while transcribing: only once the controller can drop a
    /// transcript that is still on its way (otherwise it would land after the pill said
    /// cancelled). The "esc" hint follows it.
    static let cancelsWhileTranscribing = false

    private var showsLiveText: Bool {
        switch dictation.phase {
        case .listening, .transcribing: !liveText.isEmpty
        default: false
        }
    }

    private var liveText: String {
        dictation.liveText.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private var failure: PillPresentation.Failure? {
        if case .failed(let message) = dictation.phase { PillPresentation.failure(message) } else { nil }
    }

    private var isErrorTone: Bool { failure?.isError ?? false }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: showsLiveText ? 18 : Self.height / 2, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            liveTextView
            row
        }
        .frame(width: showsLiveText ? Self.liveWidth : nil)
        .background { surface }
        .compositingGroup()
        .shadow(color: .black.opacity(scheme == .dark ? 0.6 : 0.16), radius: 14, y: 10)
        .animation(Motion.unlessReduced(Motion.deliberate, reduceMotion), value: stateKey)
        .animation(Motion.unlessReduced(Motion.normal, reduceMotion), value: showsLiveText)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            interaction?.capsuleFrame = frame
        }
        .onChange(of: takesMouse, initial: true) { _, takes in interaction?.capsuleTakesMouse = takes }
        .onChange(of: showsLiveText, initial: true) { _, scrollable in interaction?.scrollable = scrollable }
        .onChange(of: liveText.isEmpty) { _, empty in
            // A new dictation starts following its newest words again.
            if empty {
                follow.reset()
                scrollPosition = ScrollPosition(edge: .bottom)
                moreAbove = false
                textHeight = 0
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Dictation")
    }

    /// The opaque capsule: the card colour (a red wash for errors), a 1 pt ring.
    @ViewBuilder private var surface: some View {
        let ring = isErrorTone ? Crystal.recording.opacity(0.28)
            : (scheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.10))
        shape.fill(Crystal.card)
            .overlay { if isErrorTone { shape.fill(Crystal.recording.opacity(scheme == .dark ? 0.07 : 0.05)) } }
            .overlay { shape.strokeBorder(ring, lineWidth: 1) }
    }

    /// The pill has buttons in it now, so the panel takes the mouse over it.
    private var takesMouse: Bool {
        switch dictation.phase {
        case .listening: true
        case .transcribing: Self.cancelsWhileTranscribing || showsLiveText
        case .failed: failure?.canRetry ?? false
        default: false
        }
    }

    // MARK: The row

    @ViewBuilder private var row: some View {
        switch dictation.phase {
        case .listening(let since): listeningRow(since: since)
        case .transcribing: transcribingRow
        case .done(let result): doneRow(result)
        case .failed: if let failure { failureRow(failure) }
        case .idle: readyRow
        }
    }

    private func listeningRow(since: Date) -> some View {
        HStack(spacing: 6) {
            PillIconButton(symbol: "xmark", label: "Cancel", help: "Cancel (\(Self.cancelKey ?? "esc"))") { dictation.cancel() }
            cancelHint.padding(.leading, -4)
            Circle().fill(Crystal.recording).frame(width: 8, height: 8).padding(.leading, 2).accessibilityHidden(true)
            TimelineView(.periodic(from: since, by: 1)) { ctx in
                Text(Self.clock(ctx.date.timeIntervalSince(since)))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Crystal.ink2)
                    .accessibilityLabel("Listening, \(Self.spokenClock(ctx.date.timeIntervalSince(since)))")
            }
            if let chip = chipState {
                StyleChip(state: chip, interaction: interaction, showcaseHover: showcaseChipHover)
                    .padding(.leading, 2)
            }
            VoiceWaveform(meter: dictation.meter, reduceMotion: reduceMotion)
                .frame(minWidth: 94, maxWidth: showsLiveText ? .infinity : 94, alignment: .trailing)
                .padding(.horizontal, 2)
            PillFinishButton { dictation.stop() }
        }
        .padding(.horizontal, 4)
        .frame(height: Self.height)
    }

    private var chipState: StyleChipState? {
        guard !dictation.isMeasuring else { return nil }
        return StyleChipState(resolution: dictation.currentStyle, rulesResolution: dictation.rulesStyle,
                              target: dictation.alwaysUseTarget)
    }

    private var transcribingRow: some View {
        let cancels = Self.cancelsWhileTranscribing
        let label = dictation.transcribingNote ?? "Transcribing"
        return HStack(spacing: 6) {
            if cancels {
                PillIconButton(symbol: "xmark", label: "Cancel", help: "Cancel (\(Self.cancelKey ?? "esc"))") { dictation.cancel() }
                cancelHint.padding(.leading, -4)
            }
            PillSpinner(reduceMotion: reduceMotion).padding(.leading, cancels ? 2 : 0)
            // "Retrying the host (1 of 2)", "Transcribing on this Mac" once the first try failed.
            Text(label + "…")
                .font(.system(size: 13))
                .foregroundStyle(Crystal.ink2)
                .lineLimit(1)
                .padding(.leading, 2)
                .accessibilityLabel(label)
            if showsLiveText { Spacer(minLength: 0) }
        }
        .padding(.leading, cancels ? 4 : 12)
        .padding(.trailing, 14)
        .frame(height: Self.height)
    }

    @ViewBuilder private func doneRow(_ result: DictationController.Result) -> some View {
        switch result.delivery {
        case .copied(let reason):
            HStack(spacing: 6) {
                PillGlyph(symbol: "doc.on.clipboard")
                Text("Copied to the clipboard").font(.system(size: 13, weight: .medium)).foregroundStyle(Crystal.ink)
                if let detail = PillPresentation.copiedDetail(reason) {
                    Text(detail).font(.system(size: 13)).foregroundStyle(Crystal.ink2).lineLimit(1)
                }
                Keycap(label: "⌘V").padding(.leading, 2)
                Text("to paste").font(.system(size: 13)).foregroundStyle(Crystal.ink2)
            }
            .padding(.leading, 6)
            .padding(.trailing, 12)
            .frame(height: Self.height)
            .accessibilityElement(children: .combine)
        default:
            HStack(spacing: 6) {
                PillGlyph(symbol: result.delivery.isRecovered ? "arrow.clockwise" : "checkmark")
                    .symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion ? 0 : result.words)
                Text(Self.headline(result)).font(.system(size: 13, weight: .medium)).foregroundStyle(Crystal.ink).lineLimit(1)
                Text("· " + Self.detail(result, serverName: serverName))
                    .font(.system(size: 13)).foregroundStyle(Crystal.ink2).lineLimit(1).monospacedDigit()
            }
            .padding(.leading, 6)
            .padding(.trailing, 14)
            .frame(height: Self.height)
            .accessibilityElement(children: .combine)
        }
    }

    private func failureRow(_ failure: PillPresentation.Failure) -> some View {
        let tone = failure.isError ? Crystal.error : Crystal.ink
        return HStack(spacing: 6) {
            if failure.isError {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 13, weight: .medium)).foregroundStyle(tone)
                    .frame(width: 18).accessibilityHidden(true)
            } else {
                PillGlyph(symbol: Self.symbol(for: failure.kind))
            }
            Text(failure.title).font(.system(size: 13, weight: failure.isError ? .regular : .medium)).foregroundStyle(tone).lineLimit(1)
            if let detail = failure.detail {
                Text(detail).font(.system(size: 13)).foregroundStyle(failure.isError ? tone.opacity(0.75) : Crystal.ink2).lineLimit(1)
            }
            if failure.canRetry {
                PillTextButton(title: "Retry", color: Crystal.error) { dictation.start(.button) }
            }
        }
        .padding(.leading, failure.isError ? 12 : 6)
        .padding(.trailing, failure.canRetry ? 2 : 14)
        .frame(height: Self.height)
        .accessibilityElement(children: .combine)
    }

    /// Before a recording (screenshots and the demo only: the floating pill hides when idle).
    private var readyRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform").font(.system(size: 13)).foregroundStyle(Crystal.ink2).frame(width: 28, height: 28)
            VoiceWaveform(meter: dictation.meter, reduceMotion: true, bars: 14, resting: true).frame(width: 54)
            Keycap(label: shortcut).padding(.leading, 4)
        }
        .padding(.leading, 4)
        .padding(.trailing, 10)
        .frame(height: Self.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Ready, \(shortcut) to dictate")
    }

    /// A quiet reminder that the cancel key (Escape unless changed) ends the dictation.
    @ViewBuilder private var cancelHint: some View {
        if let key = Self.cancelKey {
            Text(key)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Crystal.ink3)
                .lineLimit(1)
                .fixedSize()
                .accessibilityHidden(true)
        }
    }

    static var cancelKey: String? {
        HotkeyController.cancelShortcutSymbols.map { $0 == "⎋" ? "esc" : $0 }
    }

    // MARK: Live text

    /// The words so far, in a few lines that follow the newest words. Scrolling up pauses the
    /// following (a fade at the top says there is more above); scrolling back down resumes it.
    @ViewBuilder private var liveTextView: some View {
        if showsLiveText {
            let maxHeight = Self.liveTextLineHeight * CGFloat(max(1, maxLines))
            ScrollView(.vertical) {
                Text(liveText)
                    .font(Self.liveTextFont)
                    .lineSpacing(3)
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
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .transition(.opacity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(liveText)
            .accessibilityAddTraits(.updatesFrequently)
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

    // MARK: Words

    static func headline(_ result: DictationController.Result) -> String {
        switch result.delivery {
        case .pasted(let app): app.map { "Pasted into \($0)" } ?? "Pasted"
        case .copied: "Copied to the clipboard"
        case .shownInApp: "Added in \(AppInfo.displayName)"
        case .recovered(let copied): copied ? "A saved dictation, copied" : "A saved dictation is done"
        }
    }

    /// "38 words", "38 words · via build-box" (Bark Server, said once, as it lands), "in history".
    static func detail(_ result: DictationController.Result, serverName: String?) -> String {
        let words = "\(result.words) word\(result.words == 1 ? "" : "s")"
        if result.delivery.isRecovered { return "\(words) · in history" }
        if result.placement == .remoteHost { return "\(words) · via \(serverName ?? "Bark Server")" }
        return words
    }

    static func symbol(for kind: PillPresentation.Failure.Kind) -> String {
        switch kind {
        case .nothingHeard: "waveform.slash"
        case .tooShort: "timer"
        case .savedToRetry: "clock.arrow.circlepath"
        case .microphone: "mic.slash"
        case .other: "exclamationmark.triangle"
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    static func spokenClock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s < 60 ? "\(s) seconds" : "\(s / 60) minutes \(s % 60) seconds"
    }
}
