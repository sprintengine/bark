import FairspokenCore
import FairspokenUI
import SwiftUI

/// Live mic level as rounded bars, redrawn at 30 Hz only while `active`: the last second or so
/// of the voice, newest on the right, scrolling as you speak. With Reduce Motion the bars stay
/// put and light up from the left with the level instead, a calmer meter that still follows the
/// voice.
struct LevelBars: View {
    var meter: LevelMeter
    var active: Bool
    var bars = 24
    var color: Color = Crystal.live
    var minHeight: CGFloat = 3
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.showcaseReduceMotion) private var showcaseReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || showcaseReduceMotion }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !active)) { timeline in
            // Read outside the Canvas: a Canvas whose inputs don't change isn't redrawn, so a
            // meter read inside it froze on its first frame.
            let snap = meter.snapshot(count: reduceMotion ? 0 : bars)
            let reduceMotion = reduceMotion
            Canvas { ctx, size in
                _ = timeline.date
                let gap: CGFloat = 3
                let w = max(2, (size.width - gap * CGFloat(bars - 1)) / CGFloat(bars))
                for i in 0..<bars {
                    let rect: CGRect
                    let opacity: Double
                    if reduceMotion {
                        // A steady meter: bars lit up to the level, the rest dim.
                        let lit = CGFloat(snap.level) * CGFloat(bars) > CGFloat(i) + 0.5
                        let h = max(minHeight, size.height * 0.5)
                        rect = CGRect(x: CGFloat(i) * (w + gap), y: (size.height - h) / 2, width: w, height: h)
                        opacity = active && lit ? 0.9 : 0.22
                    } else {
                        let v = CGFloat(snap.history[i])
                        let h = max(minHeight, v * size.height)
                        rect = CGRect(x: CGFloat(i) * (w + gap), y: (size.height - h) / 2, width: w, height: h)
                        opacity = active ? 0.35 + 0.65 * Double(i) / Double(max(1, bars - 1)) : 0.25
                    }
                    ctx.fill(Path(roundedRect: rect, cornerRadius: min(w, rect.height) / 2), with: .color(color.opacity(opacity)))
                }
            }
        }
        .accessibilityLabel("Microphone level")
    }
}

/// The recording dot, with a halo that swells and brightens with the voice and settles in
/// silence. With Reduce Motion the halo doesn't grow; the dot's glow follows the level instead.
struct VoiceDot: View {
    var meter: LevelMeter
    var active: Bool
    var color: Color = Crystal.live
    var size: CGFloat = 9
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.showcaseReduceMotion) private var showcaseReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || showcaseReduceMotion }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !active)) { _ in
            let level = active ? CGFloat(meter.snapshot().level) : 0
            ZStack {
                if reduceMotion {
                    Circle().fill(color.opacity(0.12 + 0.3 * level))
                        .frame(width: size * 2, height: size * 2)
                } else {
                    Circle().fill(color.opacity(0.10 + 0.22 * level))
                        .frame(width: size * (1.2 + 1.5 * level), height: size * (1.2 + 1.5 * level))
                    Circle().stroke(color.opacity(0.15 + 0.55 * level), lineWidth: 1.5)
                        .frame(width: size * (1.1 + 1.3 * level), height: size * (1.1 + 1.3 * level))
                }
                Circle().fill(color.opacity(reduceMotion ? 0.6 + 0.4 * level : 1))
                    .frame(width: size, height: size)
            }
            .frame(width: size * 2.8, height: size * 2.8)
        }
        .accessibilityHidden(true)
    }
}

extension EnvironmentValues {
    /// Screenshots: draw the meters as with Reduce Motion on (the system setting can't be set
    /// from inside the app).
    @Entry var showcaseReduceMotion = false
}
