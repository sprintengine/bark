import AppKit
import ApplicationServices
import FairspokenCore
import Synchronization

/// The focused text field just before a dictation is inserted into it.
nonisolated struct WatchedField: @unchecked Sendable {
    /// An AXUIElement is an immutable CF object; retain/release are thread-safe and AX messaging
    /// may happen from any thread.
    let element: AXUIElement
    let pid: pid_t
    let bundleID: String
    let value: String
    /// `AXSelectedTextRange`, in UTF-16 code units.
    let selectionStart: Int
    let selectionLength: Int
}

/// The Accessibility reads behind the edit watcher (`macos_ax.rs` in the Tauri app). Every call
/// here is cross-process IPC, so callers run it off the main thread under `withTimeout`.
///
/// Never read: password managers (by bundle id), terminals, secure fields (by role or subrole),
/// fields without a plain-text `AXValue`, and values over `valueCap`.
nonisolated enum FieldReader {
    /// Fields longer than this (UTF-16 code units) are not watched: re-reading a whole long
    /// document is too slow for the time limit, and the fields people dictate into are far smaller.
    static let valueCap = 100_000
    /// Per-message AX timeout, as the Tauri app's watcher uses.
    static let messagingTimeout: Float = 0.1

    /// No AX reads at all inside password managers (`PASSWORD_MANAGER_PREFIXES`).
    static let passwordManagerPrefixes = ["com.1password.", "com.agilebits.", "com.bitwarden.", "com.lastpass.", "org.keepassxc."]

    static func isPasswordManager(_ bundleID: String) -> Bool {
        passwordManagerPrefixes.contains { bundleID.hasPrefix($0) }
    }

    enum Skip: String, Error {
        case excludedApp = "a password manager or terminal"
        case noFocusedElement = "no focused element"
        case secureField = "a secure field"
        case noText = "no readable text, or too long"
        case noSelection = "no selection range"
    }

    /// Reads the focused field's text and selection in app `pid`.
    static func snapshot(pid: pid_t, bundleID: String) -> Result<WatchedField, Skip> {
        if isPasswordManager(bundleID) || AppCategory.of(bundleID: bundleID) == .terminal { return .failure(.excludedApp) }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        guard let focused = element(app, kAXFocusedUIElementAttribute) else { return .failure(.noFocusedElement) }
        AXUIElementSetMessagingTimeout(focused, messagingTimeout)
        if isSecure(focused) { return .failure(.secureField) }
        guard let value = cappedValue(focused) else { return .failure(.noText) }
        guard let range = selection(focused) else { return .failure(.noSelection) }
        return .success(WatchedField(element: focused, pid: pid, bundleID: bundleID, value: value,
                                     selectionStart: range.location, selectionLength: range.length))
    }

    /// The watched field's current text, under the same exclusions.
    static func currentValue(of element: AXUIElement) -> String? {
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return isSecure(element) ? nil : cappedValue(element)
    }

    /// Whether `element` still has keyboard focus in app `pid`; nil when that can't be read.
    static func isFocused(_ element: AXUIElement, in pid: pid_t) -> Bool? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        guard let focused = Self.element(app, kAXFocusedUIElementAttribute) else { return nil }
        return CFEqual(focused, element)
    }

    // MARK: Chromium and Electron

    /// Chromium only builds its full accessibility tree, with text fields' values and
    /// selections, for assistive apps it knows about. Electron apps build it when an app sets
    /// `AXManualAccessibility` on them; Chromium browsers honour the same attribute. Setting it
    /// has no visible effect (unlike `AXEnhancedUserInterface`, which VoiceOver uses and which
    /// makes some apps animate and position their windows differently, so it is never set here).
    /// The tree is built asynchronously, so this is set when a recording starts, seconds before
    /// the field is read. Apps that don't know the attribute return an error and are unchanged.
    static func enableManualAccessibility(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        return AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success
    }

    /// Bundle ids of Chromium browsers, which need `AXManualAccessibility` as Electron apps do.
    static let chromiumBrowserPrefixes = [
        "com.google.Chrome", "org.chromium.Chromium", "com.microsoft.edgemac", "com.brave.Browser",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "company.thebrowser.Browser",
    ]

    /// Electron (it ships `Electron Framework.framework`) or a Chromium browser.
    static func isChromiumBased(bundleURL: URL?, bundleID: String?) -> Bool {
        if let bundleID, chromiumBrowserPrefixes.contains(where: { bundleID.hasPrefix($0) }) { return true }
        guard let bundleURL else { return false }
        let framework = bundleURL.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        return FileManager.default.fileExists(atPath: framework.path)
    }

    // MARK: Attributes

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

    /// `NSSecureTextField` and browser password inputs report role `AXTextField` with subrole
    /// `AXSecureTextField`; some report it as the role.
    private static func isSecure(_ element: AXUIElement) -> Bool {
        let secure = kAXSecureTextFieldSubrole as String
        return string(element, kAXRoleAttribute) == secure || string(element, kAXSubroleAttribute) == secure
    }

    /// `AXValue` as a string, checking `AXNumberOfCharacters` first so a huge value is never
    /// copied across the process boundary.
    private static func cappedValue(_ element: AXUIElement) -> String? {
        var count: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &count) == .success,
           let length = (count as? NSNumber)?.intValue, length < 0 || length > valueCap {
            return nil
        }
        guard let value = string(element, kAXValueAttribute), value.utf16.count <= valueCap else { return nil }
        return value
    }

    private static func selection(_ element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
        return range
    }

    // MARK: Time limit

    /// Runs `work` on a background queue and returns its result, or nil if it takes longer than
    /// `limit` (AX calls can hang on a busy app; the work is left to finish on its own).
    static func withTimeout<T: Sendable>(_ limit: Duration = .milliseconds(250), _ work: @escaping @Sendable () -> T) async -> T? {
        await withCheckedContinuation { continuation in
            let once = Once(continuation)
            DispatchQueue.global(qos: .userInitiated).async { once.finish(work()) }
            Task.detached {
                try? await Task.sleep(for: limit)
                once.finish(nil)
            }
        }
    }

    /// Resumes its continuation once: with the work's answer or the deadline's, whichever is first.
    private final class Once<T: Sendable>: Sendable {
        private let continuation: Mutex<CheckedContinuation<T?, Never>?>
        init(_ continuation: CheckedContinuation<T?, Never>) { self.continuation = Mutex(continuation) }
        func finish(_ value: T?) { continuation.withLock { $0.take() }?.resume(returning: value) }
    }
}
