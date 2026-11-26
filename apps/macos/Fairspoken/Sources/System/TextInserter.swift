import AppKit
import ApplicationServices
import Carbon.HIToolbox
import FairspokenCore
import OSLog
import Synchronization

/// Delivers text to the frontmost app: clipboard + synthetic ⌘V after the hotkey's
/// modifiers are released (plan §2.7), then optionally restores the previous clipboard.
/// Respects secure input (password fields, some terminals) by copying only, and copies only
/// when the focused element is clearly not a text target (`PasteTarget`), so the dictation is
/// never pasted into nothing and then taken off the clipboard.
@MainActor
enum TextInserter {
    enum Outcome: Equatable {
        case pasted
        case copied(reason: String)
    }

    private static let log = Logger(subsystem: AppInfo.bundleID, category: "insert")
    /// Marks our temporary clipboard write so clipboard managers skip it (nspasteboard.org).
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    static let noTextTargetReason = "Copied — no text field. Press ⌘V to paste."
    static let switchedDuringCheckReason = "Copied — press ⌘V to paste"

    /// `expectedApp` is the app that was frontmost when recording started. If another app is in
    /// front now, the text is still pasted but the old clipboard is not put back, so the
    /// dictation stays recoverable if it landed somewhere unexpected. With `requireExpectedApp`
    /// (pasting a dictation again into its app) it is copied instead.
    ///
    /// With `html`, the pasteboard gets one item carrying both the HTML and the plain text, so
    /// apps that take rich text paste the layout and the rest paste the words.
    static func deliver(_ text: String, html: String? = nil, paste: Bool, restoreClipboard: Bool, expectedApp: pid_t?,
                        requireExpectedApp: Bool = false) async -> Outcome {
        let pasteboard = NSPasteboard.general
        func write(_ text: String, to pasteboard: NSPasteboard, transient: Bool) {
            Self.write(text, html: html, to: pasteboard, transient: transient)
        }
        guard paste else {
            write(text, to: pasteboard, transient: false)
            return .copied(reason: "Copied to clipboard")
        }
        guard AXIsProcessTrusted() else {
            write(text, to: pasteboard, transient: false)
            return .copied(reason: "Copied — allow Accessibility to paste")
        }
        // The target is checked after the wait: the user may switch apps while still releasing
        // the shortcut, and ⌘V goes to whatever is in front once it is up.
        await waitForModifierRelease(timeout: .milliseconds(800))
        if IsSecureEventInputEnabled() || focusedElementIsSecure() {
            // Never rich text into a secure field.
            Self.write(text, html: nil, to: pasteboard, transient: false)
            return .copied(reason: "Copied — secure field")
        }

        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let focus = await probeFocus(of: front)
        // The probe described an app that is no longer in front: don't paste blind.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != front {
            write(text, to: pasteboard, transient: false)
            return .copied(reason: switchedDuringCheckReason)
        }
        let bundleID = front.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
        if PasteTarget.decide(focus, appBundleID: bundleID) == .copyOnly {
            write(text, to: pasteboard, transient: false)
            return .copied(reason: noTextTargetReason)
        }

        let switchedApps = expectedApp != nil && front != expectedApp
        if switchedApps && requireExpectedApp {
            write(text, to: pasteboard, transient: false)
            return .copied(reason: switchedDuringCheckReason)
        }
        let saved = restoreClipboard && !switchedApps ? snapshot(pasteboard) : nil
        // The layout was made for the app the recording started in: elsewhere, words only.
        Self.write(text, html: switchedApps ? nil : html, to: pasteboard, transient: saved != nil)
        let ourChange = pasteboard.changeCount
        postCommandV()

        if let saved {
            // Give the target app time to read the pasteboard before restoring it. If another
            // app came to the front meanwhile, the paste may have missed: leave the dictation.
            try? await Task.sleep(for: .milliseconds(450))
            if pasteboard.changeCount == ourChange, NSWorkspace.shared.frontmostApplication?.processIdentifier == front {
                restore(saved, to: pasteboard)
            }
        }
        return .pasted
    }

    static func copy(_ text: String, html: String? = nil) {
        write(text, html: html, to: .general, transient: false)
    }

    private static func write(_ text: String, html: String?, to pasteboard: NSPasteboard, transient: Bool) {
        pasteboard.clearContents()
        guard let html else {
            pasteboard.setString(text, forType: .string)
            if transient { pasteboard.setData(Data(), forType: transientType) }
            return
        }
        let item = NSPasteboardItem()
        // The charset declaration keeps non-ASCII text (fadas, curly quotes) intact in every reader.
        item.setString("<meta charset=\"utf-8\">" + html, forType: .html)
        item.setString(text, forType: .string)
        if transient { item.setData(Data(), forType: transientType) }
        pasteboard.writeObjects([item])
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let data = item.data(forType: type) { entry[type] = data } }
            return entry
        }
    }

    private static func restore(_ items: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(restored)
    }

    /// Poll the combined session modifier state until ⌘⇧⌥⌃/fn are up (or time out), so the
    /// synthetic ⌘V is not merged with the user's still-held shortcut.
    private static func waitForModifierRelease(timeout: Duration) async {
        let deadline = ContinuousClock.now + timeout
        let mask: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl, .maskSecondaryFn]
        while ContinuousClock.now < deadline {
            if CGEventSource.flagsState(.combinedSessionState).intersection(mask).isEmpty { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .hidSystemState)
        let v = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// Reads the app's focus off the main actor, under one deadline for all of its AX queries
    /// (each is cross-process IPC). Running out of time is `.unknown`, which pastes.
    private static func probeFocus(of pid: pid_t?, deadline: Duration = .milliseconds(300)) async -> PasteTarget.Focus {
        guard let pid else { return .unknown }
        return await withCheckedContinuation { continuation in
            let probe = FocusProbe(continuation)
            DispatchQueue.global(qos: .userInitiated).async { probe.finish(focus(of: pid)) }
            Task.detached {
                try? await Task.sleep(for: deadline)
                probe.finish(.unknown)
            }
        }
    }

    /// Resumes its continuation once: with the probe's answer or the deadline's, whichever is first.
    nonisolated private final class FocusProbe: Sendable {
        private let continuation: Mutex<CheckedContinuation<PasteTarget.Focus, Never>?>
        init(_ continuation: CheckedContinuation<PasteTarget.Focus, Never>) { self.continuation = Mutex(continuation) }
        func finish(_ focus: PasteTarget.Focus) {
            continuation.withLock { $0.take() }?.resume(returning: focus)
        }
    }

    /// What the app says has focus. Any error is `.unknown` (which pastes); only an explicit
    /// "nothing focused" is `.none`.
    nonisolated private static func focus(of pid: pid_t) -> PasteTarget.Focus {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        var focused: CFTypeRef?
        switch AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused) {
        case .success:
            guard let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return .unknown }
            return .element(describe(focused as! AXUIElement))
        case .noValue:
            var window: CFTypeRef?
            let hasWindow: Bool? = switch AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &window) {
            case .success: window != nil
            case .noValue: false
            default: nil
            }
            return .none(appHasFocusedWindow: hasWindow)
        default:
            return .unknown
        }
    }

    nonisolated private static func describe(_ element: AXUIElement) -> PasteTarget.Element {
        AXUIElementSetMessagingTimeout(element, 0.25)
        func value(_ attribute: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
        }
        var settable = DarwinBoolean(false)
        let valueIsSettable: Bool? =
            AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success ? settable.boolValue : nil
        return PasteTarget.Element(
            role: value(kAXRoleAttribute) as? String,
            subrole: value(kAXSubroleAttribute) as? String,
            isEditable: value("AXIsEditable") as? Bool,
            hasEditableAncestor: value("AXEditableAncestor") != nil,
            valueIsSettable: valueIsSettable)
    }

    /// `AXSecureTextField` focus check with a short messaging timeout (AX is cross-process IPC).
    private static func focusedElementIsSecure() -> Bool {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.25)
        var subrole: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
           (subrole as? String) == (kAXSecureTextFieldSubrole as String) {
            return true
        }
        return false
    }
}
