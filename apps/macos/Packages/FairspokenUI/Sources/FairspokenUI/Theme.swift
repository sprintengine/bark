import AppKit
import SwiftUI

/// Brand tokens for the dictation client: the Crystal theme's green hint, and the live
/// microphone colour. Fairspoken Server uses `Crystal.serverAccent` (design/crystal/README.md).
public enum Brand {
    public static var accent: Color { Crystal.clientAccent }
    public static var secondary: Color { Crystal.ink2 }
    public static var live: Color { Crystal.live }
}

/// Crystal: a frosted sidebar beside opaque content, with one subtle accent: green for the
/// clients, red for the server. Tokens match design/crystal/README.md.
///
/// The material rule: only the window's chrome (the sidebar) is frosted, and the frost is tinted
/// once (`frostTint`). Content stands on an opaque ground (`canvas`) in solid cards (`card`) with a
/// hairline edge, so nothing translucent stacks on anything translucent. Glass is kept for small
/// floating pieces: the recording pill, toasts and popovers.
public enum Crystal {
    public static let page = Color(hex: 0xEDEFF2, dark: 0x0D0F12)
    public static let pageSheen = Color(hex: 0xFFFFFF, dark: 0x1B1F24)
    /// Primary text.
    public static let ink = Color(hex: 0x16191D, dark: 0xECEEF0, highContrast: (0x000000, 0xFFFFFF))
    /// Secondary text: at least 4.5:1 on `card` and `canvas` in both themes.
    public static let ink2 = Color(hex: 0x575F68, dark: 0xA3ABB3, highContrast: (0x2E343A, 0xD4D9DE))
    /// Tertiary text: timestamps and captions. Still 4.5:1 on `card` and `canvas`.
    public static let ink3 = Color(hex: 0x656D76, dark: 0x8C959E, highContrast: (0x464E56, 0xB0B8C0))
    /// Dividers and outlines (8–10%, stronger with Increase Contrast).
    public static let hairline = Color(
        light: NSColor(srgbRed: 16 / 255, green: 24 / 255, blue: 32 / 255, alpha: 0.10),
        dark: NSColor(white: 1, alpha: 0.09),
        highContrastLight: NSColor(srgbRed: 16 / 255, green: 24 / 255, blue: 32 / 255, alpha: 0.32),
        highContrastDark: NSColor(white: 1, alpha: 0.30))
    /// Flat fill for wells inside a card (fields, code, keycaps).
    public static let well = Color(light: NSColor(srgbRed: 16 / 255, green: 24 / 255, blue: 32 / 255, alpha: 0.045),
                                   dark: NSColor(white: 1, alpha: 0.055))

    // MARK: Surfaces

    /// The opaque ground of the content column (the big card beside the sidebar) and of
    /// the onboarding window.
    public static let canvas = Color(hex: 0xF5F6F8, dark: 0x111316)
    /// A solid content card on `canvas`.
    public static let card = Color(hex: 0xFFFFFF, dark: 0x1A1D21)
    /// The 1 pt highlight along a card's top edge.
    public static let cardHighlight = Color(light: NSColor(white: 1, alpha: 0.9), dark: NSColor(white: 1, alpha: 0.06))
    /// Laid once over the sidebar's frost, at 52% of the app's base tone.
    public static let frostTint = Color(light: NSColor(srgbRed: 0.918, green: 0.933, blue: 0.949, alpha: 0.52),
                                        dark: NSColor(srgbRed: 0.035, green: 0.039, blue: 0.047, alpha: 0.52))
    /// The frost's stand-in with Reduce Transparency: the same tone, opaque.
    public static let frostSolid = Color(hex: 0xE6E9ED, dark: 0x0B0C0F)

    // MARK: Rows

    /// A row under the pointer, on a card.
    public static let rowHover = Color(light: NSColor(srgbRed: 16 / 255, green: 24 / 255, blue: 32 / 255, alpha: 0.04),
                                       dark: NSColor(white: 1, alpha: 0.05))
    /// A row under the pointer, on the frost (one alpha step over the tint).
    public static let chromeHover = Color(light: NSColor(srgbRed: 16 / 255, green: 24 / 255, blue: 32 / 255, alpha: 0.05),
                                          dark: NSColor(white: 1, alpha: 0.06))
    /// The selected row on the frost.
    public static let chromeSelected = Color(
        light: NSColor(srgbRed: 16 / 255, green: 24 / 255, blue: 32 / 255, alpha: 0.085),
        dark: NSColor(white: 1, alpha: 0.10),
        highContrastLight: NSColor(srgbRed: 16 / 255, green: 24 / 255, blue: 32 / 255, alpha: 0.16),
        highContrastDark: NSColor(white: 1, alpha: 0.20))

    // MARK: Accents and status

    /// The clients' hint (Fairspoken for Mac): sage green.
    public static let clientAccent = Color(hex: 0x2A7F56, dark: 0x5CCB94, highContrast: (0x1D6B45, 0x7FE0AE))
    /// Text and glyphs on an accent fill: white on the light theme's deep green, near-black on the
    /// dark theme's light green (4.5:1 or better on both).
    public static let onAccent = Color(hex: 0xFFFFFF, dark: 0x08140E)
    /// The server's hint (Fairspoken Server): garnet.
    public static let serverAccent = Color(hex: 0xB2453E, dark: 0xF07F76)

    public static let ok = Color(hex: 0x2B7F57, dark: 0x5CCB94)
    public static let warn = Color(hex: 0x8F620C, dark: 0xE7B95A)
    public static let error = Color(hex: 0xB4283C, dark: 0xFF7D8E)
    /// The microphone is on.
    public static let live = Color(hex: 0xD9483B, dark: 0xFF6E62)

    /// Fills for the rounded-square icon tiles (sidebar sections, permissions, settings).
    public enum Tile {
        public static let orange = Color(hex: 0xF08A24, dark: 0xF39A3C)
        public static let indigo = Color(hex: 0x5B5FD6, dark: 0x7276E8)
        public static let purple = Color(hex: 0x9A5BD8, dark: 0xA772E3)
        public static let gray = Color(hex: 0x8A9098, dark: 0x6E757E)
        public static let green = Color(hex: 0x2E9D63, dark: 0x3DAF73)
        public static let blue = Color(hex: 0x2F7BE6, dark: 0x4A8DF0)
        public static let red = Color(hex: 0xE0483C, dark: 0xEC5A4E)
        public static let teal = Color(hex: 0x1F9AA6, dark: 0x2FAFBB)
    }
}

/// The type scale: system font, 13 pt body, six steps.
public enum TypeScale {
    /// 11 pt: keycaps, badges, column headings.
    public static let micro = Font.system(size: 11)
    /// 12 pt: captions and secondary lines.
    public static let meta = Font.system(size: 12)
    /// 13 pt: body text and controls.
    public static let body = Font.system(size: 13)
    /// 15 pt: card and section headings.
    public static let heading = Font.system(size: 15, weight: .semibold)
    /// 20 pt: page titles.
    public static let title = Font.system(size: 20, weight: .semibold)
    /// 28 pt: onboarding titles and headline numbers.
    public static let display = Font.system(size: 28, weight: .semibold)
}

/// Motion: 120–260 ms, ease-out, and none at all with Reduce Motion.
public enum Motion {
    public static let fastDuration = 0.12
    public static let normalDuration = 0.18
    public static let deliberateDuration = 0.26

    /// The standard ease-out curve (0.2, 0.8, 0.2, 1).
    public static func ease(_ duration: Double) -> Animation {
        .timingCurve(0.2, 0.8, 0.2, 1, duration: duration)
    }

    public static var fast: Animation { ease(fastDuration) }
    public static var normal: Animation { ease(normalDuration) }
    public static var deliberate: Animation { ease(deliberateDuration) }

    /// `animation`, or nil with Reduce Motion.
    public static func unlessReduced(_ animation: Animation, _ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}

/// The still backdrop behind a Crystal window: a silver sheen with one faint wash of `accent`
/// in the top-leading corner, so Liquid Glass has something to refract. Drawn once (no
/// animation) to keep idle CPU at zero. Fairspoken Server's window stands on it.
public struct CrystalBackground: View {
    @Environment(\.colorScheme) private var scheme
    public var accent: Color

    public init(accent: Color = Crystal.clientAccent) { self.accent = accent }

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                LinearGradient(colors: [Crystal.pageSheen, Crystal.page], startPoint: .top, endPoint: .bottom)
                // A cool brushed-metal band across the middle.
                LinearGradient(colors: [.clear, Color.white.opacity(scheme == .dark ? 0.025 : 0.35), .clear],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle().fill(accent.opacity(scheme == .dark ? 0.12 : 0.08))
                    .frame(width: w * 0.8, height: w * 0.8)
                    .position(x: w * 0.1, y: h * 0.0)
                    .blur(radius: 120)
            }
            .drawingGroup()
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// The window's frost: the desktop blurred behind the window (`NSVisualEffectView`, so the blur
/// costs the app nothing), with `Crystal.frostTint` laid over it once. With Reduce Transparency
/// it is the same tone, opaque.
public struct WindowFrost: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    public init() {}

    public var body: some View {
        Group {
            if reduceTransparency {
                Crystal.frostSolid
            } else {
                VisualEffectBackground(material: .sidebar).overlay(Crystal.frostTint)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// `NSVisualEffectView` blending with what is behind the window.
public struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    public init(material: NSVisualEffectView.Material = .sidebar) { self.material = material }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    public func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

extension Color {
    // Brand book palette (design/brand/README.md §3): the mark's two inks.
    /// Copybook Blue: primary actions, links, the fair line.
    public static let fsBlue = Color(hex: 0x2C4BD0, dark: 0x93A8FF)
    /// Margin Red: the signal only (live microphone, audio in flight, the caret). Never errors.
    public static let fsRed = Color(hex: 0xE5512B, dark: 0xFF7148)

    public init(light: NSColor, dark: NSColor, highContrastLight: NSColor? = nil, highContrastDark: NSColor? = nil) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark,
                                               .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
            case .accessibilityHighContrastDarkAqua?: highContrastDark ?? dark
            case .accessibilityHighContrastAqua?: highContrastLight ?? light
            case .darkAqua?, .vibrantDark?: dark
            default: light
            }
        })
    }

    public init(hex: UInt32, dark: UInt32, highContrast: (light: UInt32, dark: UInt32)? = nil) {
        func ns(_ v: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
        self.init(light: ns(hex), dark: ns(dark),
                  highContrastLight: highContrast.map { ns($0.light) }, highContrastDark: highContrast.map { ns($0.dark) })
    }
}

extension Font {
    /// Rounded numerals for stats.
    public static func mvNumber(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }

    /// Measured data (timings, addresses): the brand sets data in mono.
    public static func fsData(_ style: Font.TextStyle = .callout, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .monospaced).weight(weight)
    }
}
