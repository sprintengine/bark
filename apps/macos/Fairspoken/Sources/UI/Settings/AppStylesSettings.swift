import AppKit
import FairspokenCore
import FairspokenUI
import SwiftUI
import UniformTypeIdentifiers

/// Settings › App styles: the style for each kind of app, then every app and site with its own
/// rule or seen in history, each with a style picker and a before-and-after preview made by the
/// real formatter.
enum AppStylesSettings {
    typealias Row = SettingsCatalog.Row
    typealias Section = SettingsCatalog.Section

    @MainActor
    static func sections(_ model: AppModel) -> [Section] {
        let rules = model.settings.settings.styleRules
        let destinations = StyleDestinations.list(model)
        var defaults: [Row] = StyleCategory.allCases.map { category in
            Row(id: "category-\(category.rawValue)", searchText: "\(category.name) apps \(category.examples) default style",
                view: CategoryRow(category: category))
        }
        defaults.append(Row(id: "category-other", searchText: "Everything else default style other apps",
                            view: SettingsRow("Everything else", detail: "Any app or site not covered above, or listed below.") {
            StylePicker(selection: rules.defaultStyle, label: "Style for everything else") { style in
                if let style { model.settings.update { $0.styleRules.defaultStyle = style } }
            }
        }))
        var apps: [Row] = destinations.map { destination in
            Row(id: "dest-\(destination.id)", searchText: "\(destination.name) \(destination.id) app site style rule",
                view: DestinationRow(destination: destination))
        }
        if apps.isEmpty {
            apps.append(Row(id: "dest-empty", searchText: "apps sites",
                            view: SettingsRow("No apps yet", detail: "Apps you dictate into appear here, with the style each one gets.")))
        }
        return [
            Section("Defaults", rows: defaults),
            Section("Apps and sites", trailing: AnyView(
                Button {
                    model.appStylesAddPresented = true
                } label: {
                    Label("Add App or Site", systemImage: "plus")
                }
                .cardButton()
            ), rows: apps),
        ]
    }
}

// MARK: - Destinations

/// An app or a website in the list: one with the user's own rule, or one seen in history.
struct StyleDestination: Identifiable, Equatable {
    enum Kind: Equatable { case app(bundleID: String), site(host: String) }
    var kind: Kind
    var name: String
    var style: DictationStyle.ID
    /// Why it gets that style: "Your rule", "Chat apps", "Everything else".
    var reason: String
    var hasRule: Bool
    /// A terminal or a password manager: always Verbatim, whatever the rules say.
    var forced = false

    var id: String {
        switch kind {
        case .app(let bundleID): bundleID
        case .site(let host): host
        }
    }

    var destination: DictationDestination {
        switch kind {
        case .app(let bundleID): DictationDestination(bundleID: bundleID, appName: name)
        case .site(let host): DictationDestination(url: "https://\(host)/")
        }
    }
}

enum StyleDestinations {
    /// The user's rules first (apps, then sites), then what history went to most, at most 12 more.
    @MainActor
    static func list(_ model: AppModel) -> [StyleDestination] {
        let rules = model.settings.settings.styleRules
        var out: [StyleDestination] = []
        var seen = Set<String>()
        for rule in rules.apps.reversed() where seen.insert(rule.bundleID).inserted {
            out.append(StyleDestination(kind: .app(bundleID: rule.bundleID), name: rule.appName ?? appName(rule.bundleID) ?? rule.bundleID,
                                        style: rule.style, reason: "Your rule", hasRule: true))
        }
        for rule in rules.sites.reversed() where rule.pathPrefix == nil && seen.insert(rule.host).inserted {
            out.append(StyleDestination(kind: .site(host: rule.host), name: rule.host, style: rule.style, reason: "Your rule", hasRule: true))
        }
        // History: by how often each went there.
        var counts: [String: (count: Int, kind: StyleDestination.Kind, name: String)] = [:]
        for item in model.history.items where !item.isBarkNote {
            if let host = item.destinationHost, !host.isEmpty {
                counts[host, default: (0, .site(host: host), host)].count += 1
            } else if let bundleID = item.appBundleId, !bundleID.isEmpty, bundleID != AppInfo.bundleID {
                counts[bundleID, default: (0, .app(bundleID: bundleID), item.appName ?? bundleID)].count += 1
            }
        }
        let seenInHistory = counts.sorted { $0.value.count > $1.value.count || ($0.value.count == $1.value.count && $0.key < $1.key) }
        var added = 0
        for (key, entry) in seenInHistory where added < 12 && seen.insert(key).inserted {
            var d = StyleDestination(kind: entry.kind, name: entry.name, style: .clean, reason: "", hasRule: false)
            let resolution = rules.resolve(d.destination)
            d.style = resolution.style
            d.reason = reason(resolution, rules: rules, for: d.destination)
            d.forced = resolution.source == .forced
            out.append(d)
            added += 1
        }
        return out
    }

    /// Why a destination without a rule gets its style, in the settings' words: "Chat default",
    /// "Everything else", "Terminal".
    static func reason(_ r: StyleResolution, rules: StyleRules, for d: DictationDestination) -> String {
        switch r.source {
        case .builtInApp, .builtInSite:
            let builtIn = d.host.flatMap { StyleRules.builtInSiteStyle(host: $0, path: d.path ?? "/") }
                ?? StyleRules.builtInAppStyle(bundleID: d.bundleID)
            return builtIn.flatMap(StyleCategory.of(builtIn:)).map { "\($0.name) default" } ?? "Bark's default"
        case .global: return "Everything else"
        default: return r.reason
        }
    }

    static func appName(_ bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

// MARK: - Rows

/// One kind of app and its style.
private struct CategoryRow: View {
    var category: StyleCategory
    @Environment(AppModel.self) private var model

    var body: some View {
        let rules = model.settings.settings.styleRules
        let style = rules.style(for: category)
        SettingsRow(category.name, detail: category.examples) {
            if style != category.builtInStyle { Badge("Changed") }
        } control: {
            StylePicker(selection: style, label: "Style for \(category.name) apps",
                        reset: style == category.builtInStyle ? nil : ("Use \(category.builtInStyle.displayName), Bark's Default", category.builtInStyle)) { s in
                if let s { model.settings.update { $0.styleRules.setCategory(category, style: s) } }
            }
        }
    }
}

/// An app or site: its icon and name, why it gets its style, the picker, and the preview when
/// open.
private struct DestinationRow: View {
    var destination: StyleDestination
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    var body: some View {
        let open = model.appStylesOpenRow == destination.id
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    withAnimation(Motion.unlessReduced(Motion.normal, reduceMotion)) {
                        model.appStylesOpenRow = open ? nil : destination.id
                    }
                } label: {
                    HStack(spacing: 12) {
                        DestinationIcon(destination: destination)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(destination.name).font(.system(size: 14, weight: .medium)).foregroundStyle(Crystal.ink).lineLimit(1)
                            Text("\(destination.reason) · \(destination.style.summary)")
                                .font(.system(size: 12)).foregroundStyle(Crystal.ink2).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(hovered || open ? Crystal.ink2 : Crystal.ink3)
                            .rotationEffect(.degrees(open ? 90 : 0))
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(destination.name), \(destination.style.displayName). \(destination.reason)")
                .accessibilityHint(open ? "Hides the preview" : "Shows a preview")
                if destination.forced {
                    Text("Always Verbatim")
                        .font(.system(size: 13)).foregroundStyle(Crystal.ink3)
                        .frame(minWidth: 132, alignment: .trailing)
                        .help("Bark never reshapes what goes into a terminal or a password field.")
                } else {
                    StylePicker(selection: destination.style, label: "Style for \(destination.name)",
                                reset: destination.hasRule ? ("Remove Your Rule", nil) : nil) { style in
                        setRule(style)
                    }
                }
            }
            .padding(.horizontal, SettingsMetrics.rowH)
            .padding(.vertical, 11)
            if open {
                StylePreview(style: destination.style, destinationName: destination.name)
                    .padding(.leading, SettingsMetrics.rowH + 32)
                    .padding(.trailing, SettingsMetrics.rowH)
                    .padding(.bottom, 16)
                    .transition(.opacity)
            }
        }
        .background(open ? Crystal.rowHover.opacity(0.5) : hovered ? Crystal.rowHover : .clear)
        .onHover { hovered = $0 }
        .contextMenu {
            if destination.hasRule { Button("Remove Your Rule") { setRule(nil) } }
        }
    }

    private func setRule(_ style: DictationStyle.ID?) {
        model.settings.update { s in
            switch destination.kind {
            case .app(let bundleID):
                if let style { s.styleRules.setApp(bundleID, appName: destination.name, style: style) } else { s.styleRules.removeApp(bundleID) }
            case .site(let host):
                if let style { s.styleRules.setSite(host, style: style) } else { s.styleRules.removeSite(host) }
            }
        }
    }
}

/// The app's own icon (from NSWorkspace), or a monogram; a globe tile for a website.
struct DestinationIcon: View {
    var destination: StyleDestination
    var size: CGFloat = 20

    var body: some View {
        Group {
            switch destination.kind {
            case .app(let bundleID):
                if let icon = AppIcons.icon(for: bundleID) {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: size, height: size)
                } else {
                    AppMonogram(appName: destination.name, bundleID: bundleID, size: size)
                }
            case .site(let host):
                AppMonogram(appName: DictationText.siteName(host), bundleID: host, size: size)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// App icons by bundle id, looked up once.
@MainActor
enum AppIcons {
    private static var cache: [String: NSImage?] = [:]
    static func icon(for bundleID: String) -> NSImage? {
        if let cached = cache[bundleID] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[bundleID] = icon
        return icon
    }
}

/// A select listing every style with its line; `reset` adds a last item (nil: remove the rule).
struct StylePicker: View {
    var selection: DictationStyle.ID
    var label: String
    var reset: (title: String, style: DictationStyle.ID?)? = nil
    var onPick: (DictationStyle.ID?) -> Void

    init(selection: DictationStyle.ID, label: String, reset: (String, DictationStyle.ID?)? = nil,
         onPick: @escaping (DictationStyle.ID?) -> Void) {
        self.selection = selection
        self.label = label
        self.reset = reset.map { (title: $0.0, style: $0.1) }
        self.onPick = onPick
    }

    var body: some View {
        SelectMenu(selection.displayName, label: label) {
            Picker(label, selection: Binding(get: { selection }, set: { onPick($0) })) {
                ForEach(DictationStyle.all) { style in
                    Text(style.name).tag(style.id)
                }
            }
            .pickerStyle(.inline)
            if let reset {
                Divider()
                Button(reset.title) { onPick(reset.style) }
            }
        }
        .help(selection.summary)
    }
}

// MARK: - Preview

/// A sample dictation in a style: what was said, with what cleanup took out dimmed, and what Bark
/// would paste, both from the real formatter; then what the style does.
struct StylePreview: View {
    var style: DictationStyle.ID
    var destinationName: String
    @Environment(AppModel.self) private var model

    var body: some View {
        let raw = StyleSamples.sample(for: style)
        let s = model.settings.settings
        let result = DictationPipeline.process(raw, context: PostProcessContext(
            settings: s, appBundleID: nil, resolution: StyleResolution(style: style, reason: "Preview", source: .dictation)))
        let diff = WordDiff(from: raw, to: result.text)
        HStack(alignment: .top, spacing: 12) {
            column("What you said", symbol: "mic") {
                Text(StyleSamples.dimmed(diff))
                    .font(.system(size: 13))
                    .lineSpacing(4)
                    .foregroundStyle(Crystal.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Crystal.message, in: .rect(cornerRadius: Radius.card, style: .continuous))
            }
            column("What Bark pastes in \(destinationName)", symbol: "arrow.turn.down.left") {
                Text(result.plainText)
                    .font(style == .code ? .mono(12.5) : .system(size: 13))
                    .lineSpacing(4)
                    .foregroundStyle(Crystal.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Crystal.canvas, in: .rect(cornerRadius: Radius.card, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Crystal.hairline))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        FlowChips(items: StyleSamples.traits(style, cleanup: s.cleanupSettings, rich: result.html != nil))
            .padding(.top, 12)
    }

    private func column(_ title: String, symbol: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .labelStyle(CaptionLabelStyle())
                .font(.system(size: 12))
                .foregroundStyle(Crystal.ink3)
                .lineLimit(1)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct CaptionLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 10, weight: .semibold))
            configuration.title
        }
    }
}

/// Outline chips with a check: what a style does.
struct FlowChips: View {
    var items: [String]
    var body: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(items, id: \.self) { item in
                HStack(spacing: 5) {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Crystal.ink)
                    Text(item).font(.system(size: 12)).foregroundStyle(Crystal.ink2)
                }
                .padding(.horizontal, 8)
                .frame(height: 24)
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Crystal.hairline))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Sample dictations that show each style at work, and the words for what a style does.
enum StyleSamples {
    static func sample(for style: DictationStyle.ID) -> String {
        switch style {
        case .email:
            "Hi Aoife, um, so could you send the revised quote by Thursday, no wait, Friday, and copy in Declan? He's handling the kitchen side now. Thanks, Sam."
        case .casual:
            "Um, on the train now, home by half six."
        case .notes:
            "Kitchen quote. Bullet point worktop. Bullet point two wall units. Bullet point, uh, fitters the first week of March."
        case .document:
            "Q4 review. Retention is up, you know, four points, I mean three points, on last quarter. New paragraph. Churn is flat."
        case .code:
            "Rename fetchQuote to, uh, loadQuote everywhere."
        case .clean, .verbatim:
            "Um, can we move the practice meeting to Thursday, no wait, Friday? The new nurse starts that morning."
        }
    }

    /// The sample with what cleanup took out in the secondary grey.
    static func dimmed(_ diff: WordDiff) -> AttributedString {
        var out = AttributedString()
        for (i, word) in diff.originalWords.enumerated() {
            if i > 0 { out += AttributedString(" ") }
            var a = AttributedString(word)
            if i < diff.removedInOriginal.count, diff.removedInOriginal[i] { a.foregroundColor = Crystal.ink3 }
            out += a
        }
        return out
    }

    static func traits(_ style: DictationStyle.ID, cleanup: CleanupSettings, rich: Bool) -> [String] {
        var out: [String] = []
        if style != .verbatim {
            if cleanup.removeFillers { out.append("Fillers out") }
            if cleanup.fixSelfCorrections { out.append("Self-corrections fixed") }
        }
        switch style {
        case .verbatim: out += ["Exactly as heard", "Your dictionary only"]
        case .casual: out += ["Your own casing", "No full stop on a short message"]
        case .clean: out += ["Sentence case", "Tidy punctuation"]
        case .email: out += ["Greeting on its own line", "Paragraphs", "Sign-off on its own lines"]
        case .document: out += ["Spoken headings", "Paragraphs", "Lists"]
        case .notes: out += ["Bullet points", "Numbered lists", "Headings"]
        case .code: out += ["Identifiers kept", "No punctuation polishing"]
        }
        if rich { out.append("Pasted as rich text too") }
        return out
    }
}

// MARK: - Add an app or site

/// Picks an app (running, or from Applications) or types a website, and a style for it.
struct AddStyleRuleSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var kind = 0
    @State private var bundleID: String?
    @State private var appName = ""
    @State private var host = ""
    @State private var style: DictationStyle.ID = .clean
    @State private var apps: [(id: String, name: String)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add an app or site").font(.system(size: 17, weight: .semibold)).foregroundStyle(Crystal.ink)
            Text("Give it its own style. Its rule beats the defaults.")
                .font(.system(size: 13)).foregroundStyle(Crystal.ink2).padding(.top, 4)
            SegmentedChoice("App or website", selection: $kind, options: [.init(0, "App", symbol: "macwindow"), .init(1, "Website", symbol: "globe")])
                .padding(.top, 16)
            SettingsGroup {
                if kind == 0 {
                    SettingsRow("App", detail: bundleID ?? "An app that's open now, or one from Applications.") {
                        SelectMenu(appName.isEmpty ? "Choose…" : appName, label: "App", minWidth: 180) {
                            ForEach(apps, id: \.id) { app in
                                Button(app.name) { bundleID = app.id; appName = app.name; style = suggested }
                            }
                            Divider()
                            Button("Other App…") { chooseApp() }
                        }
                    }
                } else {
                    SettingsRow("Website", detail: hostError ?? "Its address: mail.example.com or example.com.") {
                        SettingsTextField("Website", text: $host, prompt: "example.com").frame(width: 200)
                    }
                }
                SettingsRow("Style", detail: style.summary) {
                    StylePicker(selection: style, label: "Style") { if let s = $0 { style = s } }
                }
            }
            .padding(.top, 14)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.cardButton().keyboardShortcut(.cancelAction)
                Button("Add", action: add).buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction).disabled(!canAdd)
            }
            .padding(.top, 18)
        }
        .padding(22)
        .frame(width: 520)
        .background(Crystal.card)
        .onAppear(perform: loadApps)
    }

    private var cleanHost: String? {
        let text = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }
        return DictationDestination.sanitize(text.contains("://") ? text : "https://" + text)?.host
    }

    private var hostError: String? {
        host.trimmingCharacters(in: .whitespaces).isEmpty || cleanHost != nil ? nil : "That doesn't look like a website's address."
    }

    private var canAdd: Bool { kind == 0 ? bundleID != nil : cleanHost != nil }

    /// What the app gets today, as a starting point.
    private var suggested: DictationStyle.ID {
        guard let bundleID else { return style }
        return model.settings.settings.styleRules.resolve(DictationDestination(bundleID: bundleID, appName: appName)).style
    }

    private func loadApps() {
        let own = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> (id: String, name: String)? in
                guard let id = app.bundleIdentifier, id != own, seen.insert(id).inserted else { return nil }
                return (id, app.localizedName ?? id)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
        bundleID = id
        appName = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        style = suggested
    }

    private func add() {
        model.settings.update { s in
            if kind == 0, let bundleID {
                s.styleRules.setApp(bundleID, appName: appName, style: style)
            } else if let cleanHost {
                s.styleRules.setSite(cleanHost, style: style)
            }
        }
        model.appStylesOpenRow = kind == 0 ? bundleID : cleanHost
        dismiss()
    }
}
