import Foundation

/// What the recording pill says, worked out apart from drawing it: how a failure reads and in
/// which tone, what a clipboard fallback adds, and the style chip with its menu.
public enum PillPresentation {
    /// A failed dictation, as the pill shows it.
    public struct Failure: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            /// Silence: nothing went wrong, nothing was heard.
            case nothingHeard
            /// Released before there was anything to transcribe.
            case tooShort
            /// The microphone couldn't be started (busy, unplugged) or access is off.
            case microphone
            /// Not transcribed, but the recording is kept and will be tried again.
            case savedToRetry
            case other
        }

        public var kind: Kind
        /// Bold: "Nothing heard", "Couldn't transcribe".
        public var title: String
        /// Muted, after the title: "saved to retry".
        public var detail: String?
        /// Drawn in the error tone (red ring and text); the rest are neutral.
        public var isError: Bool
        /// Offers Retry (start a new recording): the microphone failed to start.
        public var canRetry: Bool
    }

    /// Reads the controller's failure message. Messages are plain sentences, some with a
    /// detail after a dash ("Couldn't transcribe — saved to retry").
    public static func failure(_ message: String) -> Failure {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let (head, tail) = split(trimmed)
        if lower.hasPrefix("no speech") {
            return Failure(kind: .nothingHeard, title: "Nothing heard", detail: nil, isError: false, canRetry: false)
        }
        if lower.hasPrefix("too short") {
            return Failure(kind: .tooShort, title: "Too short", detail: tail ?? "hold the shortcut while you speak",
                           isError: false, canRetry: false)
        }
        if lower.hasSuffix("saved to retry") {
            let title = head.lowercased().hasPrefix("cancelled") ? "Cancelled" : head
            return Failure(kind: .savedToRetry, title: title, detail: "saved to retry", isError: false, canRetry: false)
        }
        if lower.contains("microphone") {
            // "Couldn't start the microphone: <system error>": the system's words are too long
            // for the pill; VoiceOver reads the whole message.
            let short = trimmed.split(separator: ":", maxSplits: 1).first.map(String.init) ?? trimmed
            let starting = lower.hasPrefix("couldn't start")
            return Failure(kind: .microphone, title: starting ? "Microphone unavailable" : short,
                           detail: starting ? "another app may have it" : nil, isError: true, canRetry: starting)
        }
        let clipped = trimmed.count > 60 ? String(trimmed.prefix(58)).trimmingCharacters(in: .whitespaces) + "…" : trimmed
        return Failure(kind: .other, title: clipped, detail: nil, isError: true, canRetry: false)
    }

    /// The muted words after "Copied to the clipboard" for a fallback reason, or nil when the
    /// reason says no more than that. The pill shows ⌘V itself, so "press ⌘V to paste" goes.
    public static func copiedDetail(_ reason: String) -> String? {
        var rest = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["Copied to clipboard", "Copied to the clipboard", "Copied"] where rest.hasPrefix(prefix) {
            rest = String(rest.dropFirst(prefix.count))
            break
        }
        rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: " —–-:.").union(.whitespaces))
        for pasteHint in ["Press ⌘V to paste", "press ⌘V to paste"] {
            rest = rest.replacingOccurrences(of: pasteHint, with: "")
        }
        rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: " —–-:.").union(.whitespaces))
        return rest.isEmpty ? nil : rest
    }

    /// The first label of a host name, for "via build-box": `build-box.tail1234.ts.net:48173`
    /// → `build-box`. An IP address is kept whole.
    public static func shortHostName(_ host: String) -> String {
        let bare = host.split(separator: ":").first.map(String.init) ?? host
        if bare.split(separator: ".").allSatisfy({ Int($0) != nil }) { return bare }
        return bare.split(separator: ".").first.map(String.init) ?? bare
    }

    private static func split(_ message: String) -> (String, String?) {
        for dash in [" — ", " – ", " - "] {
            if let range = message.range(of: dash) {
                let tail = String(message[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                return (String(message[..<range.lowerBound]), tail.isEmpty ? nil : tail)
            }
        }
        return (message, nil)
    }
}

/// The style chip on the listening pill ("Email · Mail rule") and its menu: every style with the
/// current one ticked, a way back to the rules after a choice, and "Always use … for …".
/// Terminals and secure fields are locked to Verbatim: the chip says so and has no menu.
public struct StyleChipState: Equatable, Sendable {
    public enum Entry: Equatable, Sendable, Identifiable {
        case style(DictationStyle.ID, checked: Bool)
        /// Back to what the rules give ("Back to Email (Mail rule)").
        case useRules(title: String)
        /// "Always use Email for Mail".
        case alwaysUse(title: String, style: DictationStyle.ID)

        public var id: String {
            switch self {
            case .style(let style, _): "style-\(style.rawValue)"
            case .useRules: "rules"
            case .alwaysUse: "always"
            }
        }
    }

    public var style: DictationStyle.ID
    /// "Mail rule", "Your Slack rule", "Your pick", "Terminal".
    public var reason: String
    public var isLocked: Bool
    public var entries: [Entry]

    /// The chip's text: "Email · Mail rule".
    public var label: String { "\(style.displayName) · \(reason)" }

    /// For VoiceOver: "Style, Email, Mail rule".
    public var accessibilityLabel: String {
        isLocked ? "Style, \(style.displayName), always for a \(reason.lowercased())" : "Style, \(style.displayName), \(reason)"
    }

    /// `resolution` is the style the recording will get now; `rulesResolution` what the rules
    /// alone would give (nil when it can't be known, e.g. a note in Bark); `target` where
    /// "Always use" would write a rule (nil for none). Nil when there is no style to show.
    public init?(resolution: StyleResolution?, rulesResolution: StyleResolution? = nil, target: StyleRules.RuleTarget?) {
        guard let resolution else { return nil }
        style = resolution.style
        reason = Self.shortReason(resolution.reason)
        isLocked = resolution.source == .forced
        guard !isLocked else {
            entries = []
            return
        }
        var entries: [Entry] = DictationStyle.ID.allCases.map { .style($0, checked: $0 == resolution.style) }
        if resolution.source == .dictation, let rules = rulesResolution, rules.source != .dictation {
            entries.append(.useRules(title: "Back to \(rules.style.displayName) (\(Self.shortReason(rules.reason)))"))
        }
        if let target {
            entries.append(.alwaysUse(title: "Always use \(resolution.style.displayName) for \(target.label)", style: resolution.style))
        }
        self.entries = entries
    }

    /// Short enough for the chip: "Your rule for Slack" → "Your Slack rule"; with a long name
    /// ("Your rule for Microsoft Outlook") just "Your rule", the app being in front of the person.
    /// A style picked for this one dictation reads "Your pick": "You chose this" cut the chip's
    /// reason short ("Casual · You chose t…").
    public static func shortReason(_ reason: String) -> String {
        let r = reason.trimmingCharacters(in: .whitespaces)
        if r == "You chose this" { return "Your pick" }
        if r.hasPrefix("Your rule for ") {
            let name = String(r.dropFirst("Your rule for ".count))
            return name.count <= 12 ? "Your \(name) rule" : "Your rule"
        }
        if r.hasSuffix(" rule"), r.count > 20 { return "App rule" }
        if r.count > 22 { return String(r.prefix(21)) + "…" }
        return r
    }
}
