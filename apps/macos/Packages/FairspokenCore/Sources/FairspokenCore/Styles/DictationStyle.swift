import Foundation

/// How a dictation is shaped for where it is going. Every style is deterministic and only
/// reshapes words that were spoken: none invents a greeting, a sign-off or a name.
public struct DictationStyle: Identifiable, Equatable, Sendable {
    public enum ID: String, Codable, Sendable, CaseIterable {
        /// What was heard, with the user's vocabulary casing and corrections only.
        case verbatim
        /// Light cleanup for chat: no full stop on a short single message, the speaker's casing.
        case casual
        /// Full cleanup in sentence case: the default.
        case clean
        /// Clean, with a spoken greeting and sign-off on their own lines and paragraphs.
        case email
        /// Clean, with spoken headings, lists and paragraphs.
        case document
        /// Like document, list-friendly, for notes apps.
        case notes
        /// Fillers and corrections only: no punctuation polishing, identifiers kept.
        case code
    }

    public var id: ID
    public var name: String
    public var summary: String

    public static let all: [DictationStyle] = ID.allCases.map(DictationStyle.init(id:))

    public init(id: ID) {
        self.id = id
        name = id.displayName
        summary = id.summary
    }
}

public extension DictationStyle.ID {
    var displayName: String {
        switch self {
        case .verbatim: "Verbatim"
        case .casual: "Casual"
        case .clean: "Clean"
        case .email: "Email"
        case .document: "Document"
        case .notes: "Notes"
        case .code: "Code"
        }
    }

    var summary: String {
        switch self {
        case .verbatim: "Exactly what you said, with your vocabulary and corrections."
        case .casual: "Light tidy for chat. Keeps your casing, no full stop on a short message."
        case .clean: "Fillers, repeats and self-corrections removed, in sentence case."
        case .email: "Clean, with your greeting and sign-off on their own lines."
        case .document: "Clean, with spoken headings, lists and paragraphs."
        case .notes: "Clean, with spoken bullet points, numbered lists and headings."
        case .code: "Fillers and corrections removed. Punctuation and identifiers left alone."
        }
    }

    /// The cleanup stages the style runs, before the user's switches.
    var cleanupOptions: CleanupOptions {
        switch self {
        case .verbatim:
            return .none
        case .casual:
            var o = CleanupOptions.full
            o.sentenceCase = false
            o.dropFinalFullStopWhenShort = true
            return o
        case .clean, .email, .document, .notes:
            return .full
        case .code:
            var o = CleanupOptions.full
            o.punctuationTidy = false
            o.sentenceCase = false
            return o
        }
    }

    /// Styles whose layout is pasted as rich text too.
    var producesHTML: Bool { self == .email || self == .document || self == .notes }
}

/// Where a dictation is going, read when the recording starts (`DestinationReader` in the app).
/// The URL keeps only scheme, host and path: never a query or fragment.
public struct DictationDestination: Equatable, Sendable {
    public var bundleID: String?
    public var appName: String?
    public var windowTitle: String?
    /// "https://mail.google.com/mail/u/0/" style: scheme, host and path only.
    public var url: String?
    public var host: String?
    public var path: String?
    /// The focused field takes one line only (a search box, a subject line, a chat input).
    public var isSingleLineField: Bool
    /// A password field, or secure input is on.
    public var isSecureField: Bool

    public init(bundleID: String? = nil, appName: String? = nil, windowTitle: String? = nil, url: String? = nil,
                isSingleLineField: Bool = false, isSecureField: Bool = false) {
        self.bundleID = bundleID
        self.appName = appName
        self.windowTitle = windowTitle
        self.isSingleLineField = isSingleLineField
        self.isSecureField = isSecureField
        if let url, let clean = Self.sanitize(url) {
            self.url = clean.url
            host = clean.host
            path = clean.path
        }
    }

    public var isTerminal: Bool { AppCategory.of(bundleID: bundleID) == .terminal }

    /// A reply ("Re: Thursday's clinic"), from the window title.
    public var isReply: Bool {
        guard let title = windowTitle?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        return title.hasPrefix("re:") || title.contains(" re: ") || title.hasPrefix("aw:") || title.hasPrefix("sv:")
    }

    /// Only http(s) URLs, cut to scheme, host (lowercased, without "www.") and path. User,
    /// password, port, query and fragment are dropped.
    public static func sanitize(_ raw: String) -> (url: String, host: String, path: String)? {
        guard let components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              var host = components.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        return ("\(scheme)://\(host)\(path)", host, path)
    }
}

/// The user's per-app rule.
public struct AppStyleRule: Codable, Equatable, Sendable, Identifiable {
    public var bundleID: String
    public var appName: String?
    public var style: DictationStyle.ID
    public var id: String { bundleID }

    public init(bundleID: String, appName: String? = nil, style: DictationStyle.ID) {
        self.bundleID = bundleID
        self.appName = appName
        self.style = style
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = c.lenient(String.self, .bundleID) ?? ""
        appName = c.lenient(String.self, .appName)
        style = c.lenient(DictationStyle.ID.self, .style) ?? .clean
    }
}

/// The user's per-site rule: a host, and optionally a path prefix ("docs.google.com",
/// "/spreadsheets" for one part of a site).
public struct SiteStyleRule: Codable, Equatable, Sendable, Identifiable {
    public var host: String
    public var pathPrefix: String?
    public var style: DictationStyle.ID
    public var id: String { host + (pathPrefix ?? "") }

    public init(host: String, pathPrefix: String? = nil, style: DictationStyle.ID) {
        self.host = host
        self.pathPrefix = pathPrefix
        self.style = style
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = c.lenient(String.self, .host) ?? ""
        pathPrefix = c.lenient(String.self, .pathPrefix)
        style = c.lenient(DictationStyle.ID.self, .style) ?? .clean
    }

    func matches(host other: String, path: String) -> Bool {
        guard other == host || other.hasSuffix("." + host) else { return false }
        guard let prefix = pathPrefix, !prefix.isEmpty, prefix != "/" else { return true }
        return path.hasPrefix(prefix)
    }
}

/// The style chosen for one dictation, and why.
public struct StyleResolution: Equatable, Sendable {
    public enum Source: String, Equatable, Sendable {
        /// Chosen for this dictation (the pill's menu).
        case dictation
        /// The user's rule for the app.
        case app
        /// The user's rule for the website.
        case site
        /// Bark's own default for a website.
        case builtInSite
        /// Bark's own default for the app.
        case builtInApp
        /// The user's default style.
        case global
        /// A terminal or a secure field: always verbatim and plain.
        case forced
    }

    public var style: DictationStyle.ID
    /// Short human text: "Mail rule", "You chose this", "mail.google.com".
    public var reason: String
    public var source: Source
    /// Line breaks and multi-line layouts are allowed (not a single-line field or a terminal).
    public var allowsMultiline: Bool
    /// Rich text may be pasted alongside plain.
    public var allowsRichText: Bool

    public init(style: DictationStyle.ID, reason: String, source: Source, allowsMultiline: Bool = true, allowsRichText: Bool = true) {
        self.style = style
        self.reason = reason
        self.source = source
        self.allowsMultiline = allowsMultiline
        self.allowsRichText = allowsRichText
    }
}

/// Which style each destination gets: the user's per-app rule, then the user's per-site rule,
/// then Bark's defaults (by site, then by app), then the user's default style (`clean`).
public struct StyleRules: Codable, Equatable, Sendable {
    public var defaultStyle: DictationStyle.ID = .clean
    public var apps: [AppStyleRule] = []
    public var sites: [SiteStyleRule] = []

    public static let maxRules = 200

    public init(defaultStyle: DictationStyle.ID = .clean, apps: [AppStyleRule] = [], sites: [SiteStyleRule] = []) {
        self.defaultStyle = defaultStyle
        self.apps = apps
        self.sites = sites
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaultStyle = c.lenient(DictationStyle.ID.self, .defaultStyle) ?? .clean
        apps = c.lenient([LenientElement<AppStyleRule>].self, .apps)?.compactMap(\.value) ?? []
        sites = c.lenient([LenientElement<SiteStyleRule>].self, .sites)?.compactMap(\.value) ?? []
    }

    /// Trimmed, blank and duplicate rules dropped (the later one wins), hosts lowercased.
    public func normalized() -> StyleRules {
        var out = self
        var seenApps = Set<String>()
        out.apps = apps.reversed().compactMap { rule -> AppStyleRule? in
            var r = rule
            r.bundleID = rule.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !r.bundleID.isEmpty, seenApps.insert(r.bundleID).inserted else { return nil }
            return r
        }.reversed()
        var seenSites = Set<String>()
        out.sites = sites.reversed().compactMap { rule -> SiteStyleRule? in
            var r = rule
            var host = rule.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let parsed = DictationDestination.sanitize(host.contains("://") ? host : "https://" + host) { host = parsed.host }
            r.host = host
            let prefix = rule.pathPrefix?.trimmingCharacters(in: .whitespacesAndNewlines)
            r.pathPrefix = (prefix?.isEmpty ?? true) || prefix == "/" ? nil : (prefix!.hasPrefix("/") ? prefix : "/" + prefix!)
            guard !r.host.isEmpty, seenSites.insert(r.id).inserted else { return nil }
            return r
        }.reversed()
        if out.apps.count > Self.maxRules { out.apps = Array(out.apps.suffix(Self.maxRules)) }
        if out.sites.count > Self.maxRules { out.sites = Array(out.sites.suffix(Self.maxRules)) }
        return out
    }

    // MARK: Editing

    public mutating func setApp(_ bundleID: String, appName: String? = nil, style: DictationStyle.ID) {
        apps.removeAll { $0.bundleID == bundleID }
        apps.append(AppStyleRule(bundleID: bundleID, appName: appName, style: style))
        self = normalized()
    }

    public mutating func removeApp(_ bundleID: String) { apps.removeAll { $0.bundleID == bundleID } }

    public mutating func setSite(_ host: String, pathPrefix: String? = nil, style: DictationStyle.ID) {
        let rule = SiteStyleRule(host: host, pathPrefix: pathPrefix, style: style)
        guard let clean = StyleRules(sites: [rule]).normalized().sites.first else { return }
        sites.removeAll { $0.id == clean.id }
        sites.append(clean)
        self = normalized()
    }

    public mutating func removeSite(_ host: String, pathPrefix: String? = nil) {
        let id = host.lowercased() + (pathPrefix ?? "")
        sites.removeAll { $0.id == id }
    }

    /// "Always use this for <app or site>": a site rule when the dictation went to a website,
    /// otherwise an app rule. False when there is nothing to attach a rule to.
    @discardableResult
    public mutating func alwaysUse(_ style: DictationStyle.ID, for destination: DictationDestination) -> Bool {
        if let host = destination.host {
            setSite(host, style: style)
            return true
        }
        guard let bundleID = destination.bundleID, !bundleID.isEmpty else { return false }
        setApp(bundleID, appName: destination.appName, style: style)
        return true
    }

    // MARK: Resolving

    public func resolve(_ d: DictationDestination, override: DictationStyle.ID? = nil) -> StyleResolution {
        let multiline = !d.isSingleLineField && !d.isTerminal
        func make(_ style: DictationStyle.ID, _ reason: String, _ source: StyleResolution.Source) -> StyleResolution {
            StyleResolution(style: style, reason: reason, source: source, allowsMultiline: multiline,
                            allowsRichText: multiline && !d.isTerminal && !d.isSecureField)
        }
        // A password field is never reshaped, whatever was chosen.
        if d.isSecureField || d.bundleID.map(Self.isPasswordManager) == true {
            return StyleResolution(style: .verbatim, reason: "Secure field", source: .forced, allowsMultiline: false, allowsRichText: false)
        }
        if let override { return make(override, "You chose this", .dictation) }
        // A terminal runs what it is given: no commands, no cleanup, nothing rich.
        if d.isTerminal {
            return StyleResolution(style: .verbatim, reason: "Terminal", source: .forced, allowsMultiline: false, allowsRichText: false)
        }
        let appName = d.appName ?? "this app"
        if let bundleID = d.bundleID, let rule = apps.last(where: { $0.bundleID == bundleID }) {
            return make(rule.style, "Your rule for \(rule.appName ?? appName)", .app)
        }
        if let host = d.host {
            let path = d.path ?? "/"
            let matching = sites.filter { $0.matches(host: host, path: path) }
            if let best = matching.max(by: { ($0.pathPrefix?.count ?? 0, $0.host.count) < ($1.pathPrefix?.count ?? 0, $1.host.count) }) {
                return make(best.style, "Your rule for \(best.host)", .site)
            }
            if let builtIn = Self.builtInSiteStyle(host: host, path: path) {
                return make(builtIn, host, .builtInSite)
            }
        }
        if let builtIn = Self.builtInAppStyle(bundleID: d.bundleID) {
            return make(builtIn, "\(d.appName ?? "App") rule", .builtInApp)
        }
        return make(defaultStyle, defaultStyle == .clean ? "Default" : "Your default", .global)
    }

    // MARK: Built-in defaults

    /// Bundle-id prefixes and the style Bark gives them unless the user says otherwise.
    public static let builtInApps: [(prefix: String, style: DictationStyle.ID)] = [
        ("com.apple.mail", .email), ("com.microsoft.Outlook", .email), ("com.readdle.SparkDesktop", .email),
        ("com.readdle.smartemail", .email), ("com.mimestream.Mimestream", .email), ("com.superhuman.electron", .email),
        ("com.apple.Notes", .notes), ("md.obsidian", .notes), ("net.shinyfrog.bear", .notes), ("net.shinyfrog.panda", .notes),
        ("com.apple.iWork.Pages", .document), ("com.microsoft.Word", .document), ("notion.id", .document),
        ("com.tinyspeck.slackmacgap", .casual), ("com.apple.MobileSMS", .casual), ("net.whatsapp.WhatsApp", .casual),
        ("desktop.WhatsApp", .casual), ("com.hnc.Discord", .casual), ("com.microsoft.teams", .casual),
        ("org.telegram.desktop", .casual), ("ru.keepcoder.Telegram", .casual), ("org.whispersystems.signal-desktop", .casual),
        ("com.apple.dt.Xcode", .code), ("com.microsoft.VSCode", .code), ("com.todesktop.230313mzl4w4u92", .code),
        ("com.jetbrains.", .code), ("dev.zed.Zed", .code), ("com.sublimetext.", .code), ("com.panic.Nova", .code),
    ]

    public static let builtInSites: [(host: String, style: DictationStyle.ID)] = [
        ("mail.google.com", .email), ("outlook.live.com", .email), ("outlook.office.com", .email),
        ("outlook.office365.com", .email), ("mail.proton.me", .email), ("mail.yahoo.com", .email), ("icloud.com/mail", .email),
        ("docs.google.com", .document), ("notion.so", .document), ("notion.site", .document),
        ("app.slack.com", .casual), ("web.whatsapp.com", .casual), ("discord.com", .casual),
        ("teams.microsoft.com", .casual), ("teams.live.com", .casual), ("messages.google.com", .casual),
        ("github.com", .code), ("gist.github.com", .code), ("gitlab.com", .code),
    ]

    public static func builtInAppStyle(bundleID: String?) -> DictationStyle.ID? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        if AppCategory.of(bundleID: bundleID) == .terminal { return .code }
        return builtInApps.first { bundleID.hasPrefix($0.prefix) }?.style
    }

    public static func builtInSiteStyle(host: String, path: String = "/") -> DictationStyle.ID? {
        builtInSites.first { entry in
            let parts = entry.host.split(separator: "/", maxSplits: 1)
            let h = String(parts[0])
            guard host == h || host.hasSuffix("." + h) else { return false }
            return parts.count == 1 || path.hasPrefix("/" + parts[1])
        }?.style
    }

    static func isPasswordManager(_ bundleID: String) -> Bool {
        ["com.1password.", "com.agilebits.", "com.bitwarden.", "com.lastpass.", "org.keepassxc.", "com.apple.Passwords"]
            .contains { bundleID.hasPrefix($0) }
    }
}

/// Decodes an array element, or nil when it is malformed, so one bad rule doesn't drop the rest.
struct LenientElement<T: Decodable>: Decodable {
    var value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}
