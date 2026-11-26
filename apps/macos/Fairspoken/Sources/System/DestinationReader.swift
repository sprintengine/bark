import AppKit
import ApplicationServices
import Carbon.HIToolbox
import FairspokenCore
import Synchronization

/// Where a dictation is going, read through Accessibility when the recording starts: the
/// window title, the kind of field that has focus, and for a browser the page's address.
///
/// The address comes from `AXURL` on the web area that contains the focused element, falling
/// back to the window's `AXDocument`; no AppleScript. Only scheme, host and path are kept
/// (`DictationDestination.sanitize`). Every read is cross-process IPC, so it runs off the main
/// thread under one deadline; anything that doesn't answer in time is simply left out.
nonisolated enum DestinationReader {
    static let deadline: Duration = .milliseconds(300)
    /// How far up from the focused element a web area is looked for.
    static let maxAncestors = 40

    static let browserPrefixes = FieldReader.chromiumBrowserPrefixes + [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "org.mozilla.firefox", "org.mozilla.nightly",
        "app.zen-browser.zen", "com.kagi.kagimacOS",
    ]

    /// Chromium processes already asked to build their full tree: once per process is enough.
    private static let primed = Mutex<Set<pid_t>>([])

    static func isBrowser(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return browserPrefixes.contains { bundleID.hasPrefix($0) }
    }

    /// The destination for app `pid`, or what is known without Accessibility if it times out.
    static func read(pid: pid_t?, bundleID: String?, appName name: String?) async -> DictationDestination {
        let basic = DictationDestination(bundleID: bundleID, appName: name)
        guard let pid, AXIsProcessTrusted() else { return basic }
        // Password managers are never read; secure input means a password field has focus.
        if let bundleID, FieldReader.isPasswordManager(bundleID) {
            return DictationDestination(bundleID: bundleID, appName: name, isSecureField: true)
        }
        let browser = isBrowser(bundleID)
        let chromium = browser && FieldReader.isChromiumBased(bundleURL: nil, bundleID: bundleID)
            && primed.withLock { $0.insert(pid).inserted }
        let terminal = AppCategory.of(bundleID: bundleID) == .terminal
        let read = await FieldReader.withTimeout(deadline) {
            // Chromium builds the tree with page addresses only for assistive apps it knows
            // about: ask for it here too, whatever the edit watcher's settings (it is built
            // lazily, so the controller asks again a moment later if the address isn't there yet).
            if chromium, !FieldReader.enableManualAccessibility(pid: pid) { primed.withLock { _ = $0.remove(pid) } }
            return snapshot(pid: pid, bundleID: bundleID, appName: name, wantsURL: browser, readsField: !terminal)
        }
        var destination = read ?? basic
        if IsSecureEventInputEnabled() { destination.isSecureField = true }
        return destination
    }

    private static func snapshot(pid: pid_t, bundleID: String?, appName: String?, wantsURL: Bool, readsField: Bool) -> DictationDestination {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, FieldReader.messagingTimeout)
        let window = element(appElement, kAXFocusedWindowAttribute)
        let title = window.flatMap { string($0, kAXTitleAttribute) }
        var singleLine = false
        var secure = false
        var url: String?
        if readsField, let focused = element(appElement, kAXFocusedUIElementAttribute) {
            AXUIElementSetMessagingTimeout(focused, FieldReader.messagingTimeout)
            let role = string(focused, kAXRoleAttribute)
            let subrole = string(focused, kAXSubroleAttribute)
            secure = role == kAXSecureTextFieldSubrole as String || subrole == kAXSecureTextFieldSubrole as String
            singleLine = ["AXTextField", "AXComboBox", "AXSearchField"].contains(role ?? "") || subrole == "AXSearchField"
            if wantsURL { url = webAreaURL(from: focused) }
        }
        if wantsURL, url == nil, let window { url = string(window, kAXDocumentAttribute) }
        return DictationDestination(bundleID: bundleID, appName: appName, windowTitle: title, url: url,
                                    isSingleLineField: singleLine, isSecureField: secure)
    }

    /// `AXURL` of the nearest `AXWebArea` at or above `element`.
    private static func webAreaURL(from element: AXUIElement) -> String? {
        var current: AXUIElement? = element
        var steps = 0
        while let node = current, steps < maxAncestors {
            AXUIElementSetMessagingTimeout(node, FieldReader.messagingTimeout)
            if string(node, kAXRoleAttribute) == "AXWebArea" {
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(node, kAXURLAttribute as CFString, &value) == .success, let value else { return nil }
                if CFGetTypeID(value) == CFURLGetTypeID() { return (value as! URL).absoluteString }
                return value as? String
            }
            current = self.element(node, kAXParentAttribute)
            steps += 1
        }
        return nil
    }

    private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
