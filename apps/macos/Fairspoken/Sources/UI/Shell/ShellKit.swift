import FairspokenCore
import FairspokenUI
import SwiftUI

// MARK: - App monogram

/// An app as a small tile holding two letters ("MA" for Mail), tinted by app. Notes written in
/// Bark show Bark's glyph instead.
struct AppMonogram: View {
    var appName: String?
    var bundleID: String?
    var isNote = false
    var size: CGFloat = 16

    var body: some View {
        let tint = AppMonogram.tint(for: bundleID ?? appName ?? "")
        let shape = RoundedRectangle(cornerRadius: size >= 20 ? 5 : 4, style: .continuous)
        Group {
            if isNote {
                Image(systemName: "waveform")
                    .font(.system(size: size * 0.55, weight: .bold))
                    .foregroundStyle(Crystal.canvas)
                    .frame(width: size, height: size)
                    .background(Crystal.ink, in: shape)
            } else {
                Text(AppMonogram.letters(appName ?? AppInfo.displayName))
                    .font(.system(size: size >= 20 ? 9 : 7.5, weight: .bold, design: .monospaced))
                    .tracking(-0.15)
                    .foregroundStyle(tint)
                    .frame(width: size, height: size)
                    .background(tint.opacity(0.14), in: shape)
            }
        }
        .accessibilityHidden(true)
    }

    /// Two letters: the initials of a two-word name ("Google Docs" → GD), else the first two.
    static func letters(_ name: String) -> String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.count >= 2, let a = words[0].first, let b = words[1].first { return "\(a)\(b)".uppercased() }
        return String(name.filter { $0.isLetter || $0.isNumber }.prefix(2)).uppercased()
    }

    /// The palette's hues only: blue, orange, sky, grey, amber. Stable for an app across launches.
    static func tint(for key: String) -> Color {
        let known: [String: Int] = ["com.apple.mail": 0, "com.tinyspeck.slackmacgap": 1, "com.apple.dt.xcode": 2,
                                    "com.apple.mobilesms": 3, "com.apple.notes": 4]
        let index = known[key.lowercased()] ?? key.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[index % palette.count]
    }

    static let palette: [Color] = [
        Color(hex: 0x1D4ED8, dark: 0x51A2FF),
        Color(hex: 0xC2410C, dark: 0xFF8904),
        Color(hex: 0x0369A1, dark: 0x00BCFF),
        Color(hex: 0x4B5563, dark: 0x99A1AF),
        Color(hex: 0x92400E, dark: 0xFFB900),
    ]
}

// MARK: - Icon button

/// A square icon button: 28 pt (24 compact), muted at rest, a fill under the pointer or when on.
struct IconButton: View {
    var symbol: String
    var label: String
    var size: CGFloat = 28
    var on = false
    var help: String?
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size >= 28 ? 14 : 12.5, weight: .regular))
                .foregroundStyle(on || hovered ? Crystal.ink : Crystal.ink2)
                .frame(width: size, height: size)
                .background(on ? Crystal.selected : hovered ? Crystal.rowHover : .clear,
                            in: .rect(cornerRadius: size >= 28 ? Radius.control : 6, style: .continuous))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help ?? label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The "T" of a text style: the stroke glyph rows and menus use for a dictation's style.
struct TypeGlyph: View {
    var size: CGFloat = 12
    var color: Color = Crystal.ink3

    var body: some View {
        TypeShape()
            .stroke(color, style: StrokeStyle(lineWidth: max(1, size / 10), lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private struct TypeShape: Shape {
        func path(in rect: CGRect) -> Path {
            let s = rect.width / 24
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
            var path = Path()
            path.move(to: p(4, 7)); path.addLine(to: p(4, 4)); path.addLine(to: p(20, 4)); path.addLine(to: p(20, 7))
            path.move(to: p(9, 20)); path.addLine(to: p(15, 20))
            path.move(to: p(12, 4)); path.addLine(to: p(12, 20))
            return path
        }
    }
}

// MARK: - Words about a dictation

enum DictationText {
    /// A style's display name: "email" → "Email".
    static func styleName(_ id: String?) -> String? {
        guard let id, !id.isEmpty else { return nil }
        switch id {
        case "verbatim": return "Verbatim"
        case "casual": return "Casual"
        case "clean": return "Clean"
        case "email": return "Email"
        case "document": return "Document"
        case "notes": return "Notes"
        case "code": return "Code"
        default: return id.prefix(1).uppercased() + id.dropFirst()
        }
    }

    /// The row's title: the first line, trimmed; past a short greeting line ("Hi Aoife,") when
    /// more follows, so an email reads by what it asks.
    static func title(_ item: TranscriptHistoryItem) -> String {
        let lines = item.text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard var line = lines.first else { return "Empty dictation" }
        if lines.count > 1, line.hasSuffix(","), line.split(separator: " ").count <= 4 { line = lines[1] }
        return line
    }

    /// The meta line: "Email · 38 words", "Note · 12 words", "38 words".
    static func meta(_ item: TranscriptHistoryItem) -> String {
        let words = "\(item.wordCount) word\(item.wordCount == 1 ? "" : "s")"
        if item.isBarkNote { return "Note · \(words)" }
        if let style = styleName(item.style) { return "\(style) · \(words)" }
        return words
    }

    /// Where it went: "Mail", a website's host ("docs.google.com"), "Bark" for a note.
    static func appName(_ item: TranscriptHistoryItem) -> String {
        if item.isBarkNote { return AppInfo.displayName }
        if let host = item.destinationHost, !host.isEmpty { return host }
        return item.appName ?? AppInfo.displayName
    }

    /// The monogram's name: the website's own name for a host ("docs.google.com" → DG is no use,
    /// so the second-level label: "google" → GO), else the app.
    static func monogramName(_ item: TranscriptHistoryItem) -> String {
        if let host = item.destinationHost, !host.isEmpty {
            let labels = host.split(separator: ".")
            if labels.count >= 2 { return String(labels[labels.count - 2]) }
            return host
        }
        return item.appName ?? AppInfo.displayName
    }

    /// "now", "2m", "3h", "1d", "3w": compact, for the thread list.
    static func age(_ date: Date, now: Date = .now) -> String {
        let s = max(0, now.timeIntervalSince(date))
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86_400 { return "\(Int(s / 3600))h" }
        if s < 86_400 * 14 { return "\(Int(s / 86_400))d" }
        return "\(Int(s / (86_400 * 7)))w"
    }

    /// "2 minutes ago", for VoiceOver.
    static func spokenAge(_ date: Date) -> String {
        RelativeDateTimeFormatter().localizedString(for: date, relativeTo: .now)
    }
}

/// History grouped for the thread list: Today, Yesterday, Previous 7 days, Earlier.
enum HistoryGroups {
    struct Group: Identifiable {
        var title: String
        var items: [TranscriptHistoryItem]
        var id: String { title }
    }

    static func make(_ items: [TranscriptHistoryItem], now: Date = .now, calendar: Calendar = .current) -> [Group] {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let week = calendar.date(byAdding: .day, value: -7, to: today) ?? today
        var buckets: [[TranscriptHistoryItem]] = [[], [], [], []]
        for item in items {
            let d = item.date
            buckets[d >= today ? 0 : d >= yesterday ? 1 : d >= week ? 2 : 3].append(item)
        }
        let titles = ["Today", "Yesterday", "Previous 7 days", "Earlier"]
        return zip(titles, buckets).compactMap { $1.isEmpty ? nil : Group(title: $0, items: $1) }
    }
}

// MARK: - Dictate button

/// The round dictate button: the primary blue with a microphone at rest, a stop glyph and a red
/// ring that follows the voice while listening.
struct DictateButton: View {
    var dictation: DictationController
    var size: CGFloat = 32
    var action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let listening = dictation.phase.isListening
        let busy = dictation.phase == .transcribing
        Button(action: action) {
            ZStack {
                if busy {
                    ProgressView().controlSize(.small).tint(Crystal.onAccent)
                } else {
                    Image(systemName: listening ? "stop.fill" : "mic")
                        .font(.system(size: size * 0.42, weight: .medium))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .foregroundStyle(Crystal.onAccent)
            .frame(width: size, height: size)
            .background(Circle().fill(Crystal.primary))
            .overlay(Circle().strokeBorder(.white.opacity(0.16), lineWidth: 1).mask(alignment: .top) {
                Rectangle().frame(height: size * 0.18)
            })
            .background {
                if listening && !reduceMotion {
                    TimelineView(.animation(minimumInterval: 1 / 30)) { _ in
                        let level = CGFloat(dictation.meter.snapshot().level)
                        Circle().stroke(Crystal.recording.opacity(0.55), lineWidth: 2)
                            .frame(width: size + 4 + level * 8, height: size + 4 + level * 8)
                    }
                } else if listening {
                    Circle().stroke(Crystal.recording.opacity(0.55), lineWidth: 2).frame(width: size + 6, height: size + 6)
                }
            }
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .help(listening ? "Stop" : "Dictate here")
        .accessibilityLabel(listening ? "Stop dictation" : "Start dictation")
    }
}

// MARK: - Grouped card

/// The settings idiom: a card of divided rows (12 pt corners, a soft edge).
struct GroupCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(Crystal.card.opacity(0.4), in: .rect(cornerRadius: Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Crystal.hairlineSoft))
    }
}

/// A divider between a grouped card's rows.
struct SoftDivider: View {
    var vertical = false
    var body: some View {
        Rectangle().fill(Crystal.hairlineSoft)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
            .accessibilityHidden(true)
    }
}

extension View {
    /// The composer's lift: a long soft shadow in dark mode, a faint one in light.
    func composerShadow() -> some View { modifier(ComposerShadow()) }
}

private struct ComposerShadow: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.07), radius: scheme == .dark ? 16 : 12, y: scheme == .dark ? 12 : 6)
    }
}
