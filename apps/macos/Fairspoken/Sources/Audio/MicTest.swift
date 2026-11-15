import FairspokenCore
import Foundation
import Observation

/// The microphones to offer. Demo and screenshot runs list sample names, never this Mac's own
/// devices (which can carry a person's name).
enum Microphones {
    static let demoNames = ["MacBook Pro Microphone", "Studio Display Microphone", "USB Headset"]

    static func names() -> [String] {
        AppInfo.isDemo ? demoNames : AudioCapture.inputDevices().map(\.name)
    }

    /// The system default input's name.
    static func defaultName() -> String? {
        AppInfo.isDemo ? demoNames.first : AudioCapture.defaultInputName()
    }

    /// What `audioDevice` ("" is the system default) reads as.
    static func displayName(for setting: String) -> String {
        setting.isEmpty ? (defaultName() ?? "System default") : setting
    }
}

/// The setup guide's microphone test: listens on the chosen device and reports what it found
/// (permission, device, failure, silence or speech). It shares the dictation's capture, so it
/// never runs during a dictation, and it stops whenever the guide closes.
@Observable
final class MicTest {
    private(set) var running = false
    private(set) var error: String?
    private(set) var peak: Float = 0
    private(set) var startedAt: Date?
    /// Set on each tick while running, so views re-evaluate the elapsed time.
    private(set) var now = Date()

    @ObservationIgnored private let capture: AudioCapture
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var showcased = false
    /// This test's hold on the shared capture; a dictation that starts afterwards takes it over.
    @ObservationIgnored private var captureToken: Int?

    init(capture: AudioCapture) { self.capture = capture }

    var meter: LevelMeter { capture.meter }
    var listenedSeconds: Double { startedAt.map { now.timeIntervalSince($0) } ?? 0 }

    func check(permission: SetupGuide.Permission, deviceCount: Int) -> SetupGuide.MicCheck {
        SetupGuide.micCheck(permission: permission, deviceCount: deviceCount, running: running, error: error,
                            listenedSeconds: listenedSeconds, peakLevel: peak)
    }

    func start(deviceName: String) {
        stop()
        error = nil
        peak = 0
        do {
            captureToken = try capture.start(deviceName: deviceName, maxSeconds: 60, sink: nil)
        } catch {
            self.error = error.localizedDescription
            return
        }
        running = true
        startedAt = Date()
        now = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if running && !showcased, let captureToken { capture.stop(owner: captureToken) }
        captureToken = nil
        running = false
        showcased = false
    }

    private func tick() {
        now = Date()
        peak = max(peak, meter.snapshot().level)
        // A test, not a recording: stop after a while.
        if listenedSeconds > 30 { stop() }
    }

    /// Screenshots: a running test that has heard speech, fed by the caller's levels.
    func showcase(listening: Bool, peak: Float) {
        stop()
        running = listening
        showcased = listening
        startedAt = Date().addingTimeInterval(-3)
        now = Date()
        self.peak = peak
        error = nil
    }
}
