import AppKit
import CoreGraphics
import KeyboardShortcuts
import FairspokenCore
import OSLog

extension KeyboardShortcuts.Name {
    /// ⌘⇧1 by default, matching the Tauri app's `recordingShortcut`.
    static let dictation = Self("dictation", default: .init(.one, modifiers: [.command, .shift]))
    /// Registered only while recording, so Esc is never stolen from other apps otherwise.
    static let cancelDictation = Self("cancelDictation", default: .init(.escape))
}

/// Global dictation triggers: the KeyboardShortcuts combo (Carbon hot key, no permission)
/// in toggle or push-to-talk mode, plus optional hold-Fn/Globe via a listen-only event tap.
@MainActor
final class HotkeyController {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onCancel: (() -> Void)?
    var onFnPress: (() -> Void)?
    var onFnRelease: (() -> Void)?

    private let fnMonitor = FnKeyMonitor()

    init() {
        KeyboardShortcuts.onKeyDown(for: .dictation) { [weak self] in self?.onPress?() }
        KeyboardShortcuts.onKeyUp(for: .dictation) { [weak self] in self?.onRelease?() }
        KeyboardShortcuts.onKeyDown(for: .cancelDictation) { [weak self] in self?.onCancel?() }
        KeyboardShortcuts.disable(.cancelDictation)
        fnMonitor.onChange = { [weak self] down in
            if down { self?.onFnPress?() } else { self?.onFnRelease?() }
        }
    }

    func setCancelEnabled(_ enabled: Bool) {
        if enabled { KeyboardShortcuts.enable(.cancelDictation) } else { KeyboardShortcuts.disable(.cancelDictation) }
    }

    /// Starts/stops the Fn tap. Returns false when Input Monitoring is missing.
    @discardableResult
    func setFnEnabled(_ enabled: Bool) -> Bool {
        enabled ? fnMonitor.start() : { fnMonitor.stop(); return true }()
    }

    var fnActive: Bool { fnMonitor.isRunning }

    private var shortcutHoldWatch: Task<Void, Never>?

    /// While a hold-to-talk recording started by the shortcut runs: every 250 ms, whether the
    /// shortcut's modifiers are still held. Once they have been seen held and then are not, the
    /// key-up was lost (sleep, secure input, a busy main thread), and `onReleased` stands in for
    /// it. Reads only the modifier state, which needs no permission. A shortcut without
    /// modifiers can't be watched this way.
    func watchShortcutHold(onReleased: @escaping () -> Void) {
        stopWatchingShortcutHold()
        guard let modifiers = KeyboardShortcuts.getShortcut(for: .dictation)?.modifiers else { return }
        var wanted: CGEventFlags = []
        if modifiers.contains(.command) { wanted.insert(.maskCommand) }
        if modifiers.contains(.shift) { wanted.insert(.maskShift) }
        if modifiers.contains(.option) { wanted.insert(.maskAlternate) }
        if modifiers.contains(.control) { wanted.insert(.maskControl) }
        guard !wanted.isEmpty else { return }
        shortcutHoldWatch = Task { [weak self] in
            var seenHeld = false
            while !Task.isCancelled {
                let held = CGEventSource.flagsState(.combinedSessionState).isSuperset(of: wanted)
                if held {
                    seenHeld = true
                } else if seenHeld {
                    Self.log.notice("The shortcut's release was missed; ending the hold")
                    self?.shortcutHoldWatch = nil
                    onReleased()
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func stopWatchingShortcutHold() {
        shortcutHoldWatch?.cancel()
        shortcutHoldWatch = nil
    }

    private static let log = Logger(subsystem: AppInfo.bundleID, category: "hotkeys")

    /// Seeds the KeyboardShortcuts binding from an imported Tauri accelerator string once.
    static func adoptAccelerator(_ accelerator: String) {
        guard let parsed = AcceleratorString(parsing: accelerator), let key = key(for: parsed.code) else { return }
        var mods: NSEvent.ModifierFlags = []
        if parsed.modifiers.contains(.command) { mods.insert(.command) }
        if parsed.modifiers.contains(.shift) { mods.insert(.shift) }
        if parsed.modifiers.contains(.option) { mods.insert(.option) }
        if parsed.modifiers.contains(.control) { mods.insert(.control) }
        KeyboardShortcuts.setShortcut(.init(key, modifiers: mods), for: .dictation)
    }

    /// The current binding in the shared schema's accelerator format.
    static func currentAccelerator() -> String? {
        guard let shortcut = KeyboardShortcuts.getShortcut(for: .dictation), let key = shortcut.key,
              let code = codes.first(where: { $0.value == key })?.key else { return nil }
        var mods: AcceleratorString.Modifiers = []
        if shortcut.modifiers.contains(.command) { mods.insert(.command) }
        if shortcut.modifiers.contains(.shift) { mods.insert(.shift) }
        if shortcut.modifiers.contains(.option) { mods.insert(.option) }
        if shortcut.modifiers.contains(.control) { mods.insert(.control) }
        return AcceleratorString(modifiers: mods, code: code).string
    }

    static var hasShortcut: Bool { KeyboardShortcuts.getShortcut(for: .dictation) != nil }

    static var currentShortcutSymbols: String {
        KeyboardShortcuts.getShortcut(for: .dictation)?.description ?? "Not set"
    }

    /// The key that cancels a recording ("⎋" unless changed).
    static var cancelShortcutSymbols: String? {
        KeyboardShortcuts.getShortcut(for: .cancelDictation)?.description
    }

    private static func key(for code: String) -> KeyboardShortcuts.Key? { codes[code] }

    private static let codes: [String: KeyboardShortcuts.Key] = {
        var map: [String: KeyboardShortcuts.Key] = [
            "Digit0": .zero, "Digit1": .one, "Digit2": .two, "Digit3": .three, "Digit4": .four,
            "Digit5": .five, "Digit6": .six, "Digit7": .seven, "Digit8": .eight, "Digit9": .nine,
            "Space": .space, "Escape": .escape, "Enter": .return, "Tab": .tab,
            "F1": .f1, "F2": .f2, "F3": .f3, "F4": .f4, "F5": .f5, "F6": .f6,
            "F7": .f7, "F8": .f8, "F9": .f9, "F10": .f10, "F11": .f11, "F12": .f12,
            "Semicolon": .semicolon, "Period": .period, "Comma": .comma, "Slash": .slash,
            "Minus": .minus, "Equal": .equal, "Backquote": .backtick,
        ]
        let letters: [KeyboardShortcuts.Key] = [.a, .b, .c, .d, .e, .f, .g, .h, .i, .j, .k, .l, .m,
                                                .n, .o, .p, .q, .r, .s, .t, .u, .v, .w, .x, .y, .z]
        for (i, key) in letters.enumerated() {
            map["Key\(Character(UnicodeScalar(UInt8(65 + i))))"] = key
        }
        return map
    }()
}

/// Listen-only `CGEventTap` on `flagsChanged`, watching keycode 63 (Fn/Globe), exactly as
/// `macos_input.rs` does. Needs Input Monitoring (not Accessibility). Re-enables itself
/// when macOS disables the tap for timeout or user input.
///
/// A release can be lost (the tap disabled while Fn went up, sleep, the screen locking, secure
/// input), which would leave a hold-to-talk recording running. So when the tap is re-enabled,
/// and every 250 ms while Fn is held, the key's state is read from the session's modifier
/// flags (no permission beyond the tap's own), and a release is reported if it is up. That
/// check acts only once the flags have shown Fn down during this hold, so a keyboard whose Fn
/// never appears there is not cut short.
@MainActor
final class FnKeyMonitor {
    var onChange: ((Bool) -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var fnDown = false
    /// The session's flags have shown Fn held during this hold.
    private var flagsShowFn = false
    private var holdPoll: Task<Void, Never>?
    private static let log = Logger(subsystem: AppInfo.bundleID, category: "hotkeys")

    var isRunning: Bool { tap != nil }

    func start() -> Bool {
        guard tap == nil else { return true }
        guard CGPreflightListenEventAccess() else { return false }
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                          eventsOfInterest: mask, callback: fnTapCallback, userInfo: refcon) else {
            Self.log.error("Creating the Fn event tap failed")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        source = nil
        if fnDown { setFn(false) }
    }

    fileprivate func handle(type: CGEventType, keyCode: Int64, flags: CGEventFlags) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Self.log.notice("The Fn tap was disabled (\(type == .tapDisabledByTimeout ? "timeout" : "user input", privacy: .public)); re-enabling it")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            // Fn may have gone up while the tap was off.
            checkStillHeld(reason: "after the tap was re-enabled")
            return
        }
        guard type == .flagsChanged, keyCode == 63 else { return }
        let down = flags.contains(.maskSecondaryFn)
        guard down != fnDown else { return }
        setFn(down)
    }

    private func setFn(_ down: Bool) {
        fnDown = down
        holdPoll?.cancel()
        holdPoll = nil
        if down {
            flagsShowFn = Self.fnHeldNow()
            holdPoll = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                    self?.checkStillHeld(reason: "while it was held")
                }
            }
        }
        onChange?(down)
    }

    /// Reports the release macOS didn't deliver, if Fn is up now.
    private func checkStillHeld(reason: String) {
        guard fnDown else { return }
        if Self.fnHeldNow() {
            flagsShowFn = true
        } else if flagsShowFn {
            Self.log.notice("Fn's release was missed (\(reason, privacy: .public)); ending the hold")
            setFn(false)
        }
    }

    private static func fnHeldNow() -> Bool {
        CGEventSource.flagsState(.combinedSessionState).contains(.maskSecondaryFn)
    }
}

/// C callback; the tap's run-loop source is on the main run loop, so this runs on main.
nonisolated private func fnTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let refcon {
        let monitor = Unmanaged<FnKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        MainActor.assumeIsolated { monitor.handle(type: type, keyCode: keyCode, flags: flags) }
    }
    return Unmanaged.passUnretained(event)
}
