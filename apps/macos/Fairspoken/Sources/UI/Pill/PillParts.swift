import FairspokenCore
import FairspokenUI
import Observation
import SwiftUI

/// What the floating panel needs from the pill it shows, and the style menu's state. The pill
/// writes its frames (hosting-view coordinates, top-left origin); `PillController` turns them
/// into screen rects to decide where the panel takes the mouse, and opens the menu.
@MainActor
@Observable
final class PillInteraction {
    var capsuleFrame: CGRect = .zero
    /// The capsule has buttons now (cancel, the style chip, finish, Retry).
    var capsuleTakesMouse = false
    /// Its live text can be scrolled.
    var scrollable = false
    var chipFrame: CGRect?
    /// The style menu is open.
    private(set) var menuOpen = false
    /// It was opened by resting the pointer on the chip, so it closes when the pointer leaves;
    /// opened with a click (or VoiceOver) it stays until a choice, a click elsewhere, or the end
    /// of the recording.
    private(set) var openedByHover = false
    /// The chip is under the pointer (drawn raised).
    var chipHovered = false
    /// A click on the chip closed the menu: resting there doesn't open it again until the
    /// pointer has left the chip.
    @ObservationIgnored var hoverSuppressed = false
    @ObservationIgnored var onMenuChange: ((Bool) -> Void)?

    func openMenu(byHover: Bool) {
        if menuOpen {
            // A click on a menu the pointer opened pins it.
            if !byHover { openedByHover = false }
            return
        }
        openedByHover = byHover
        menuOpen = true
        onMenuChange?(true)
    }

    func closeMenu() {
        guard menuOpen else { return }
        menuOpen = false
        openedByHover = false
        onMenuChange?(false)
    }

    /// A click on the chip: opens the menu, or closes one it had pinned open.
    func chipClicked() {
        if menuOpen, !openedByHover {
            closeMenu()
            hoverSuppressed = true
        } else {
            openMenu(byHover: false)
        }
    }
}

// MARK: - Buttons

/// A round 28 pt icon button: muted at rest, a light fill under the pointer.
struct PillIconButton: View {
    var symbol: String
    var label: String
    var help: String
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(hovered ? Crystal.ink : Crystal.ink2)
                .frame(width: 28, height: 28)
                .background(hovered ? Crystal.rowHover : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
        .accessibilityLabel(label)
    }
}

/// Finish: the one blue thing on the pill, a round button with a check.
struct PillFinishButton: View {
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Crystal.onAccent)
                .frame(width: 28, height: 28)
                .background(Crystal.primary.opacity(hovered ? 0.88 : 1), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Finish and paste")
        .accessibilityLabel("Finish")
    }
}

/// A ghost text button in the capsule ("Retry").
struct PillTextButton: View {
    var title: String
    var color: Color
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(color)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(hovered ? color.opacity(0.12) : .clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// The state's glyph in a 24 pt circle at the capsule's start.
struct PillGlyph: View {
    var symbol: String
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Crystal.ink)
            .frame(width: 24, height: 24)
            .accessibilityHidden(true)
    }
}

/// A 14 pt ring with one lit segment, turning; still with Reduce Motion.
struct PillSpinner: View {
    var reduceMotion: Bool
    @State private var turning = false

    var body: some View {
        ZStack {
            Circle().stroke(Crystal.ink.opacity(0.14), lineWidth: 2)
            Circle().trim(from: 0, to: 0.25).stroke(Crystal.ink2, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(turning ? 360 : 0))
        }
        .frame(width: 14, height: 14)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) { turning = true }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Waveform

/// The voice as 24 thin bars, newest on the right: each bar's height and strength follow the
/// level it was recorded at (0.2 at rest). With Reduce Motion the bars hold still at a fixed
/// height and light up from the left with the level instead.
struct VoiceWaveform: View {
    var meter: LevelMeter
    var reduceMotion: Bool
    var bars = 24
    /// Before a recording: every bar at rest.
    var resting = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: resting)) { timeline in
            let snap = meter.snapshot(count: resting || reduceMotion ? 0 : bars)
            let reduceMotion = reduceMotion
            let resting = resting
            let bars = bars
            Canvas { ctx, size in
                _ = timeline.date
                let w: CGFloat = 2, gap: CGFloat = 2
                let total = CGFloat(bars) * w + CGFloat(bars - 1) * gap
                let x0 = size.width - total
                for i in 0..<bars {
                    let level: CGFloat
                    let height: CGFloat
                    if resting {
                        level = 0
                        height = 0.2
                    } else if reduceMotion {
                        level = CGFloat(snap.level) * CGFloat(bars) > CGFloat(i) + 0.5 ? 1 : 0
                        height = 0.4
                    } else {
                        level = CGFloat(snap.history[i])
                        height = max(0.2, level)
                    }
                    let h = size.height * height
                    let rect = CGRect(x: x0 + CGFloat(i) * (w + gap), y: (size.height - h) / 2, width: w, height: h)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(Crystal.ink.opacity(0.3 + 0.55 * level)))
                }
            }
        }
        .frame(height: 16)
        .accessibilityHidden(true)
    }
}

// MARK: - Style chip and menu

/// "Email · Mail rule" on the listening pill. Resting the pointer on it (or clicking it) opens
/// the style menu; a terminal or a secure field shows "Verbatim" with a lock and no menu.
struct StyleChip: View {
    var state: StyleChipState
    var interaction: PillInteraction?
    var showcaseHover = false

    var body: some View {
        let raised = showcaseHover || (interaction?.chipHovered ?? false) || (interaction?.menuOpen ?? false)
        Button {
            interaction?.chipClicked()
        } label: {
            HStack(spacing: 5) {
                if state.isLocked {
                    Image(systemName: "lock.fill").font(.system(size: 8.5, weight: .semibold)).foregroundStyle(Crystal.ink3)
                } else {
                    TypeGlyph(size: 11, color: Crystal.ink2)
                }
                Text(state.style.displayName).foregroundStyle(Crystal.ink)
                Text("· \(state.reason)").foregroundStyle(Crystal.ink2)
                if !state.isLocked {
                    Image(systemName: "chevron.down").font(.system(size: 7.5, weight: .bold)).foregroundStyle(Crystal.ink3)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(raised && !state.isLocked ? Crystal.selected : Crystal.keyFill, in: Capsule())
            .overlay { if raised && !state.isLocked { Capsule().strokeBorder(Crystal.input) } }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(state.isLocked)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            interaction?.chipFrame = state.isLocked ? nil : frame
        }
        .onDisappear { interaction?.chipFrame = nil }
        .help(state.isLocked ? "\(state.reason)s always get your words as spoken" : "Change the style of this dictation")
        .accessibilityLabel(state.accessibilityLabel)
        .accessibilityHint(state.isLocked ? "" : "Opens the styles for this dictation")
    }
}

/// The style menu over the pill: every style with the current one ticked, the way back to the
/// rules after a choice, and "Always use … for …". Drawn as the app's menus are (a solid card,
/// a hairline, 4 pt inset, 8 pt corners); its panel never takes the keyboard.
struct StyleMenuView: View {
    var state: StyleChipState
    var onStyle: (DictationStyle.ID) -> Void
    var onRules: () -> Void
    var onAlwaysUse: (DictationStyle.ID) -> Void
    /// Screenshots: the row drawn as if under the pointer.
    var showcaseHighlight: String?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("This dictation")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Crystal.ink3)
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .padding(.bottom, 2)
                .accessibilityAddTraits(.isHeader)
            ForEach(state.entries) { entry in
                switch entry {
                case .style(let style, let checked):
                    StyleMenuRow(title: style.displayName, detail: nil, checked: checked, symbol: nil,
                                 help: style.summary, highlighted: showcaseHighlight == entry.id) { onStyle(style) }
                case .useRules(let title):
                    Divider().padding(.vertical, 4).padding(.horizontal, -4)
                    StyleMenuRow(title: title, detail: nil, checked: false, symbol: "arrow.uturn.backward",
                                 help: "Use what your rules give this app", highlighted: showcaseHighlight == entry.id) { onRules() }
                case .alwaysUse(let title, let style):
                    if !state.entries.contains(where: { if case .useRules = $0 { true } else { false } }) {
                        Divider().padding(.vertical, 4).padding(.horizontal, -4)
                    }
                    StyleMenuRow(title: title, detail: nil, checked: false, symbol: "pin",
                                 help: "Saves a rule; change it in Settings", highlighted: showcaseHighlight == entry.id) { onAlwaysUse(style) }
                }
            }
        }
        .padding(4)
        // As wide as its longest row ("Always use Document for docs.google.com"), within reason.
        .frame(minWidth: 236, maxWidth: 340, alignment: .leading)
        .fixedSize()
        .background {
            // The shadow is the card's alone, so a highlighted row doesn't cast one.
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(Crystal.card)
                .shadow(color: .black.opacity(scheme == .dark ? 0.55 : 0.16), radius: 14, y: 10)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Crystal.hairline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Styles for this dictation")
    }
}

private struct StyleMenuRow: View {
    var title: String
    var detail: String?
    var checked: Bool
    var symbol: String?
    var help: String
    var highlighted = false
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Group {
                    if checked {
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Crystal.ink)
                    } else if let symbol {
                        Image(systemName: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(Crystal.ink2)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 16)
                Text(title).font(.system(size: 13)).foregroundStyle(Crystal.ink).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(hovered || highlighted ? Crystal.selected : .clear, in: .rect(cornerRadius: 4, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
        .accessibilityAddTraits(checked ? .isSelected : [])
    }
}
