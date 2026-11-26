import AppKit
import SwiftUI

// The settings idiom, shared by Bark and Bark Server: a centred column with a page title, section
// headings, and grouped cards of divided rows (title, a one-line description, the control on the
// right). Switches are the only blue on a settings page.

/// Metrics for settings pages.
public enum SettingsMetrics {
    /// The page column's width cap.
    public static let column: CGFloat = 768
    /// Padding inside a row; titles, descriptions and headings line up on it.
    public static let rowH: CGFloat = 16
    public static let rowV: CGFloat = 12
    /// Gap between a row's text and its control.
    public static let controlGap: CGFloat = 32
    /// The widest a row's description runs.
    public static let detailWidth: CGFloat = 520
}

/// A settings page: a scrolling column, at most 768 pt wide, centred, under the page's title and
/// one quiet line.
public struct SettingsPage<Content: View>: View {
    var title: String?
    var subtitle: String?
    @ViewBuilder var content: Content

    public init(title: String? = nil, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let title {
                    SettingsPageTitle(title, subtitle: subtitle)
                        .padding(.bottom, 4)
                }
                content
            }
            .frame(maxWidth: SettingsMetrics.column, alignment: .topLeading)
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
    }
}

/// A settings page's title: 22 pt semibold with one muted line, lined up with the rows' text.
public struct SettingsPageTitle: View {
    var title: String
    var subtitle: String?

    public init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 22, weight: .semibold))
                .tracking(-0.33)
                .foregroundStyle(Crystal.ink)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(Crystal.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, SettingsMetrics.rowH)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A heading over a group (16 pt semibold), with an optional action on the right, then the group.
public struct SettingsSection<Content: View, Trailing: View>: View {
    var title: String?
    var footer: String?
    var first: Bool
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    public init(_ title: String?, footer: String? = nil, first: Bool = false,
                @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.first = first
        self.trailing = trailing()
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                HStack(alignment: .center, spacing: 12) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Crystal.ink)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    trailing
                }
                .frame(minHeight: 28)
                .padding(.horizontal, SettingsMetrics.rowH)
                .padding(.bottom, 10)
            }
            SettingsGroup { content }
            if let footer {
                Text(footer)
                    .font(.system(size: 12))
                    .foregroundStyle(Crystal.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, SettingsMetrics.rowH)
                    .padding(.top, 8)
            }
        }
        .padding(.top, first ? 20 : 28)
    }
}

extension SettingsSection where Trailing == EmptyView {
    public init(_ title: String?, footer: String? = nil, first: Bool = false, @ViewBuilder content: () -> Content) {
        self.init(title, footer: footer, first: first, trailing: { EmptyView() }, content: content)
    }
}

/// A grouped card: 12 pt corners, a soft edge, the card colour at 40%, its rows divided by soft
/// hairlines.
public struct SettingsGroup<Content: View>: View {
    @ViewBuilder var content: Content

    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        VStack(spacing: 0) {
            Group(subviews: content) { subviews in
                ForEach(Array(subviews.enumerated()), id: \.element.id) { index, subview in
                    if index > 0 {
                        Rectangle().fill(Crystal.hairlineSoft).frame(height: 1).accessibilityHidden(true)
                    }
                    subview
                }
            }
        }
        .background(Crystal.card.opacity(0.4), in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Crystal.hairlineSoft))
    }
}

/// One row of a group: the title (14 pt medium) with an optional badge, a one-line description
/// (12 pt muted), anything under them (an example), and the control on the right.
public struct SettingsRow<Accessory: View, Below: View, Control: View>: View {
    var title: String
    var detail: String?
    var mono: Bool
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var below: Below
    @ViewBuilder var control: Control

    /// Everything: a badge beside the title, something under the description, the control.
    public init(_ title: String, detail: String? = nil, mono: Bool = false,
                @ViewBuilder accessory: () -> Accessory, @ViewBuilder below: () -> Below, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.mono = mono
        self.accessory = accessory()
        self.below = below()
        self.control = control()
    }

    public var body: some View {
        HStack(alignment: .center, spacing: SettingsMetrics.controlGap) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Crystal.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    accessory
                }
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(mono ? .mono(12) : .system(size: 12))
                        .lineSpacing(2)
                        .foregroundStyle(Crystal.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: SettingsMetrics.detailWidth, alignment: .leading)
                        .textSelection(.enabled)
                }
                below
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) { control }
                .fixedSize()
        }
        .padding(.horizontal, SettingsMetrics.rowH)
        .padding(.vertical, SettingsMetrics.rowV)
        .frame(minHeight: 48)
        .accessibilityElement(children: .contain)
    }
}

extension SettingsRow where Accessory == EmptyView, Below == EmptyView {
    /// Title, description and control: `SettingsRow("Title", detail: "…") { Toggle(…) }`.
    public init(_ title: String, detail: String? = nil, mono: Bool = false, @ViewBuilder control: () -> Control = { EmptyView() }) {
        self.init(title, detail: detail, mono: mono, accessory: { EmptyView() }, below: { EmptyView() }, control: control)
    }
}

extension SettingsRow where Below == EmptyView {
    /// With a badge beside the title: `SettingsRow("Title") { Badge(…) } control: { … }`.
    public init(_ title: String, detail: String? = nil, mono: Bool = false,
                @ViewBuilder accessory: () -> Accessory, @ViewBuilder control: () -> Control) {
        self.init(title, detail: detail, mono: mono, accessory: accessory, below: { EmptyView() }, control: control)
    }
}

/// A switch in the settings idiom: 30 × 18, the primary blue with a black knob when on, the
/// input grey with a muted knob when off. A button underneath, so it takes keyboard focus and
/// VoiceOver reads it as a switch.
public struct SettingsSwitchStyle: ToggleStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        SwitchBody(configuration: configuration)
    }

    private struct SwitchBody: View {
        var configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.colorScheme) private var scheme
        @State private var hovered = false

        var body: some View {
            let on = configuration.isOn
            Button {
                withAnimation(Motion.unlessReduced(Motion.fast, reduceMotion)) { configuration.isOn.toggle() }
            } label: {
                ZStack(alignment: on ? .trailing : .leading) {
                    Capsule()
                        .fill(on ? Crystal.primary : Crystal.input)
                        .overlay {
                            if hovered && isEnabled { Capsule().fill(Color.white.opacity(on ? 0.08 : 0.05)) }
                        }
                    Circle()
                        .fill(on ? (scheme == .dark ? Color.black : Color.white) : (scheme == .dark ? Crystal.ink2 : Color.white))
                        .shadow(color: .black.opacity(scheme == .dark || on ? 0 : 0.25), radius: 1, y: 0.5)
                        .frame(width: 14, height: 14)
                        .padding(2)
                }
                .frame(width: 30, height: 18)
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .accessibilityRepresentation {
                Toggle(isOn: configuration.$isOn) { configuration.label }
            }
        }
    }
}

extension ToggleStyle where Self == SettingsSwitchStyle {
    /// The settings switch.
    public static var settingsSwitch: SettingsSwitchStyle { SettingsSwitchStyle() }
}

/// A segmented choice in the settings idiom: a faint well holding 24 pt segments, the chosen one
/// raised.
public struct SegmentedChoice<Value: Hashable>: View {
    public struct Option: Identifiable {
        public var value: Value
        public var title: String
        public var symbol: String?
        public var id: String { title }
        public init(_ value: Value, _ title: String, symbol: String? = nil) {
            self.value = value
            self.title = title
            self.symbol = symbol
        }
    }

    @Binding var selection: Value
    var options: [Option]
    var label: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var namespace

    public init(_ label: String, selection: Binding<Value>, options: [Option]) {
        self.label = label
        _selection = selection
        self.options = options
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                Segment(option: option, selected: option.value == selection, namespace: namespace) {
                    withAnimation(Motion.unlessReduced(Motion.fast, reduceMotion)) { selection = option.value }
                }
            }
        }
        .padding(2)
        .background(Crystal.well, in: .rect(cornerRadius: Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Crystal.hairlineSoft))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private struct Segment: View {
        var option: Option
        var selected: Bool
        var namespace: Namespace.ID
        var action: () -> Void
        @State private var hovered = false
        @Environment(\.colorScheme) private var scheme

        var body: some View {
            Button(action: action) {
                HStack(spacing: 6) {
                    if let symbol = option.symbol {
                        Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                    }
                    Text(option.title)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected || hovered ? Crystal.ink : Crystal.ink2)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(scheme == .dark ? Color.white.opacity(0.08) : Color.white)
                            .shadow(color: .black.opacity(scheme == .dark ? 0.4 : 0.12), radius: 1, y: 1)
                            .matchedGeometryEffect(id: "segment", in: namespace)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .accessibilityLabel(option.title)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
        }
    }
}

/// The face of a select: an outline control with the current value and up-down chevrons. Put it
/// in a `Menu`'s label.
public struct SelectFace: View {
    var title: String
    var minWidth: CGFloat
    var pressed: Bool
    @State private var hovered = false

    public init(_ title: String, minWidth: CGFloat = 132, pressed: Bool = false) {
        self.title = title
        self.minWidth = minWidth
        self.pressed = pressed
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Crystal.ink)
                .lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Crystal.ink2)
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(minWidth: minWidth, minHeight: 28)
        .background(shape.fill(pressed ? Crystal.selected : hovered ? Crystal.rowHover : Crystal.well))
        .overlay(shape.strokeBorder(Crystal.input))
        .contentShape(shape)
        .onHover { hovered = $0 }
    }
}

/// A menu that looks like a select: `SelectFace` with the current value.
public struct SelectMenu<Content: View>: View {
    var title: String
    var label: String
    var minWidth: CGFloat
    @ViewBuilder var content: Content

    public init(_ title: String, label: String, minWidth: CGFloat = 132, @ViewBuilder content: () -> Content) {
        self.title = title
        self.label = label
        self.minWidth = minWidth
        self.content = content()
    }

    public var body: some View {
        Menu {
            content
        } label: {
            SelectFace(title, minWidth: minWidth)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(label)
        .accessibilityValue(title)
    }
}

/// A radio mark: a ring, or the primary blue with a white centre when chosen.
public struct RadioMark: View {
    var on: Bool
    public init(on: Bool) { self.on = on }

    public var body: some View {
        ZStack {
            if on {
                Circle().fill(Crystal.primary)
                Circle().fill(Color.white).frame(width: 6, height: 6)
            } else {
                Circle().strokeBorder(Crystal.ink3.opacity(0.6), lineWidth: 1)
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}

/// A worked example under a row: mono text on a faint fill. Removed words orange and struck
/// through, added ones blue.
public struct ExampleChip: View {
    public enum Part {
        case plain(String)
        case removed(String)
        case added(String)
    }

    var parts: [Part]
    public init(_ parts: [Part]) { self.parts = parts }

    public var body: some View {
        Text(attributed)
            .font(.mono(12))
            .lineSpacing(2)
            .foregroundStyle(Crystal.ink2)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Crystal.well, in: .rect(cornerRadius: 6, style: .continuous))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 5)
            .accessibilityLabel(spoken)
    }

    private var attributed: AttributedString {
        var out = AttributedString()
        for (i, part) in parts.enumerated() {
            if i > 0 { out += AttributedString(" ") }
            switch part {
            case .plain(let s):
                out += AttributedString(s)
            case .removed(let s):
                var a = AttributedString(s)
                a.foregroundColor = Crystal.removed
                a.backgroundColor = Crystal.removed.opacity(0.10)
                a.strikethroughStyle = Text.LineStyle(pattern: .solid, color: Crystal.removed.opacity(0.6))
                out += a
            case .added(let s):
                var a = AttributedString(s)
                a.foregroundColor = Crystal.info
                a.backgroundColor = Crystal.info.opacity(0.12)
                out += a
            }
        }
        return out
    }

    private var spoken: String {
        "Example: " + parts.map { part -> String in
            switch part {
            case .plain(let s): s
            case .removed(let s): "\(s), removed,"
            case .added(let s): "becomes \(s)"
            }
        }.joined(separator: " ")
    }
}

/// A settings sidebar item: an icon, a title and an optional count, the selected one on the
/// selected-row fill.
public struct SettingsNavItem: View {
    var title: String
    var symbol: String
    var count: String?
    var selected: Bool
    var badge: Bool
    var action: () -> Void
    @State private var hovered = false

    public init(_ title: String, symbol: String, count: String? = nil, selected: Bool, badge: Bool = false,
                action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.count = count
        self.selected = selected
        self.badge = badge
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(selected ? Crystal.ink : Crystal.ink3)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(selected || hovered ? Crystal.ink : Crystal.ink.opacity(0.8))
                    .lineLimit(1)
                Spacer(minLength: 6)
                if badge {
                    Circle().fill(Crystal.primary).frame(width: 6, height: 6).accessibilityHidden(true)
                }
                if let count {
                    Text(count).font(.system(size: 12)).monospacedDigit().foregroundStyle(Crystal.ink3)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(selected ? Crystal.selected : hovered ? Crystal.rowHover : .clear,
                        in: .rect(cornerRadius: 6, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(badge ? "\(title), update available" : title)
        .accessibilityValue(count ?? "")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// A group label in a settings sidebar.
public struct SettingsNavLabel: View {
    var title: String
    public init(_ title: String) { self.title = title }
    public var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Crystal.ink3)
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A text field in the settings idiom: a faint well with the input edge, 28 pt high, the primary
/// blue round it while it has the focus.
public struct SettingsTextField: View {
    var label: String
    @Binding var text: String
    var prompt: String
    var secure: Bool
    var mono: Bool
    var onSubmit: () -> Void
    @FocusState private var focused: Bool
    @State private var hovered = false

    public init(_ label: String, text: Binding<String>, prompt: String, secure: Bool = false, mono: Bool = false,
                onSubmit: @escaping () -> Void = {}) {
        self.label = label
        _text = text
        self.prompt = prompt
        self.secure = secure
        self.mono = mono
        self.onSubmit = onSubmit
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        Group {
            if secure {
                SecureField(label, text: $text, prompt: Text(prompt).foregroundStyle(Crystal.ink3))
            } else {
                TextField(label, text: $text, prompt: Text(prompt).foregroundStyle(Crystal.ink3))
            }
        }
        .textFieldStyle(.plain)
        .labelsHidden()
        .font(mono ? .mono(12.5) : .system(size: 13))
        .foregroundStyle(Crystal.ink)
        .focused($focused)
        .onSubmit(onSubmit)
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(shape.fill(hovered && !focused ? Crystal.rowHover : Crystal.well))
        .overlay(shape.strokeBorder(focused ? Crystal.primary : Crystal.input, lineWidth: focused ? 1.5 : 1))
        .contentShape(shape)
        .onTapGesture { focused = true }
        .onHover { hovered = $0 }
        .accessibilityLabel(label)
    }
}

/// A value with a stepper beside it: "2 min" [−|+].
public struct ValueStepper: View {
    @Binding var value: Int
    var range: ClosedRange<Int>
    var step: Int
    var label: String
    var format: (Int) -> String

    public init(value: Binding<Int>, range: ClosedRange<Int>, step: Int = 1, label: String, format: @escaping (Int) -> String) {
        _value = value
        self.range = range
        self.step = step
        self.label = label
        self.format = format
    }

    public var body: some View {
        HStack(spacing: 8) {
            Text(format(value)).font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(Crystal.ink)
            Stepper(label, value: $value, in: range, step: step).labelsHidden()
        }
        .accessibilityElement(children: .combine)
    }
}
