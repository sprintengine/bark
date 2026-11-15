import SwiftUI

/// Metrics for solid content surfaces (tables, lists, detail sheets): opaque cards with a 12 pt
/// radius, hairline separators, 13 pt body text and compact rows. Kept in one place so a later
/// restyle of the app's chrome changes them once.
public enum ContentMetrics {
    public static let cornerRadius: CGFloat = 12
    public static let bodySize: CGFloat = 13
    public static let rowHeight: CGFloat = 40
    public static let rowPadding: CGFloat = 12
    public static let columnSpacing: CGFloat = 14
}

extension Crystal {
    /// The opaque fill of a content card.
    public static let surface = Color(hex: 0xFFFFFF, dark: 0x16191D)
    /// A row under the pointer.
    public static let rowHover = Color(light: NSColor(srgbRed: 16 / 255, green: 24 / 255, blue: 32 / 255, alpha: 0.035),
                                       dark: NSColor(white: 1, alpha: 0.04))
}

extension Font {
    /// Body text in content cards (13 pt).
    public static let contentBody = Font.system(size: ContentMetrics.bodySize)
    /// Column headings and secondary row text.
    public static let contentCaption = Font.system(size: 11, weight: .medium)
}

/// An opaque card for content: solid fill, 12 pt corners, a hairline edge. No glass, so it can
/// hold rows, fields and controls directly.
public struct ContentCard<Content: View>: View {
    var padding: CGFloat
    @ViewBuilder var content: Content

    public init(padding: CGFloat = 0, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: ContentMetrics.cornerRadius, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Crystal.surface, in: shape)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Crystal.hairline))
    }
}

/// A one-pixel separator between rows.
public struct Hairline: View {
    var inset: CGFloat
    public init(inset: CGFloat = 0) { self.inset = inset }
    public var body: some View {
        Rectangle().fill(Crystal.hairline).frame(height: 1).padding(.leading, inset)
            .accessibilityHidden(true)
    }
}

/// A 1…5 score as five short segments, filled up to `value`.
public struct ScoreBar: View {
    var value: Int
    var tint: Color
    var label: String
    public init(value: Int, tint: Color = Crystal.clientAccent, label: String) {
        self.value = value
        self.tint = tint
        self.label = label
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(i < value ? tint : Crystal.hairline)
                    .frame(width: 9, height: 8)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue("\(value) of 5")
    }
}

/// A compact text badge beside a name: EN, NEW, Recommended, In use.
public struct Badge: View {
    public enum Style { case neutral, accent, positive, outline }
    var text: String
    var style: Style
    public init(_ text: String, style: Style = .neutral) {
        self.text = text
        self.style = style
    }

    public var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(foreground)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(background, in: .rect(cornerRadius: 4, style: .continuous))
            .overlay {
                if style == .outline {
                    RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Crystal.ink3.opacity(0.6))
                }
            }
    }

    private var foreground: Color {
        switch style {
        case .neutral, .outline: Crystal.ink2
        case .accent: Crystal.clientAccent
        case .positive: Crystal.ok
        }
    }

    private var background: Color {
        switch style {
        case .neutral: Crystal.well
        case .accent: Crystal.clientAccent.opacity(0.12)
        case .positive: Crystal.ok.opacity(0.12)
        case .outline: .clear
        }
    }
}

/// A search field for the top of a content screen.
public struct ContentSearchField: View {
    @Binding var text: String
    var prompt: String
    public init(text: Binding<String>, prompt: String) {
        _text = text
        self.prompt = prompt
    }

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Crystal.ink3)
            TextField(prompt, text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Crystal.ink3) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
            }
        }
        .font(.contentBody)
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(Crystal.surface, in: .rect(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Crystal.hairline))
    }
}

/// A table column heading that sorts when clicked; shows a chevron while it is the sort.
public struct SortHeader: View {
    var title: String
    var active: Bool
    var action: () -> Void
    public init(_ title: String, active: Bool, action: @escaping () -> Void) {
        self.title = title
        self.active = active
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(title)
                if active { Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)) }
            }
            .font(.contentCaption)
            .foregroundStyle(active ? Crystal.ink : Crystal.ink3)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// A small circular progress indicator with a stop button in the middle (downloads).
public struct ProgressStopButton: View {
    var fraction: Double?
    var tint: Color
    var action: () -> Void
    public init(fraction: Double?, tint: Color = Crystal.clientAccent, action: @escaping () -> Void) {
        self.fraction = fraction
        self.tint = tint
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(Crystal.hairline, lineWidth: 2.5)
                if let fraction {
                    Circle().trim(from: 0, to: max(0.02, fraction))
                        .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                } else {
                    ProgressView().controlSize(.mini)
                }
                RoundedRectangle(cornerRadius: 1.5).fill(Crystal.ink2).frame(width: 7, height: 7)
            }
            .frame(width: 22, height: 22)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help("Stop the download")
        .accessibilityLabel("Stop the download")
        .accessibilityValue(fraction.map { "\(Int($0 * 100)) percent" } ?? "")
    }
}
