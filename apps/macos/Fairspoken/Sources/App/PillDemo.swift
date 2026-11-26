#if DEBUG
import AppKit
import FairspokenCore

/// Dev-only `--pill-demo [seconds]`: shows the real floating pill, listening, with live text that
/// keeps growing and a level that follows a simulated voice, then quits. Prints, once a second,
/// the pill's screen frame, whether the panel takes the mouse, and whether the app or panel has
/// taken focus (it never should).
///
/// `--pill-demo-check <dir>` also sends the panel a scroll up, a scroll back down and a click,
/// as the window server would deliver them, saving the panel's pixels along the way and logging
/// the focus after each.
@MainActor
enum PillDemo {
    static func run(model: AppModel, pill: PillController) {
        let args = AppInfo.arguments
        if args.contains("--pill-demo-paste") {
            runPaste(model: model, pill: pill)
            return
        }
        let seconds = args.firstIndex(of: "--pill-demo").flatMap { i in i + 1 < args.count ? Double(args[i + 1]) : nil } ?? 30
        let checkDir = args.firstIndex(of: "--pill-demo-check").flatMap { i in i + 1 < args.count ? URL(fileURLWithPath: args[i + 1]) : nil }
        let words = ScreenshotHarness.longDictation.split(separator: " ").map(String.init)
        let since = Date()
        let panel = pill.debugPanel
        func log(_ what: String) {
            let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
            print("\(what): \(pill.debugDescription) frontmost=\(front)", String(format: "level=%.2f", model.dictation.meter.snapshot().level))
            fflush(stdout)
        }
        func shot(_ name: String) {
            guard let checkDir else { return }
            try? FileManager.default.createDirectory(at: checkDir, withIntermediateDirectories: true)
            try? ScreenshotHarness.png(of: panel)?.write(to: checkDir.appendingPathComponent("\(name).png"))
        }
        func send(_ cg: CGEvent?) {
            // An event with no window reads its location as window coordinates once sent to the
            // panel: aim at the middle of the pill's text (the pill sits at the panel's bottom).
            cg?.location = CGPoint(x: panel.frame.width / 2, y: (NSScreen.screens.first?.frame.height ?? 0) - 80)
            if let cg, let event = NSEvent(cgEvent: cg) { panel.sendEvent(event) }
        }
        Task {
            var shown = checkDir == nil ? 12 : 50
            var step = 0
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                let t = Double(step) / 10
                if step % 5 == 0, shown < words.count * 3 { shown += 1 }
                let text = (0..<shown).map { words[$0 % words.count] }.joined(separator: " ")
                model.dictation.showcase(.listening(since: since), liveText: text)
                let speech = max(0, 0.5 + 0.5 * sin(t * 3.1) * sin(t * 1.3 + 0.6))
                model.dictation.meter.push(rms: pow(10, Float(-62 + 34 * speech) / 20), seconds: 0.1)
                if step % 10 == 0 { log("t=\(Int(t))") }
                if checkDir != nil {
                    switch step {
                    case 60: shot("1-following")
                    case 63: shot("2-following-later")
                    case 70:
                        send(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 30, wheel2: 0, wheel3: 0))
                        log("after scroll up")
                    case 75: shot("3-scrolled-up")
                    case 95: shot("4-scrolled-up-later")
                    case 100:
                        send(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -2000, wheel2: 0, wheel3: 0))
                        log("after scroll down")
                    case 120: shot("5-following-again")
                    case 125:
                        send(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left))
                        send(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: .zero, mouseButton: .left))
                        log("after click")
                    default: break
                    }
                }
                step += 1
                try? await Task.sleep(for: .milliseconds(100))
            }
            model.dictation.showcase(.idle)
            try? await Task.sleep(for: .seconds(1))
            NSApp.terminate(nil)
        }
    }

    /// `--pill-demo-paste [dir]`: with another app in front (TextEdit with an empty document),
    /// starts a recording with no microphone aimed at it, then moves the real pointer and clicks
    /// as a person would (events posted to the window server): rests on the style chip, picks
    /// Notes in the menu, lets a hover-opened menu close by leaving it, and finishes with a
    /// sample transcript, which is styled and pasted as a dictation is. Logs focus after each
    /// step: the app in front must stay in front, and neither Bark nor its panels may take focus.
    static func runPaste(model: AppModel, pill: PillController) {
        let args = AppInfo.arguments
        let dir = args.firstIndex(of: "--pill-demo-paste").flatMap { i in i + 1 < args.count ? URL(fileURLWithPath: args[i + 1]) : nil }
        let dictation = model.dictation
        func log(_ what: String) {
            let front = NSWorkspace.shared.frontmostApplication
            let style = dictation.currentStyle.map { "\($0.style.rawValue) (\($0.reason))" } ?? "none"
            print("\(what): frontmost=\(front?.localizedName ?? "?") frontFocusedWindow=\(focusedWindowTitle(of: front) ?? "none") "
                  + "barkActive=\(NSApp.isActive) barkKeyWindow=\(NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "none") "
                  + "style=\(style) \(pill.debugDescription)")
            fflush(stdout)
        }
        func shot(_ name: String, _ panel: NSPanel) {
            guard let dir else { return }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? ScreenshotHarness.png(of: panel)?.write(to: dir.appendingPathComponent("\(name).png"))
        }
        /// Cocoa screen point (bottom-left origin) to the window server's (top-left).
        func cg(_ p: NSPoint) -> CGPoint {
            CGPoint(x: p.x, y: (NSScreen.screens.first?.frame.height ?? 0) - p.y)
        }
        // With Accessibility the real pointer moves and clicks through the window server.
        // Without it (or with the screen locked) the pill is told where a stand-in pointer is and
        // the clicks go straight to the panel under it, as the window server would send them.
        let real = AXIsProcessTrusted()
        func move(to p: NSPoint) {
            if real {
                CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: cg(p), mouseButton: .left)?.post(tap: .cghidEventTap)
            } else {
                pill.debugPointer = p
            }
        }
        func click(at p: NSPoint) {
            move(to: p)
            if real {
                CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: cg(p), mouseButton: .left)?.post(tap: .cghidEventTap)
                CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: cg(p), mouseButton: .left)?.post(tap: .cghidEventTap)
                return
            }
            guard let panel = [pill.debugMenuPanel, pill.debugPanel].first(where: { $0.isVisible && $0.frame.contains(p) }) else {
                print("click at \(p): no panel there")
                return
            }
            let local = panel.convertPoint(fromScreen: p)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: local, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    panel.sendEvent(event)
                }
            }
        }
        Task {
            print("accessibility trusted=\(real): \(real ? "the real pointer" : "a stand-in pointer and clicks sent to the panel")")
            try? await Task.sleep(for: .seconds(1))
            log("before")
            dictation.debugBeginFakeRecording()
            let feeder = Task {
                var t = 0.0
                while !Task.isCancelled {
                    t += 0.03
                    let syllable = pow(abs(sin(t * 5.5)), 0.6)
                    dictation.meter.push(rms: pow(10, Float(-46 + 18 * syllable) / 20))
                    try? await Task.sleep(for: .milliseconds(30))
                }
            }
            try? await Task.sleep(for: .seconds(1.5))
            log("listening")
            guard let chip = pill.debugChipCentre else { print("no chip"); NSApp.terminate(nil); return }
            // 1. Rest on the chip: the menu opens.
            move(to: chip)
            try? await Task.sleep(for: .milliseconds(700))
            log("resting on the chip")
            shot("1-pill-chip-hover", pill.debugPanel)
            shot("2-menu-open", pill.debugMenuPanel)
            // 2. Click Notes (the sixth style row).
            let menu = pill.debugMenuPanel.frame
            let notes = NSPoint(x: menu.minX + 60, y: menu.maxY - PillController.menuShadowRoom - 4 - 24 - 28 * 5 - 14)
            move(to: NSPoint(x: notes.x, y: chip.y + 20))
            try? await Task.sleep(for: .milliseconds(150))
            move(to: notes)
            try? await Task.sleep(for: .milliseconds(300))
            click(at: notes)
            try? await Task.sleep(for: .milliseconds(600))
            log("after clicking Notes")
            shot("3-pill-after-choice", pill.debugPanel)
            // 3. Rest on the chip again, then leave: a menu the pointer opened closes by itself.
            move(to: chip)
            try? await Task.sleep(for: .milliseconds(700))
            log("resting on the chip again")
            move(to: NSPoint(x: chip.x + 400, y: chip.y + 300))
            try? await Task.sleep(for: .milliseconds(800))
            log("pointer gone")
            // 4. Click the chip: the menu opens and stays when the pointer leaves; a second click closes it.
            click(at: chip)
            try? await Task.sleep(for: .milliseconds(400))
            move(to: NSPoint(x: chip.x + 400, y: chip.y + 300))
            try? await Task.sleep(for: .milliseconds(800))
            log("clicked the chip, pointer gone")
            click(at: chip)
            try? await Task.sleep(for: .milliseconds(400))
            log("clicked the chip again")
            move(to: NSPoint(x: chip.x + 400, y: chip.y + 300))
            // 5. Finish: styled as chosen and pasted into the app in front.
            feeder.cancel()
            let delivery = await dictation.debugFinishFakeRecording(
                "hi aoife new paragraph um can you send the revised quote by thursday no wait friday new paragraph thanks sam")
            print("delivery=\(delivery.map { String(describing: $0) } ?? "withdrawn")")
            log("after the paste")
            shot("4-pill-pasted", pill.debugPanel)
            try? await Task.sleep(for: .seconds(2))
            NSApp.terminate(nil)
        }
    }

    /// The title of the focused window of `app`, by Accessibility (nil without it).
    private static func focusedWindowTitle(of app: NSRunningApplication?) -> String? {
        guard let app, AXIsProcessTrusted() else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success, let window else { return nil }
        var title: CFTypeRef?
        AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title)
        return title as? String
    }
}
#endif
