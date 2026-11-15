import FairspokenCore
import SwiftUI

/// A content card. Solid (`SurfaceStyle.solid`, Bark Server): opaque fill, 12 pt corners, a
/// hairline edge, a 1 pt highlight along the top and a tight, soft shadow, on `Crystal.canvas`.
/// Frosted (Bark): translucent over the aurora, 22 pt corners, a bright rim and a soft, wide
/// shadow. Neither is glass, so cards hold rows, fields and controls directly. `tint` washes the
/// card faintly (a highlighted choice); `fillHeight` stretches it to its row's height.
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
    /// One radius for every solid content card (frosted cards use `Frost.radius`).
    public static let radius: CGFloat = 12
    /// The gap between cards (and between the content column and the window's frost).
    public static let gap: CGFloat = 4
}

extension View {
    /// The card material on any shape-sized view, in the environment's `SurfaceStyle`. The
    /// radius defaults to the style's. `selected` draws an accent edge instead of the hairline.
    public func cardSurface(cornerRadius: CGFloat? = nil, tint: Color? = nil, selected: Color? = nil) -> some View {
        modifier(CardSurface(cornerRadius: cornerRadius, tint: tint, selected: selected))
    }
}

private struct CardSurface: ViewModifier {
    var cornerRadius: CGFloat?
    var tint: Color?
    var selected: Color?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.surfaceStyle) private var style
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if style == .frosted { frosted(content) } else { solid(content) }
    }

    private func frosted(_ content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius ?? Frost.radius, style: .continuous)
        let dark = scheme == .dark
        return content
            .background {
                shape.fill(reduceTransparency ? Frost.cardSolid : Frost.card)
                    .overlay { if let tint { shape.fill(tint.opacity(dark ? 0.12 : 0.08)) } }
                    .shadow(color: .black.opacity(dark ? 0.28 : 0.05), radius: 18, y: 8)
            }
            .overlay {
                if let selected {
                    shape.strokeBorder(selected, lineWidth: 1.5)
                } else {
                    // A rim that catches the light at the top and fades down the sides.
                    shape.strokeBorder(LinearGradient(colors: [Frost.edge, Frost.edge.opacity(dark ? 0.6 : 0.45)],
                                                      startPoint: .top, endPoint: .bottom), lineWidth: 1)
                    shape.strokeBorder(Crystal.hairline.opacity(dark ? 0.0 : 0.5), lineWidth: 0.5)
                }
            }
    }

    private func solid(_ content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius ?? CardMetrics.radius, style: .continuous)
        return content
            .background {
                shape.fill(Crystal.card)
                    .overlay { if let tint { shape.fill(tint.opacity(scheme == .dark ? 0.10 : 0.06)) } }
                    .shadow(color: .black.opacity(scheme == .dark ? 0.30 : 0.05), radius: 1, y: 0.5)
                    .shadow(color: .black.opacity(scheme == .dark ? 0.22 : 0.045), radius: 6, y: 2)
            }
            .overlay {
                shape.strokeBorder(selected ?? Crystal.hairline, lineWidth: selected == nil ? 1 : 1.5)
                // The inner top highlight: a 1 pt line that fades out down the sides.
                shape.inset(by: 1).stroke(LinearGradient(colors: [Crystal.cardHighlight, .clear],
                                                         startPoint: .top, endPoint: .init(x: 0.5, y: 0.12)), lineWidth: 1)
                    .allowsHitTesting(false)
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

    @Environment(\.surfaceStyle) private var style

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
        if style == .frosted {
            // October's soft tile: the symbol in its colour on a wash of it.
            Image(systemName: symbol)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: size, height: size)
                .background(color.opacity(0.15), in: shape)
                .accessibilityHidden(true)
        } else {
            solidTile(shape)
        }
    }

    private func solidTile(_ shape: RoundedRectangle) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.52, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background {
                shape.fill(LinearGradient(colors: [color.mix(with: .white, by: 0.12), color],
                                          startPoint: .top, endPoint: .bottom))
            }
            .overlay(shape.strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}

/// The one primary action of a screen: an accent capsule with white text. Drawn with an explicit
/// fill, so it keeps its colour in a window that isn't key.
public struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color
    var large: Bool
    public init(tint: Color = Crystal.clientAccent, large: Bool = false) {
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
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isEnabled ? Crystal.onAccent : Crystal.ink3.opacity(0.7))
                .padding(.horizontal, large ? 18 : 12)
                .frame(minHeight: large ? 32 : 26)
                .background {
                    if isEnabled {
                        Capsule().fill(tint.mix(with: .black, by: configuration.isPressed ? 0.18 : hovered ? 0.08 : 0))
                            .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
                            .shadow(color: tint.opacity(0.25), radius: 2, y: 1)
                    } else {
                        // Unavailable reads as neutral and flat: no edge, so it never looks like a
                        // secondary button.
                        Capsule().fill(Crystal.well)
                    }
                }
                .contentShape(.capsule)
                .onHover { hovered = $0 }
                .animation(reduceMotion ? nil : Motion.fast, value: configuration.isPressed)
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

/// A keyboard key cap: `⌘` `⇧` `1`. `large` for the shortcut on its own (onboarding).
public struct Keycap: View {
    var label: String
    var large: Bool
    public init(label: String, large: Bool = false) { self.label = label; self.large = large }
    public var body: some View {
        let radius: CGFloat = large ? 8 : 5
        Text(label)
            .font(.system(size: large ? 20 : 11, weight: .medium, design: .rounded))
            .padding(.horizontal, large ? 12 : 5)
            .frame(minWidth: large ? 44 : 20, minHeight: large ? 40 : 18)
            .foregroundStyle(Crystal.ink)
            .background(Crystal.well, in: .rect(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Crystal.hairline))
            .overlay(alignment: .bottom) {
                // The key's lower lip.
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Crystal.hairline)
                    .frame(height: 1).padding(.horizontal, radius / 2).allowsHitTesting(false)
            }
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
            ForEach(Array(Self.split(description).enumerated()), id: \.offset) { _, part in Keycap(label: part, large: large) }
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

/// Capsule chip. Glass where it floats over a backdrop (Bark Server's window); `flat` on a
/// solid card, where glass would sit on an opaque surface.
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
    @Environment(\.colorScheme) private var scheme

    public var body: some View {
        let label = HStack(spacing: 6) {
            if let dot { StatusDot(color: dot) }
            if let symbol { Image(systemName: symbol).imageScale(.small).foregroundStyle(tint ?? Crystal.ink2) }
            Text(text).lineLimit(1)
        }
        if flat && style == .frosted {
            // October's pill: a raised capsule of the card material.
            label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Crystal.ink)
                .padding(.horizontal, 13)
                .frame(height: 30)
                .background(Capsule().fill(Frost.cardSolid.opacity(scheme == .dark ? 0.7 : 0.9))
                    .shadow(color: .black.opacity(scheme == .dark ? 0.25 : 0.06), radius: 8, y: 3))
                .overlay(Capsule().strokeBorder(Frost.edge))
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
                .font(.callout.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .glassEffect(.regular, in: .capsule)
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
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(color.opacity(0.12), in: .capsule)
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
    /// Neutral for your host, the accent for this Mac's Neural Engine.
    public var tint: Color { self == .remoteHost ? Crystal.ink2 : Crystal.clientAccent }
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

    public static func duration(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s >= 3600 { return "\(s / 3600)h \(s % 3600 / 60)m" }
        if s >= 60 { return "\(s / 60)m \(s % 60)s" }
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
