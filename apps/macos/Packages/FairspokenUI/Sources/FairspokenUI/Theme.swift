import AppKit
import SwiftUI

/// Brand tokens for the dictation client: the one blue for the action about to happen, neutral
/// greys, and the red of a live microphone.
public enum Brand {
    public static var accent: Color { Crystal.clientAccent }
    public static var secondary: Color { Crystal.ink2 }
    public static var live: Color { Crystal.live }
}

/// The shared tokens, for Bark and Bark Server. Dark is a true-black ground with surfaces a few
/// steps of white above it, 8% white hairlines, neutral text in three steps and one blue for the
/// primary action. Light mode keeps the same structure on a near-white ground. Every surface is
/// opaque: nothing lets the desktop show through. Diffs are blue (added) and orange (removed);
/// red is kept for the microphone being on. Text tokens hold at least 4.5:1 on every surface they
/// sit on, in both themes, and each has an Increase Contrast variant.
public enum Crystal {
    // MARK: Surfaces

    /// The window's ground: true black, or a near-white in light mode.
    public static let canvas = Color(hex: 0xFAFAFA, dark: 0x000000)
    /// A card, popover, menu or composer: one step up from the ground.
    public static let card = Color(hex: 0xFFFFFF, dark: 0x111111, highContrast: (0xFFFFFF, 0x161616))
    /// What you said: the grey bubble of a dictation, a step above a card.
    public static let message = Color(hex: 0xEBEBED, dark: 0x1E1E1E, highContrast: (0xE2E2E5, 0x262626))
    /// The selected row in a list (the sidebar's thread list, menus).
    public static let selected = Color(hex: 0xECECEE, dark: 0x191A1D, highContrast: (0xDCDCE0, 0x26272B))
    /// Kept for Bark Server's ground.
    public static let page = canvas
    public static let pageSheen = canvas
    /// Kept for older call sites: no highlight now, the edge alone separates a card.
    public static let cardHighlight = Color.clear

    // MARK: Text

    /// Primary text.
    public static let ink = Color(hex: 0x18181B, dark: 0xF5F5F5, highContrast: (0x000000, 0xFFFFFF))
    /// Muted text: descriptions, controls at rest.
    public static let ink2 = Color(hex: 0x52525B, dark: 0xA3A3A3, highContrast: (0x2E2E33, 0xD6D6D6))
    /// Secondary labels: timestamps, metadata, group headings.
    public static let ink3 = Color(hex: 0x63636B, dark: 0x8F8F8F, highContrast: (0x46464B, 0xB8B8B8))

    // MARK: Lines and fills

    /// Borders and dividers (8% white in dark mode).
    public static let hairline = Color(
        light: NSColor(white: 0, alpha: 0.10),
        dark: NSColor(white: 1, alpha: 0.08),
        highContrastLight: NSColor(white: 0, alpha: 0.32),
        highContrastDark: NSColor(white: 1, alpha: 0.30))
    /// Fainter dividers between rows inside a grouped card.
    public static let hairlineSoft = Color(
        light: NSColor(white: 0, alpha: 0.07),
        dark: NSColor(white: 1, alpha: 0.05),
        highContrastLight: NSColor(white: 0, alpha: 0.28),
        highContrastDark: NSColor(white: 1, alpha: 0.26))
    /// The edge of an outline control (buttons, selects, fields).
    public static let input = Color(
        light: NSColor(white: 0, alpha: 0.16),
        dark: NSColor(white: 1, alpha: 0.11),
        highContrastLight: NSColor(white: 0, alpha: 0.45),
        highContrastDark: NSColor(white: 1, alpha: 0.40))
    /// The flat fill of an outline control, a field or a keycap.
    public static let well = Color(light: NSColor(white: 0, alpha: 0.035),
                                   dark: NSColor(white: 1, alpha: 0.035))
    /// A keyboard hint's fill (foreground at 7%).
    public static let keyFill = Color(light: NSColor(white: 0, alpha: 0.06),
                                      dark: NSColor(srgbRed: 0.96, green: 0.96, blue: 0.96, alpha: 0.07))

    // MARK: Rows

    /// A row under the pointer.
    public static let rowHover = Color(light: NSColor(white: 0, alpha: 0.04),
                                       dark: NSColor(white: 1, alpha: 0.045))
    /// A row under the pointer, in the sidebar.
    public static let chromeHover = rowHover
    /// The selected row in the sidebar.
    public static let chromeSelected = selected

    // MARK: Accents and status

    /// The primary action: the one blue (white text on it, 4.6:1 dark and 6.7:1 light).
    public static let primary = Color(hex: 0x1B4ED8, dark: 0x346BF1, highContrast: (0x123A9E, 0x2456D6))
    /// The client's accent is the primary blue.
    public static let clientAccent = primary
    /// Text and glyphs on `primary`.
    public static let onAccent = Color.white
    /// Bark Server shares the same blue.
    public static let serverAccent = primary
    /// Information and diff additions.
    public static let info = Color(hex: 0x1D4ED8, dark: 0x51A2FF, highContrast: (0x1E3A8A, 0x8CC2FF))
    /// Diff removals.
    public static let removed = Color(hex: 0xC2410C, dark: 0xFF8904, highContrast: (0x9A3412, 0xFFB066))
    /// The microphone is on.
    public static let recording = Color(hex: 0xDC2626, dark: 0xFB414A)
    /// "Ready" and other good news stay neutral: the brand has no green.
    public static let ok = ink2
    public static let warn = Color(hex: 0x92400E, dark: 0xFFB900)
    public static let error = Color(hex: 0xB91C1C, dark: 0xFF6467)
    /// The microphone is on.
    public static let live = recording

    /// Fills for small icon tiles (permissions, settings): kept to the palette's hues, no green
    /// or purple.
    public enum Tile {
        public static let orange = Color(hex: 0xEA6A0A, dark: 0xFF8904)
        public static let indigo = Color(hex: 0x1B4ED8, dark: 0x51A2FF)
        public static let purple = Color(hex: 0x1B4ED8, dark: 0x51A2FF)
        public static let gray = Color(hex: 0x71717A, dark: 0x99A1AF)
        public static let green = Color(hex: 0x71717A, dark: 0x99A1AF)
        public static let blue = Color(hex: 0x1D4ED8, dark: 0x51A2FF)
        public static let red = Color(hex: 0xDC2626, dark: 0xFB414A)
        public static let teal = Color(hex: 0x0284C7, dark: 0x00BCFF)
    }
}

/// Corner radii: controls, cards and grouped settings, the composer.
public enum Radius {
    /// Buttons, rows, selects, menus.
    public static let control: CGFloat = 8
    /// Cards and grouped lists.
    public static let card: CGFloat = 12
    /// The composer and the dictation bubble.
    public static let composer: CGFloat = 16
}

/// How content surfaces are drawn. Bark Server keeps `.solid`; Bark sets `.plain`. Both are now
/// the same opaque card on the ground (`Crystal.card`, a hairline edge, 12 pt corners); the
/// distinction stays so either app can diverge again without touching every screen.
public enum SurfaceStyle: Sendable {
    case solid, plain
}

extension EnvironmentValues {
    @Entry public var surfaceStyle: SurfaceStyle = .solid
}

/// Bark's surfaces under their older names.
public enum Plain {
    /// The window's ground behind the content.
    public static let ground = Crystal.canvas
    /// A content card's fill.
    public static let card = Crystal.card
    /// A raised control on a card.
    public static let raised = Crystal.message
    /// A card's edge.
    public static let edge = Crystal.hairline
    /// Corner radius of a content card.
    public static let radius: CGFloat = Radius.card
}

/// The type scale: the system font (and system mono for data), 13 pt controls, 14 pt rows.
public enum TypeScale {
    /// 11 pt: keycaps, badges, column headings.
    public static let micro = Font.system(size: 11)
    /// 12 pt: captions and secondary lines.
    public static let meta = Font.system(size: 12)
    /// 13 pt: body text and controls.
    public static let body = Font.system(size: 13)
    /// 15 pt: card and section headings.
    public static let heading = Font.system(size: 15, weight: .semibold)
    /// 14 pt medium: row titles.
    public static let row = Font.system(size: 14, weight: .medium)
    /// 15 pt: dictated text.
    public static let dictated = Font.system(size: 15)
    /// 22 pt semibold: page titles.
    public static let title = Font.system(size: 22, weight: .semibold)
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

/// Bark Server's window ground: the plain canvas. (It was a sheen with a wash of colour; the
/// look has no gradients now.) `accent` is ignored and kept for source compatibility.
public struct CrystalBackground: View {
    public var accent: Color
    public init(accent: Color = Crystal.serverAccent) { self.accent = accent }

    public var body: some View {
        Crystal.canvas
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

/// Bark's window ground: true black in dark mode, near-white in light. No gradient.
public struct PlainBackground: View {
    public init() {}

    public var body: some View {
        Crystal.canvas
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

/// Bark's sidebar ground: the same opaque canvas as the content, divided by a hairline. Nothing
/// behind the window shows through, so the desktop can never tint the app.
public struct SidebarBackground: View {
    public init() {}

    public var body: some View {
        Crystal.canvas
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

extension Color {
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
    /// Numerals for stats: the system face with tabular digits.
    public static func mvNumber(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }

    /// System mono at `size` (timings, word diffs, model sizes).
    public static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Measured data (timings, addresses): the brand sets data in mono.
    public static func fsData(_ style: Font.TextStyle = .callout, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .monospaced).weight(weight)
    }
}
