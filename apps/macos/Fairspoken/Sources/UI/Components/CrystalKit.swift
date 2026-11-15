import FairspokenUI
import SwiftUI

/// Layout constants for the client: large plain cards (`Plain.radius`), 8 for rows and fields,
/// generous spacing.
enum Layout {
    static let card: CGFloat = Plain.radius
    static let row: CGFloat = 8
    static let gap: CGFloat = 16
    static let pageH: CGFloat = 32
    /// Below the toolbar band, which the content starts under.
    static let pageTop: CGFloat = 16
    /// The content column's width cap, so lines never run the width of a big window.
    static let readable: CGFloat = 1120
}

extension Font {
    /// The Bark wordmark's face: Fraunces SemiBold, bundled (Resources/Fonts, SIL OFL 1.1).
    /// Use it for the name and the greeting only; everything else is SF Pro.
    static func barkWordmark(_ size: CGFloat) -> Font {
        .custom("Fraunces-SemiBold", fixedSize: size)
    }
}

/// A screen title: large and bold, with at most one quiet line under it.
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
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 30, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(Crystal.ink)
                if let subtitle {
                    Text(subtitle).font(.system(size: 15)).foregroundStyle(Crystal.ink2)
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
