import FairspokenCore
import SwiftUI

/// A content card: an opaque `Crystal.card` one step off the ground, 12 pt corners and a hairline
/// edge. No shadow, no gradient, no glass, so cards hold rows, fields and controls directly.
/// `tint` washes the card faintly (a highlighted choice); `fillHeight` stretches it to its row's height.
public struct Card<Content: View>: View {
    var cornerRadius: CGFloat?
    var padding: CGFloat
    var tint: Color?
    var fillHeight: Bool
    @ViewBuilder var content: Content

    public init(cornerRadius: CGFloat? = nil, padding: CGFloat = 16, tint: Color? = nil, fillHeight: Bool = false,
                @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.tint = tint
        self.fillHeight = fillHeight
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
            .cardSurface(cornerRadius: cornerRadius, tint: tint)
    }
}

/// Transitional name: Models still says `GlassCard`; it is a solid `Card` now.
public typealias GlassCard = Card

public enum CardMetrics {
    /// One radius for every content card.
    public static let radius: CGFloat = Radius.card
    /// The gap between cards.
    public static let gap: CGFloat = 4
}

extension View {
    /// The card material on any shape-sized view. The radius defaults to `Radius.card`.
    /// `selected` draws an accent edge instead of the hairline.
    public func cardSurface(cornerRadius: CGFloat? = nil, tint: Color? = nil, selected: Color? = nil) -> some View {
        modifier(CardSurface(cornerRadius: cornerRadius, tint: tint, selected: selected))
    }
}

private struct CardSurface: ViewModifier {
    var cornerRadius: CGFloat?
    var tint: Color?
    var selected: Color?
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        // Older call sites ask for the large radii of the previous look; cards are 12 pt now.
        let shape = RoundedRectangle(cornerRadius: min(cornerRadius ?? Radius.card, Radius.composer), style: .continuous)
        return content
            .background {
                shape.fill(Crystal.card)
                    .overlay { if let tint { shape.fill(tint.opacity(scheme == .dark ? 0.10 : 0.06)) } }
            }
            .overlay {
                shape.strokeBorder(selected ?? Crystal.hairline, lineWidth: selected == nil ? 1 : 1.5)
            }
    }
}

/// A coloured rounded-square tile holding a white SF Symbol: sidebar sections, permissions,
/// settings groups.
public struct IconTile: View {
    var symbol: String
    var color: Color
    var size: CGFloat
    public init(_ symbol: String, color: Color, size: CGFloat = 22) {
        self.symbol = symbol
        self.color = color
        self.size = size
    }

    public var body: some View {
        // A soft tile: the symbol in its colour on a faint wash of it.
        let shape = RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.14), in: shape)
            .accessibilityHidden(true)
    }
}

/// The one primary action of a screen: the primary blue, 8 pt corners, white text, with a 1 pt
/// highlight along its top. Drawn with an explicit fill, so it keeps its colour in a window that
/// isn't key.
public struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color
    var large: Bool
    public init(tint: Color = Crystal.primary, large: Bool = false) {
        self.tint = tint
        self.large = large
    }

    public func makeBody(configuration: Configuration) -> some View {
        PrimaryButtonBody(configuration: configuration, tint: tint, large: large)
    }

    private struct PrimaryButtonBody: View {
        var configuration: ButtonStyleConfiguration
        var tint: Color
        var large: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovered = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isEnabled ? Crystal.onAccent : Crystal.ink3)
                .padding(.horizontal, large ? 14 : 10)
                .frame(minHeight: large ? 32 : 28)
                .background {
                    if isEnabled {
                        shape.fill(tint.mix(with: .black, by: configuration.isPressed ? 0.16 : hovered ? 0.07 : 0))
                            .overlay(alignment: .top) {
                                shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.16), .clear],
                                                                  startPoint: .top, endPoint: .init(x: 0.5, y: 0.08)))
                            }
                    } else {
                        // Unavailable reads as neutral and flat.
                        shape.fill(Crystal.well).overlay(shape.strokeBorder(Crystal.hairlineSoft))
                    }
                }
                .contentShape(shape)
                .onHover { hovered = $0 }
                .animation(reduceMotion ? nil : Motion.fast, value: configuration.isPressed)
        }
    }
}

/// A secondary action: an outline button, 28 pt high, 8 pt corners, on a faint fill.
public struct OutlineButtonStyle: ButtonStyle {
    var compact: Bool
    public init(compact: Bool = false) { self.compact = compact }

    public func makeBody(configuration: Configuration) -> some View {
        OutlineBody(configuration: configuration, compact: compact)
    }

    private struct OutlineBody: View {
        var configuration: ButtonStyleConfiguration
        var compact: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovered = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isEnabled ? Crystal.ink : Crystal.ink3)
                .padding(.horizontal, compact ? 8 : 10)
                .frame(minHeight: compact ? 24 : 28)
                .background(shape.fill(configuration.isPressed ? Crystal.selected : hovered && isEnabled ? Crystal.rowHover : Crystal.well))
                .overlay(shape.strokeBorder(Crystal.input))
                .contentShape(shape)
                .onHover { hovered = $0 }
        }
    }
}

/// A quiet action: muted text, a fill only under the pointer.
public struct GhostButtonStyle: ButtonStyle {
    var selected: Bool
    public init(selected: Bool = false) { self.selected = selected }

    public func makeBody(configuration: Configuration) -> some View {
        GhostBody(configuration: configuration, selected: selected)
    }

    private struct GhostBody: View {
        var configuration: ButtonStyleConfiguration
        var selected: Bool
        @State private var hovered = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(selected || hovered ? Crystal.ink : Crystal.ink2)
                .padding(.horizontal, 9)
                .frame(minHeight: 28)
                .background(shape.fill(selected || configuration.isPressed ? Crystal.selected : hovered ? Crystal.rowHover : .clear))
                .contentShape(shape)
                .onHover { hovered = $0 }
        }
    }
}

/// The heading over a group of cards: 13 pt semibold, with an optional trailing control.
public struct SectionHeading<Trailing: View>: View {
    var title: String
    @ViewBuilder var trailing: Trailing
    public init(_ title: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Crystal.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            trailing
        }
    }
}

/// Small uppercase label above a value.
public struct Eyebrow: View {
    var text: String
    var symbol: String? = nil
    public init(text: String, symbol: String? = nil) { self.text = text; self.symbol = symbol }
    public var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text.uppercased())
        }
        .font(.system(size: 11, weight: .semibold))
        .tracking(0.5)
        .foregroundStyle(Crystal.ink2)
    }
}

/// A keyboard hint: `⌘K`, `fn`, `esc`. Flat on a faint fill (11 pt medium, 20 pt high, 4 pt
/// corners); `outline` draws a physical key so it stands apart inside a sentence; `large` is the
/// shortcut on its own (onboarding).
public struct Keycap: View {
    var label: String
    var large: Bool
    var outline: Bool
    public init(label: String, large: Bool = false, outline: Bool = false) {
        self.label = label
        self.large = large
        self.outline = outline
    }

    public var body: some View {
        let radius: CGFloat = large ? 8 : 4
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Text(label)
            .font(.system(size: large ? 20 : 11, weight: .medium))
            .padding(.horizontal, large ? 12 : outline ? 6 : 5)
            .frame(minWidth: large ? 44 : 20, minHeight: large ? 40 : 20)
            .foregroundStyle(large ? Crystal.ink : Crystal.ink2)
            .background {
                if outline || large {
                    shape.strokeBorder(Crystal.input)
                        .overlay(alignment: .bottom) {
                            // The key's lower lip: the bottom edge drawn twice as thick.
                            shape.fill(Crystal.input).frame(height: 2).padding(.horizontal, radius / 2)
                        }
                } else {
                    shape.fill(Crystal.keyFill)
                }
            }
            .fixedSize()
            .accessibilityLabel(label)
    }
}

/// Splits a KeyboardShortcuts description like "⇧⌘1" into individual caps.
public struct ShortcutCaps: View {
    var description: String
    var large: Bool
    public init(description: String, large: Bool = false) { self.description = description; self.large = large }
    public var body: some View {
        HStack(spacing: large ? 6 : 3) {
            if large {
                ForEach(Array(Self.split(description).enumerated()), id: \.offset) { _, part in Keycap(label: part, large: true) }
            } else {
                // One hint for the whole chord, as keyboard hints are written: ⇧⌘1.
                Keycap(label: description)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Shortcut \(description)")
    }

    public static func split(_ s: String) -> [String] {
        let mods: Set<Character> = ["⌃", "⌥", "⇧", "⌘"]
        var parts: [String] = []
        var rest = ""
        for ch in s {
            if mods.contains(ch) && rest.isEmpty { parts.append(String(ch)) } else { rest.append(ch) }
        }
        if !rest.isEmpty { parts.append(rest) }
        return parts
    }
}

public struct StatusDot: View {
    var color: Color
    var pulsing = false
    public init(color: Color, pulsing: Bool = false) { self.color = color; self.pulsing = pulsing }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var on = false

    public var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay {
                if pulsing && !reduceMotion {
                    Circle().stroke(color.opacity(0.6), lineWidth: 2)
                        .scaleEffect(on ? 2.4 : 1)
                        .opacity(on ? 0 : 1)
                        .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), value: on)
                        .onAppear { on = true }
                }
            }
            .accessibilityHidden(true)
    }
}

/// A small labelled control-like chip: an outline control on a card (`flat`), or a small card.
public struct Chip: View {
    var text: String
    var symbol: String? = nil
    var tint: Color? = nil
    var dot: Color? = nil
    var flat: Bool
    public init(text: String, symbol: String? = nil, tint: Color? = nil, dot: Color? = nil, flat: Bool = false) {
        self.text = text; self.symbol = symbol; self.tint = tint; self.dot = dot; self.flat = flat
    }

    @Environment(\.surfaceStyle) private var style

    public var body: some View {
        let label = HStack(spacing: 6) {
            if let dot { StatusDot(color: dot) }
            if let symbol { Image(systemName: symbol).imageScale(.small).foregroundStyle(tint ?? Crystal.ink2) }
            Text(text).lineLimit(1)
        }
        if flat && style == .plain {
            // An outline control: 8 pt corners on a faint fill.
            label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Crystal.ink)
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(Crystal.well, in: .rect(cornerRadius: Radius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Crystal.input))
        } else if flat {
            label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Crystal.ink)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Crystal.well, in: .capsule)
                .overlay(Capsule().strokeBorder(Crystal.hairline))
        } else {
            label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Crystal.ink)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Crystal.card, in: .rect(cornerRadius: Radius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Crystal.hairline))
        }
    }
}

/// Small flat tag used inside cards (no glass-on-glass).
public struct Tag: View {
    var text: String
    var symbol: String? = nil
    var color: Color = .secondary
    public init(text: String, symbol: String? = nil, color: Color = .secondary) { self.text = text; self.symbol = symbol; self.color = color }

    public var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text).lineLimit(1)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(color)
        .padding(.horizontal, 5)
        .frame(height: 18)
        .background(color.opacity(0.14), in: .rect(cornerRadius: 4, style: .continuous))
    }
}

/// Brand mark: a small copy of the app icon, the sheepdog photo on its black tile with a
/// light hairline edge. The photo is the client's `BrandTile` image, so only Bark
/// itself can show this; elsewhere use `FairspokenMark`.
public struct BrandMark: View {
    var size: CGFloat = 28
    public init(size: CGFloat = 28) { self.size = size }
    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
        Image("BrandTile")
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .background(Color.black)
            .clipShape(shape)
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.32), .white.opacity(0.12), .white.opacity(0.18)],
                                                       startPoint: .top, endPoint: .bottom), lineWidth: max(0.5, size / 90)))
            .shadow(color: .black.opacity(0.25), radius: size * 0.06, y: size * 0.03)
            .accessibilityHidden(true)
    }
}

/// 1…5 dot meter for model accuracy/speed hints.
public struct DotMeter: View {
    var value: Int
    var color: Color
    public init(value: Int, color: Color) { self.value = value; self.color = color }
    public var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { i in
                Capsule().fill(i < value ? color : Crystal.hairline).frame(width: 12, height: 5)
            }
        }
        .accessibilityElement()
        .accessibilityValue("\(value) of 5")
    }
}

extension ComputePlacement {
    /// Neutral wherever it runs: the brand keeps its blue for actions.
    public var tint: Color { Crystal.ink2 }
}

public enum Format {
    public static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    public static func ms(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value >= 1000 ? String(format: "%.1f s", value / 1000) : "\(Int(value.rounded())) ms"
    }

    public static func number(_ n: Int) -> String { n.formatted(.number) }

    /// "45s", "1m 30s", "10m", "2h 36m", "3h": a zero remainder is left off ("10m", not "10m 0s").
    public static func duration(_ seconds: Double) -> String {
        let s = Int(seconds)
        func pair(_ big: Int, _ bigUnit: String, _ small: Int, _ smallUnit: String) -> String {
            small == 0 ? "\(big)\(bigUnit)" : "\(big)\(bigUnit) \(small)\(smallUnit)"
        }
        if s >= 3600 { return pair(s / 3600, "h", s % 3600 / 60, "m") }
        if s >= 60 { return pair(s / 60, "m", s % 60, "s") }
        return "\(s)s"
    }

    public static func relative(_ date: Date) -> String {
        let delta = Date().timeIntervalSince(date)
        if delta < 60 { return "now" }
        if Calendar.current.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.abbreviated))
    }
}

/// The Bark mark, fitted to a square: the sheepdog mark in one colour (`Crystal.ink`
/// unless `monochrome` says otherwise). On a dark surface its shapes are the dog's white
/// markings; on a light one they read as a dark-marked dog.
public struct FairspokenMark: View {
    var size: CGFloat
    var monochrome: Color?
    public init(size: CGFloat = 28, monochrome: Color? = nil) {
        self.size = size
        self.monochrome = monochrome
    }

    public var body: some View {
        DogMark(height: size, color: monochrome ?? Crystal.ink)
            .frame(width: size, height: size)
    }
}

/// The one-colour sheepdog mark from design/brand/logo/dog/dog-mark.svg, traced from the
/// app icon's photo: the blaze, the muzzle with the nose cut out, the open mouth with its
/// tongue, and the catchlights. Whatever it sits on is the dog's black. `height` is the
/// mark's height; it is about half as wide.
public struct DogMark: View {
    var height: CGFloat
    var color: Color
    public init(height: CGFloat, color: Color = .white) {
        self.height = height
        self.color = color
    }

    static let path = DogMark.parse(pathData)

    /// Parses the absolute M / L / C / Z commands the master uses.
    static func parse(_ d: String) -> Path {
        var path = Path()
        var spaced = ""
        for ch in d {
            if "MLCZ".contains(ch) { spaced += " \(ch) " } else if ch == "," { spaced += " " } else { spaced.append(ch) }
        }
        let tokens = spaced.split(separator: " ").map(String.init)
        var i = 0
        var command = ""
        func number() -> CGFloat { defer { i += 1 }; return i < tokens.count ? CGFloat(Double(tokens[i]) ?? 0) : 0 }
        func point() -> CGPoint { CGPoint(x: number(), y: number()) }
        while i < tokens.count {
            if ["M", "L", "C", "Z"].contains(tokens[i]) {
                command = tokens[i]
                i += 1
                if command == "Z" { path.closeSubpath() }
                continue
            }
            switch command {
            case "M": path.move(to: point()); command = "L"
            case "L": path.addLine(to: point())
            case "C": let c1 = point(), c2 = point(); path.addCurve(to: point(), control1: c1, control2: c2)
            default: i += 1
            }
        }
        return path
    }

    public var body: some View {
        let width = height * Self.box.width / Self.box.height
        Canvas { ctx, canvas in
            let s = canvas.height / Self.box.height
            ctx.scaleBy(x: s, y: s)
            ctx.translateBy(x: -Self.box.minX, y: -Self.box.minY)
            ctx.fill(Self.path, with: .color(color), style: FillStyle(eoFill: true))
        }
        .frame(width: width, height: height)
        .accessibilityHidden(true)
    }
}
