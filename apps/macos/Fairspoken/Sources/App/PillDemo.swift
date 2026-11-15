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
}
#endif
