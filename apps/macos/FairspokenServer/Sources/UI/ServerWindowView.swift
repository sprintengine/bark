import FairspokenHost
import FairspokenUI
import FairspokenCore
import FairspokenUpdates
import SwiftUI

/// Main window, in the same language as Bark: a solid true-black (or near-white) ground, a
/// sidebar of sections divided from the page by one hairline, and a top bar with where you are
/// and the server's controls. Nothing behind the window shows through.
struct ServerWindowView: View {
    @Environment(ServerController.self) private var controller
    @Environment(UpdateController.self) private var updates

    var body: some View {
        HStack(spacing: 0) {
            ServerSidebar()
                .frame(width: 232)
                .frame(maxHeight: .infinity)
                .overlay(alignment: .trailing) { Rectangle().fill(Crystal.hairline).frame(width: 1) }
            VStack(spacing: 0) {
                ServerTopBar()
                    .background(Crystal.canvas)
                    .zIndex(1)
                ZStack {
                    PageBackground()
                    detail.transition(.opacity)
                }
                .animation(.smooth(duration: 0.25), value: controller.section)
                .updateToast(updates, style: .server)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // The sidebar's header and the top bar take the title bar's place, beside the traffic lights.
        .ignoresSafeArea(.container, edges: .top)
        .background(Crystal.canvas)
        .tint(Crystal.primary)
        .frame(minWidth: 1120, minHeight: 760)
    }

    @ViewBuilder private var detail: some View {
        if let issue = controller.configIssue {
            ConfigIssueView(message: issue)
        } else {
            switch controller.section {
            case .activity: ActivityView()
            case .clients: ClientsView()
            case .models: ModelsView()
            case .connect: ConnectView()
            case .configuration: ConfigurationView()
            }
        }
    }
}

/// The sections, with Bark Server's name beside the traffic lights and updates at the foot.
/// ↑ and ↓ move between sections.
private struct ServerSidebar: View {
    @Environment(ServerController.self) private var controller
    @Environment(UpdateController.self) private var updates
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Crystal.canvas)
                    .frame(width: 20, height: 20)
                    .background(Crystal.ink, in: .rect(cornerRadius: 6, style: .continuous))
                Text("\(Text("Bark").fontWeight(.semibold).foregroundStyle(Crystal.ink)) \(Text("Server").foregroundStyle(Crystal.ink2))")
                    .font(.system(size: 15))
                Spacer(minLength: 0)
            }
            .padding(.leading, 90)
            .frame(height: 52)
            .background { Color.clear.contentShape(.rect).gesture(WindowDragGesture()) }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Bark Server")
            .accessibilityAddTraits(.isHeader)
            VStack(spacing: 2) {
                ForEach(ServerController.Section.allCases) { section in
                    // Configuration holds Updates, so it wears the pending-update dot.
                    SettingsNavItem(section.title, symbol: section.symbol, selected: controller.section == section,
                                    badge: section == .configuration && updates.isUpdatePending) {
                        controller.section = section
                        focused = true
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                let all = ServerController.Section.allCases
                if let i = all.firstIndex(of: controller.section) {
                    controller.section = all[min(max(i + (press.key == .downArrow ? 1 : -1), 0), all.count - 1)]
                }
                return .handled
            }
            .accessibilityLabel("Sections")
            Spacer(minLength: 0)
            UpdateSidebarButton(updates: updates, style: .server)
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
        }
        .background(Crystal.canvas)
    }
}

/// Where you are, then whether it's serving, Live or Demo, and Start or Stop.
private struct ServerTopBar: View {
    @Environment(ServerController.self) private var controller

    var body: some View {
        HStack(spacing: 10) {
            Text(controller.configIssue != nil ? "Configuration" : controller.section.title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Crystal.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 12)
            ServingChip()
            SegmentedChoice("Data", selection: Binding(get: { controller.source }, set: { controller.source = $0 }),
                            options: [.init(ServerController.Source.live, "Live"), .init(ServerController.Source.demo, "Demo")])
                .help("Live shows this server; Demo shows a simulated one")
            let running = controller.runState.isRunning
            let disabled = controller.runState == .starting || controller.configIssue != nil
            // Starting is the window's one primary action; stopping is not.
            if running {
                Button { Task { await controller.stop() } } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(OutlineButtonStyle())
                    .disabled(disabled)
                    .help("Stop serving")
            } else {
                Button { Task { await controller.start() } } label: { Label("Start Serving", systemImage: "play.fill") }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(disabled)
            }
        }
        .padding(.leading, 24)
        .padding(.trailing, 12)
        .frame(height: 52)
        .background { Color.clear.contentShape(.rect).gesture(WindowDragGesture()) }
    }
}

/// The toolbar's status: "Serving on Tailscale · 100.101.102.103:48173", "Starting…", "Not serving".
private struct ServingChip: View {
    @Environment(ServerController.self) private var controller

    var body: some View {
        let state = controller.runState
        HStack(spacing: 8) {
            StatusDot(color: color(state), pulsing: state == .starting)
            Text(title(state)).fontWeight(.medium).foregroundStyle(Crystal.ink)
            if state.isRunning {
                Text(controller.accessSummary).foregroundStyle(Crystal.ink2)
            }
        }
        .lineLimit(1)
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Crystal.well, in: .rect(cornerRadius: Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Crystal.input))
        .help(help(state))
        .accessibilityElement(children: .combine)
    }

    private func title(_ s: ServerController.RunState) -> String {
        switch s {
        case .running: "Serving"
        case .starting: "Starting…"
        case .stopped: "Stopped"
        case .failed: "Not serving"
        }
    }

    private func color(_ s: ServerController.RunState) -> Color {
        switch s {
        case .running: Crystal.ok
        case .starting: Crystal.warn
        case .stopped: Crystal.ink3
        case .failed: Crystal.error
        }
    }

    private func help(_ s: ServerController.RunState) -> String {
        if case .failed(let m) = s { return m }
        return controller.endpoints.map(\.url).joined(separator: "\n")
    }
}

/// Why the server isn't serving, above every page, with the fix at hand: when another app
/// holds the port, a port field to start on another one; otherwise Try again.
struct StartProblemBanner: View {
    @Environment(ServerController.self) private var controller
    @State private var port = HostConfiguration.defaultPort + 1
    @State private var busy = false
    @State private var problem: String?

    var body: some View {
        if case .failed(let message) = controller.runState {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Crystal.error)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Not serving").font(.callout.weight(.semibold)).foregroundStyle(Crystal.ink)
                        Text(message).font(.callout).foregroundStyle(Crystal.ink2).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 8) {
                    if controller.portConflict != nil {
                        Text("Port").font(.callout).foregroundStyle(Crystal.ink2)
                        TextField("Port", value: $port, format: .number.grouping(.never))
                            .textFieldStyle(.plain).font(.mono(12.5)).padding(.horizontal, 8).frame(width: 80, height: 28)
                            .background(Crystal.well, in: .rect(cornerRadius: Radius.control, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Crystal.input))
                            .labelsHidden()
                            .onSubmit(startOnPort)
                        Button(busy ? "Starting…" : "Start on This Port", action: startOnPort)
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(busy || !(1...65_535).contains(port) || port == controller.configuration.port)
                    }
                    Button("Try Again") { Task { busy = true; await controller.start(); busy = false } }
                        .buttonStyle(OutlineButtonStyle())
                        .disabled(busy)
                }
                .padding(.leading, 26)
                if let problem { ErrorLabel(text: problem).font(.caption).padding(.leading, 26) }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .crystalWell(stroke: Crystal.error.opacity(0.45))
            .onAppear(perform: suggestPort)
            .onChange(of: controller.portConflict) { suggestPort() }
        }
    }

    /// The next port up from the one that's taken.
    private func suggestPort() {
        problem = nil
        if let taken = controller.portConflict?.port { port = taken < 65_535 ? taken + 1 : taken - 1 }
    }

    private func startOnPort() {
        guard (1...65_535).contains(port), !busy else { return }
        busy = true
        Task {
            if case .failed(let m) = await controller.setPort(port), controller.portConflict == nil { problem = m }
            busy = false
        }
    }
}

/// The still Crystal backdrop with the server's garnet wash.
struct PageBackground: View {
    var body: some View {
        CrystalBackground(accent: Crystal.serverAccent)
    }
}

private struct ConfigIssueView: View {
    var message: String
    @Environment(ServerController.self) private var controller

    var body: some View {
        CrystalPage {
            PageHeader(title: "Configuration can't be read")
            SurfaceCard {
                VStack(alignment: .leading, spacing: 14) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.fsData(.callout)).foregroundStyle(Crystal.error).textSelection(.enabled)
                    Text("Fix the file, or reset it. Resetting makes a new token, so clients pair again.")
                        .font(.callout).foregroundStyle(Crystal.ink2)
                    HStack {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([controller.configURL]) }
                            .buttonStyle(OutlineButtonStyle())
                        Button("Reset to Defaults") { Task { await controller.resetConfiguration() } }
                            .buttonStyle(PrimaryButtonStyle())
                    }
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
        }
    }
}

// MARK: - Shared pieces

/// A page: the standard margins and spacing, and why the server isn't serving, when a start
/// failed. Cards are opaque; nothing on a page is glass.
struct CrystalPage<Content: View>: View {
    var scrolls = true
    @ViewBuilder var content: Content

    var body: some View {
        if scrolls {
            ScrollView { stack }
                .scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            stack.frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var stack: some View {
        VStack(alignment: .leading, spacing: 16) {
            StartProblemBanner()
            content
        }
        .padding(.horizontal, 32)
        .padding(.top, 16)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: scrolls ? nil : .infinity, alignment: .topLeading)
    }
}

/// An opaque card (the shared card surface). What sits inside is flat (`CrystalWell`).
struct SurfaceCard<Content: View>: View {
    var padding: CGFloat = 20
    var fillHeight = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
            .cardSurface()
    }
}

/// Flat fill for a row, field or node inside a glass card (radius 12 by default).
struct CrystalWell: ViewModifier {
    var cornerRadius: CGFloat = 12
    var stroke: Color? = nil

    func body(content: Content) -> some View {
        content
            .background(Crystal.well, in: .rect(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(stroke ?? Crystal.hairline, lineWidth: stroke == nil ? 1 : 1.5))
    }
}

extension View {
    func crystalWell(cornerRadius: CGFloat = 12, stroke: Color? = nil) -> some View {
        modifier(CrystalWell(cornerRadius: cornerRadius, stroke: stroke))
    }
}

/// Page title with at most one line of subtitle.
struct PageHeader<Trailing: View>: View {
    var title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(TypeScale.title).tracking(-0.3).foregroundStyle(Crystal.ink)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle).font(.system(size: 14)).foregroundStyle(Crystal.ink2).lineLimit(1)
                }
            }
            Spacer()
            trailing
        }
        .padding(.bottom, 4)
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// A small heading above a card.
struct SectionTitle: View {
    var text: String
    var body: some View {
        Text(text).font(.system(size: 16, weight: .semibold)).foregroundStyle(Crystal.ink).padding(.top, 6)
            .accessibilityAddTraits(.isHeader)
    }
}

/// An error line: always with the triangle, so it never reads as the garnet accent.
struct ErrorLabel: View {
    var text: String
    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.callout).foregroundStyle(Crystal.error)
    }
}

/// Notices raised by actions (a failed login-item change, a download refused).
struct NoticeBanner: View {
    @Environment(ServerController.self) private var controller

    var body: some View {
        if let notice = controller.notice {
            HStack(spacing: 10) {
                Image(systemName: "info.circle").foregroundStyle(Crystal.ink2)
                Text(notice).font(.callout).foregroundStyle(Crystal.ink)
                Spacer()
                Button("Dismiss") { controller.dismissNotice() }.buttonStyle(GhostButtonStyle())
            }
            .padding(12)
            .crystalWell()
        }
    }
}

/// Copy with a moment of "copied" feedback; icon-only when `label` is nil.
struct CopyButton: View {
    var value: String
    var label: String? = nil
    @Environment(ServerController.self) private var controller
    @State private var copied = false

    var body: some View {
        Button {
            controller.copy(value)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            if let label {
                Label(copied ? "Copied" : label, systemImage: copied ? "checkmark" : "doc.on.doc")
            } else {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").frame(width: 16)
            }
        }
        .buttonStyle(OutlineButtonStyle(compact: label == nil))
        .help("Copy")
        .accessibilityLabel(copied ? "Copied" : (label ?? "Copy"))
    }
}

enum ServerFormat {
    static func ms(_ value: Double?) -> String {
        guard let value else { return "–" }
        return value >= 1000 ? String(format: "%.1f s", value / 1000) : "\(Int(value.rounded())) ms"
    }

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s >= 86_400 { return "\(s / 86_400) d \(s % 86_400 / 3600) h" }
        if s >= 3600 { return "\(s / 3600) h \(s % 3600 / 60) m" }
        if s >= 60 { return "\(s / 60) m \(s % 60) s" }
        return "\(s) s"
    }

    static func ago(_ epochMs: Double, now: Date = Date()) -> String {
        guard epochMs > 0 else { return "–" }
        let delta = now.timeIntervalSince1970 - epochMs / 1000
        if delta < 60 { return "just now" }
        if delta < 3600 { return "\(Int(delta / 60)) min ago" }
        if delta < 86_400 { return "\(Int(delta / 3600)) h ago" }
        return Date(timeIntervalSince1970: epochMs / 1000).formatted(.dateTime.day().month(.abbreviated))
    }

    static func clock(_ epochMs: Double) -> String {
        Date(timeIntervalSince1970: epochMs / 1000).formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
    }
}

extension UpdateStyle {
    /// The server's garnet hint for actions; warnings in the Crystal warning amber.
    static let server = UpdateStyle(accent: Crystal.serverAccent, warning: Crystal.warn)
}
