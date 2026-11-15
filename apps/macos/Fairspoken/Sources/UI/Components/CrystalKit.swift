import FairspokenUI
import SwiftUI

/// Crystal layout constants for the client (design/crystal/README.md): 12 for cards, 8 for rows
/// and fields, one compact rhythm of spacing.
enum Layout {
    static let card: CGFloat = CardMetrics.radius
    static let row: CGFloat = 8
    static let gap: CGFloat = 12
    static let pageH: CGFloat = 28
    static let pageTop: CGFloat = 22
    /// The content column's width cap, so lines never run the width of a big window.
    static let readable: CGFloat = 980
}

/// A screen title: semibold, slightly tight, with at most one quiet line under it.
struct PageTitle<Trailing: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(TypeScale.title)
                    .tracking(-0.2)
                    .foregroundStyle(Crystal.ink)
                if let subtitle {
                    Text(subtitle).font(TypeScale.meta).foregroundStyle(Crystal.ink2)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 12)
            trailing
        }
    }
}

extension View {
    /// Screenshot runs: controls draw as in the key window even when the session can't make the
    /// app active (a locked screen).
    @ViewBuilder func screenshotActive() -> some View {
        if AppWindow.appearsActive { environment(\.controlActiveState, .key) } else { self }
    }

    /// The flat fill for things that sit inside a card: fields, results, code.
    func well(cornerRadius: CGFloat = Layout.row) -> some View {
        background(Crystal.well, in: .rect(cornerRadius: cornerRadius))
    }

    /// A secondary button inside a card.
    func cardButton() -> some View {
        buttonStyle(.bordered).buttonBorderShape(.capsule)
    }

    /// A small, title-style card heading (13 pt semibold).
    func cardHeading() -> some View {
        font(.system(size: 13, weight: .semibold)).foregroundStyle(Crystal.ink)
    }
}

extension ModelLibrary.EngineState {
    var tint: Color {
        if case .failed = self { return Crystal.error }
        return isReady ? Crystal.ok : isBusy ? Crystal.warn : Crystal.ink3
    }
}

extension HostStatus {
    /// "Connected", "Checking…", "Not reachable", "Not set".
    var stateLabel: String {
        switch state {
        case .notConfigured: "Not set"
        case .checking: "Checking…"
        case .connected: "Connected"
        case .failed: "Not reachable"
        }
    }

    var tint: Color {
        switch state {
        case .connected: Crystal.ok
        case .checking: Crystal.warn
        case .failed: Crystal.error
        case .notConfigured: Crystal.ink3
        }
    }
}
