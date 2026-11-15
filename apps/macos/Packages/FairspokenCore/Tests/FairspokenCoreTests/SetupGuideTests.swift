import Foundation
import Testing
@testable import FairspokenCore

@Suite("Setup guide")
struct SetupGuideTests {
    typealias Step = SetupGuide.Step

    // MARK: Steps

    @Test func walksEveryStepWhenTheEngineWorks() {
        var step = Step.welcome
        var seen = [step]
        while step != .finish {
            step = SetupGuide.step(after: step, engineUsable: true)
            seen.append(step)
        }
        #expect(seen == Step.allCases)
    }

    @Test func passesOverTryItWhenTheModelIsUnusable() {
        #expect(SetupGuide.step(after: .shortcut, engineUsable: false) == .finish)
        #expect(SetupGuide.step(before: .finish, engineUsable: false) == .shortcut)
        #expect(SetupGuide.step(before: .finish, engineUsable: true) == .tryIt)
        #expect(SetupGuide.step(after: .finish, engineUsable: true) == .finish)
        #expect(SetupGuide.step(before: .welcome, engineUsable: true) == .welcome)
    }

    @Test func aFailedDownloadKeepsThePersonOnTheModelStep() {
        #expect(!SetupGuide.ModelProgress.failed("No connection").canContinue)
        #expect(!SetupGuide.ModelProgress.failed("No connection").engineUsable)
        #expect(SetupGuide.ModelProgress.preparing(fraction: 0.4).canContinue)
        #expect(SetupGuide.ModelProgress.preparing(fraction: 0.4).engineUsable)
        #expect(SetupGuide.ModelProgress.remote.engineUsable)
        #expect(!SetupGuide.ModelProgress.notStarted.engineUsable)
    }

    @Test func offersTheDefaultFirstThenAShortListFromTheCatalogue() {
        let choices = SetupGuide.modelChoices(from: SpeechModelCatalog.all, defaultID: SpeechModelCatalog.defaultModelID)
        #expect(choices.count == 4)
        #expect(choices.first?.id == SpeechModelCatalog.defaultModelID)
        #expect(choices.allSatisfy { $0.isLocal && !$0.isExperimental })
        // Every recommended model is offered.
        for model in SpeechModelCatalog.all where model.isRecommended && !model.isExperimental {
            #expect(choices.contains { $0.id == model.id })
        }
        // A model chosen earlier is listed too.
        let withChosen = SetupGuide.modelChoices(from: SpeechModelCatalog.all, defaultID: SpeechModelCatalog.defaultModelID,
                                                 including: "tiny")
        #expect(withChosen.last?.id == "tiny")
        #expect(withChosen.count == 5)
    }

    // MARK: Microphone check

    @Test func tellsPermissionDeviceFailureAndSilenceApart() {
        func check(_ p: SetupGuide.Permission = .granted, devices: Int = 1, running: Bool = true, error: String? = nil,
                   seconds: Double = 1, peak: Float = 0) -> SetupGuide.MicCheck {
            SetupGuide.micCheck(permission: p, deviceCount: devices, running: running, error: error,
                                listenedSeconds: seconds, peakLevel: peak)
        }
        #expect(check(.notDetermined) == .needsPermission)
        #expect(check(.denied) == .denied)
        #expect(check(devices: 0) == .noDevice)
        #expect(check(error: "The device is busy") == .failed("The device is busy"))
        #expect(check(seconds: 1) == .listening)
        #expect(check(seconds: SetupGuide.silenceSeconds) == .silent)
        #expect(check(seconds: 9, peak: 0.5) == .hearing)
        #expect(check(running: false) == .idle)
        // A test that stopped itself after silence keeps saying so.
        #expect(check(running: false, seconds: SetupGuide.silenceSeconds) == .silent)
        // Once heard, stopping the test keeps the result.
        #expect(check(running: false, peak: 0.5) == .hearing)
    }

    // MARK: Checklist

    @Test func isReadyOnlyWhenTheMicrophoneAndModelAre() {
        let ready = SetupGuide.checklist(microphone: .granted, accessibility: false, model: .ready, micHeard: nil)
        #expect(SetupGuide.isReady(ready))
        #expect(ready.map(\.kind) == [.microphone, .model, .accessibility])

        let noMic = SetupGuide.checklist(microphone: .denied, accessibility: true, model: .ready, micHeard: true)
        #expect(!SetupGuide.isReady(noMic))
        #expect(noMic.first?.state == .problem("Turned off in System Settings"))

        let downloading = SetupGuide.checklist(microphone: .granted, accessibility: true, model: .preparing(fraction: 0.456), micHeard: false)
        #expect(!SetupGuide.isReady(downloading))
        #expect(downloading[1].state == .pending("Downloading, 46%"))
        #expect(downloading.last?.kind == .micHeard)
        #expect(downloading.last?.state == .pending("Nothing heard"))

        let failed = SetupGuide.checklist(microphone: .granted, accessibility: true, model: .failed("Disk full"), micHeard: nil)
        #expect(failed[1].state == .problem("Disk full"))
        #expect(SetupGuide.isReady(SetupGuide.checklist(microphone: .granted, accessibility: false, model: .remote, micHeard: false)))
    }

    @Test func modelProgressFollowsTheChosenModel() {
        func progress(chosen: String = "b", active: String = "a", engine: SetupGuide.EngineStatus = .ready,
                      item: SetupGuide.ItemStatus = .available, error: String? = nil, remote: Bool = false) -> SetupGuide.ModelProgress {
            SetupGuide.modelProgress(remote: remote, chosenID: chosen, activeID: active, activeName: "Model A",
                                     engine: engine, chosenItem: item, downloadError: error)
        }
        #expect(progress(remote: true) == .remote)
        // Model A works and B's download fails: dictation still works.
        let fallback = progress(error: "No connection")
        #expect(fallback == .fallback(failed: "No connection", using: "Model A"))
        #expect(fallback.canContinue && fallback.engineUsable)
        #expect(SetupGuide.isReady(SetupGuide.checklist(microphone: .granted, accessibility: false, model: fallback, micHeard: nil)))
        // Nothing works: a real failure.
        #expect(progress(engine: .failed("Out of memory"), error: "No connection") == .failed("No connection"))
        #expect(progress(chosen: "a", engine: .idle, error: "No connection") == .failed("No connection"))
        #expect(progress(item: .downloading(0.4)) == .preparing(fraction: 0.4))
        #expect(progress(item: .preparing) == .preparing(fraction: nil))
        #expect(progress() == .notStarted)
        #expect(progress(chosen: "a", engine: .downloading(0.2)) == .preparing(fraction: 0.2))
        #expect(progress(chosen: "a", engine: .failed("Bad file")) == .failed("Bad file"))
        #expect(progress(chosen: "a", item: .installed) == .ready)
        #expect(progress(chosen: "a", engine: .busy, item: .installed) == .preparing(fraction: nil))
        // Installed, waiting to load after the dictation in progress.
        #expect(progress(item: .installed) == .preparing(fraction: nil))
    }

    @Test func onlyTheLatestCaptureOwnerMayStopIt() {
        var ownership = CaptureOwnership()
        let test = ownership.begin()
        #expect(ownership.owns(test))
        let dictation = ownership.begin()
        #expect(!ownership.owns(test))
        #expect(ownership.owns(dictation))
    }

    // MARK: Home

    @Test func countsDistinctApps() {
        func item(_ bundle: String?, _ name: String?) -> TranscriptHistoryItem {
            TranscriptHistoryItem(id: UUID().uuidString, createdAt: 0, text: "x", backend: "b", location: "local",
                                  durationSeconds: 1, appName: name, appBundleId: bundle)
        }
        let items = [item("com.apple.mail", "Mail"), item("com.apple.Mail", "Mail"), item(nil, "Slack"), item(nil, nil),
                     item("com.apple.Notes", "Notes")]
        #expect(items.appsUsed == 3)
        #expect([TranscriptHistoryItem]().appsUsed == 0)
    }
}
