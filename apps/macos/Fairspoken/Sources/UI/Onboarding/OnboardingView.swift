import FairspokenUI
import KeyboardShortcuts
import FairspokenCore
import SwiftUI

/// The setup guide: welcome → permissions → microphone test → model → shortcut → try it →
/// a live checklist. One primary button per step. Every status is read live; nothing is claimed
/// that isn't so.
struct OnboardingView: View {
    typealias Step = SetupGuide.Step
    static let size = NSSize(width: 720, height: 860)

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step: Step
    /// The microphone test heard speech (nil until it has run).
    @State private var micHeard: Bool?
    /// Screenshots: "Try it" with a dictated message in its thread.
    var showcase = false
    var onFinish: () -> Void

    init(initialStep: Step = .welcome, showcase: Bool = false, onFinish: @escaping () -> Void) {
        _step = State(initialValue: initialStep)
        _micHeard = State(initialValue: showcase ? true : nil)
        self.showcase = showcase
        self.onFinish = onFinish
    }

    var body: some View {
        ZStack(alignment: .top) {
            Crystal.canvas
            // A subtle wash of the accent across the top.
            LinearGradient(colors: [Crystal.clientAccent.opacity(0.16), Crystal.clientAccent.opacity(0.05), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 320)
                .allowsHitTesting(false)
            VStack(spacing: 0) {
                StepProgress(step: step)
                    .padding(.top, 44)
                    .frame(height: 76, alignment: .top)
                Group {
                    if step == .tryIt {
                        // The thread fills the window; it scrolls itself.
                        TryItStep(showcase: showcase).padding(.horizontal, 56)
                    } else {
                        // On a short screen the step scrolls and the buttons stay put.
                        ScrollView {
                            Group {
                                switch step {
                                case .welcome: WelcomeStep()
                                case .permissions: PermissionsStep()
                                case .microphone: MicrophoneStep(heard: $micHeard)
                                case .model: ModelStep()
                                case .shortcut: ShortcutStep()
                                case .tryIt: EmptyView()
                                case .finish: FinishStep(micHeard: micHeard, go: go(to:))
                                }
                            }
                            .padding(.horizontal, 56)
                            .padding(.bottom, 12)
                        }
                        .scrollBounceBehavior(.basedOnSize)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .id(step)
                .transition(reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(x: 16)),
                                                                  removal: .opacity.combined(with: .offset(x: -16))))
                footer
                    .padding(.horizontal, 32)
                    .padding(.vertical, 22)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .screenshotActive()
        .onAppear { model.permissions.beginPolling() }
        .onDisappear {
            model.permissions.endPolling()
            model.micTest.stop()
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if step != .welcome && step != .finish {
                Button("Back") { go(to: SetupGuide.step(before: step, engineUsable: model.modelProgress.engineUsable)) }
                    .buttonStyle(.borderless)
                    .controlSize(.large)
                    .foregroundStyle(Crystal.ink2)
            }
            Spacer()
            secondary
            primary
                .buttonStyle(PrimaryButtonStyle(large: true))
                .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder private var secondary: some View {
        if step == .model, !model.modelProgress.canContinue {
            Button("Skip for Now") { advance() }
                .controlSize(.large)
                .buttonBorderShape(.capsule)
                .help("Carry on without a model. The last step shows what's left.")
        }
    }

    @ViewBuilder private var primary: some View {
        switch step {
        case .welcome:
            Button("Get Started") { advance() }
        case .permissions:
            switch model.permissions.microphone {
            case .granted: Button("Continue") { advance() }
            case .notDetermined: Button("Allow Microphone") { model.permissions.request(.microphone) }
            case .denied: Button("Open System Settings") { model.permissions.openSettings(.microphone) }
            }
        case .model:
            if model.modelProgress.canContinue {
                Button("Continue") { advance() }
            } else {
                Button("Retry") { retryModel() }
            }
        case .tryIt where model.dictation.phase.isListening:
            // Finish the sentence rather than throw it away.
            Button("Stop") { model.dictation.toggleFromUI() }
        case .tryIt where model.dictation.phase == .transcribing:
            Button("Continue") {}.disabled(true)
        case .finish:
            Button(SetupGuide.isReady(model.setupChecklist(micHeard: micHeard)) ? "Start Dictating" : "Done") {
                model.completeOnboarding()
                onFinish()
            }
        default:
            Button("Continue") { advance() }
        }
    }

    private func advance() {
        go(to: SetupGuide.step(after: step, engineUsable: model.modelProgress.engineUsable))
    }

    private func go(to next: Step) {
        if step == .microphone { model.micTest.stop() }
        if step == .tryIt, model.dictation.phase.isListening, model.dictation.startedInWindow == WindowCoordinator.onboardingID {
            model.dictation.cancel()
        }
        withAnimation(Motion.unlessReduced(Motion.deliberate, reduceMotion)) { step = next }
    }

    private func retryModel() {
        let id = SpeechModelCatalog.resolve(model.settings.settings.model).id
        model.models.clearDownloadError(id)
        model.useModel(id)
    }
}

// MARK: - Shared pieces

/// "Step 2 of 6" over a segmented line (the welcome screen shows none).
private struct StepProgress: View {
    var step: SetupGuide.Step

    var body: some View {
        let steps = SetupGuide.Step.allCases.filter { $0 != .welcome }
        if step != .welcome, let index = steps.firstIndex(of: step) {
            VStack(spacing: 8) {
                HStack(spacing: 4) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { i, _ in
                        Capsule().fill(i <= index ? Crystal.clientAccent : Crystal.hairline)
                            .frame(width: 36, height: 4)
                    }
                }
                Text("Step \(index + 1) of \(steps.count) · \(step.title)")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Crystal.ink2)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(index + 1) of \(steps.count), \(step.title)")
        }
    }
}

/// A step's title and its one line of explanation.
private struct StepHeader: View {
    var title: String
    var subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(TypeScale.display).tracking(-0.4).foregroundStyle(Crystal.ink)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle).font(.system(size: 15)).foregroundStyle(Crystal.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 12)
        .padding(.bottom, 22)
    }
}

// MARK: - 1 Welcome

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 18) {
            BrandMark(size: 96)
                .padding(.bottom, 10)
            Text(AppInfo.displayName)
                .font(.system(size: 34, weight: .semibold)).tracking(-0.6)
                .foregroundStyle(Crystal.ink)
                .accessibilityAddTraits(.isHeader)
            Text("Speak in any app. Your words appear where you type,\ntranscribed privately on your own devices.")
                .font(.system(size: 15)).foregroundStyle(Crystal.ink2)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
            HStack(spacing: 8) {
                Chip(text: "On this Mac", symbol: "lock.fill", flat: true)
                Chip(text: "Text in a blink", symbol: "bolt.fill", flat: true)
                Chip(text: "25 languages", symbol: "globe", flat: true)
            }
            .padding(.top, 6)
            Text("Setup takes about two minutes.")
                .font(TypeScale.meta).foregroundStyle(Crystal.ink3)
                .padding(.top, 28)
        }
        .frame(maxWidth: .infinity)
        // Centred in the space above the buttons.
        .containerRelativeFrame(.vertical, alignment: .center) { height, _ in max(height - 40, 420) }
    }
}

// MARK: - 2 Permissions

private struct PermissionsStep: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            StepHeader(title: "Allow access", subtitle: "\(AppInfo.displayName) asks only for what dictation needs. You can change these in System Settings at any time.")
            PermissionCard(kind: .microphone, tile: Crystal.Tile.red, symbol: "mic.fill", title: "Microphone",
                           detail: model.settings.settings.transcriptionLocation == .remoteHost
                               ? "Hears you only while you dictate. Audio goes only to your network device."
                               : "Hears you only while you dictate. Audio stays on this Mac.", required: true)
            PermissionCard(kind: .accessibility, tile: Crystal.Tile.blue, symbol: "character.cursor.ibeam", title: "Accessibility",
                           detail: "Types your words into the app you're using. Without it, dictations are copied for you to paste.",
                           required: false)
            if model.settings.settings.fnPushToTalk {
                PermissionCard(kind: .inputMonitoring, tile: Crystal.Tile.gray, symbol: "keyboard.fill", title: "Input Monitoring",
                               detail: "Lets you hold fn to dictate.", required: false)
            }
        }
    }
}

private struct PermissionCard: View {
    var kind: Permissions.Kind
    var tile: Color
    var symbol: String
    var title: String
    var detail: String
    var required: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        let status = model.permissions.status(kind)
        Card(padding: 16) {
            HStack(alignment: .center, spacing: 14) {
                IconTile(symbol, color: tile, size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Crystal.ink)
                        Badge(required ? "Required" : "Optional", style: required ? .accent : .neutral)
                    }
                    Text(detail).font(TypeScale.meta).foregroundStyle(Crystal.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Group {
                    if status.isGranted {
                        Label("Allowed", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(Crystal.ok)
                    } else if kind == .microphone, status == .denied {
                        Button("Open Settings") { model.permissions.openSettings(kind) }
                    } else {
                        Button("Allow") { model.permissions.request(kind) }
                    }
                }
                .frame(minWidth: 96, alignment: .trailing)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 3 Microphone

private struct MicrophoneStep: View {
    @Binding var heard: Bool?
    @Environment(AppModel.self) private var model
    @State private var names: [String] = []

    var body: some View {
        let test = model.micTest
        let check = test.check(permission: AppModel.permission(model.permissions.microphone), deviceCount: names.count)
        VStack(alignment: .leading, spacing: 8) {
            StepHeader(title: "Test your microphone", subtitle: "Say a few words. The waveform should move as you speak.")
            Card(padding: 20) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text("Microphone").font(TypeScale.body).foregroundStyle(Crystal.ink2)
                        Spacer()
                        Picker("Microphone", selection: Binding(get: { model.settings.settings.audioDevice }, set: { v in
                            model.settings.update { $0.audioDevice = v }
                            restart()
                        })) {
                            Text("System default\(Microphones.defaultName().map { " (\($0))" } ?? "")").tag("")
                            ForEach(names, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    LevelBars(meter: test.meter, active: test.running, bars: 44,
                              color: check == .hearing ? Crystal.clientAccent : Crystal.ink2, minHeight: 4)
                        .frame(height: 72)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity)
                        .background(Crystal.well, in: .rect(cornerRadius: 10, style: .continuous))
                    MicCheckLine(check: check, retry: restart)
                }
            }
        }
        .onAppear {
            names = Microphones.names()
            if !AppInfo.isDemo, model.permissions.microphone.isGranted, !model.dictation.phase.isActive { restart() }
        }
        .onDisappear { model.micTest.stop() }
        .onChange(of: check) { _, value in
            if value == .hearing { heard = true } else if value == .silent, heard != true { heard = false }
        }
    }

    private func restart() {
        // Never during a dictation: they share the microphone.
        guard !AppInfo.isDemo, !model.dictation.phase.isActive else { return }
        if model.permissions.microphone.isGranted {
            model.micTest.start(deviceName: model.settings.settings.audioDevice)
        }
    }
}

/// What the microphone test found, and the fix for it.
private struct MicCheckLine: View {
    var check: SetupGuide.MicCheck
    var retry: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).font(.system(size: 15))
            Text(message).font(TypeScale.body).foregroundStyle(Crystal.ink).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            action
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch check {
        case .hearing: "checkmark.circle.fill"
        case .listening, .idle: "waveform"
        default: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch check {
        case .hearing: Crystal.ok
        case .listening, .idle: Crystal.ink2
        default: Crystal.warn
        }
    }

    private var message: String {
        switch check {
        case .idle: "Start the test, then say a few words."
        case .needsPermission: "\(AppInfo.displayName) needs the microphone to hear you."
        case .denied: "Microphone access is turned off for \(AppInfo.displayName)."
        case .noDevice: "No microphone found. Connect one, then try again."
        case .failed(let error): "The microphone wouldn't start: \(error) Choose another, or try again."
        case .listening: "Listening…"
        case .silent: "Nothing heard. Check the microphone isn't muted, or choose another."
        case .hearing: "Sounds good. We can hear you."
        }
    }

    @ViewBuilder private var action: some View {
        switch check {
        case .needsPermission: Button("Allow") { model.permissions.request(.microphone) }
        case .denied: Button("Open Settings") { model.permissions.openSettings(.microphone) }
        case .noDevice, .failed, .silent: Button("Try Again", action: retry)
        case .idle: Button("Start Test", action: retry)
        case .listening, .hearing: EmptyView()
        }
    }
}

// MARK: - 4 Model

private struct ModelStep: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let chosen = SpeechModelCatalog.resolve(model.settings.settings.model).id
        let choices = SetupGuide.modelChoices(from: SpeechModelCatalog.all, defaultID: SpeechModelCatalog.defaultModelID,
                                              including: chosen)
        VStack(alignment: .leading, spacing: 8) {
            StepHeader(title: "Choose a speech model",
                       subtitle: "It runs on this Mac, so nothing you say is uploaded. The recommended model suits most people; you can change it any time in Models.")
            if model.modelProgress == .remote {
                Card(padding: 16) {
                    Label("You're transcribing on a network device, so this Mac needs no model.", systemImage: "server.rack")
                        .font(TypeScale.body).foregroundStyle(Crystal.ink)
                }
            } else {
                // The recommendation first; the alternatives one click away.
                let recommended = choices.filter { $0.id == SpeechModelCatalog.defaultModelID }
                let others = choices.filter { $0.id != SpeechModelCatalog.defaultModelID }
                ForEach(recommended) { info in ModelChoiceCard(info: info, chosen: info.id == chosen) }
                ModelProgressLine()
                    .padding(.vertical, 6)
                SectionHeading("Other models") {
                    Text("All \(SpeechModelCatalog.all.count) are in Models").font(TypeScale.meta).foregroundStyle(Crystal.ink3)
                }
                .padding(.top, 4)
                ForEach(others) { info in ModelChoiceCard(info: info, chosen: info.id == chosen) }
            }
        }
        .onAppear {
            // The chosen model downloads in the background while the person carries on.
            if !AppInfo.isDemo, model.modelProgress == .notStarted { model.useModel(chosen) }
        }
    }
}

private struct ModelChoiceCard: View {
    var info: SpeechModelInfo
    var chosen: Bool
    @Environment(AppModel.self) private var model
    @State private var hovered = false

    var body: some View {
        let state = model.models.state(of: info.id)
        Button {
            model.models.clearDownloadError(info.id)
            model.useModel(info.id)
        } label: {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: chosen ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(chosen ? Crystal.clientAccent : Crystal.ink3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(info.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Crystal.ink)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        if info.id == SpeechModelCatalog.defaultModelID { Badge("Recommended", style: .accent) }
                        if !info.name.contains(info.engine.label) { Badge(info.engine.label) }
                        if info.englishOnly { Badge("EN", style: .outline).help("English only") }
                    }
                    Text(info.summary).font(TypeScale.meta).foregroundStyle(Crystal.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("Speed").font(.system(size: 11)).foregroundStyle(Crystal.ink3)
                        ScoreBar(value: info.speed, label: "Speed")
                    }
                    HStack(spacing: 6) {
                        Text("Accuracy").font(.system(size: 11)).foregroundStyle(Crystal.ink3)
                        ScoreBar(value: info.accuracy, label: "Accuracy")
                    }
                    stateLabel(state)
                }
                .fixedSize()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .cardSurface(tint: chosen ? Crystal.clientAccent : nil, selected: chosen ? Crystal.clientAccent.opacity(0.7) : nil)
        .overlay {
            if hovered && !chosen {
                RoundedRectangle(cornerRadius: CardMetrics.radius, style: .continuous).fill(Crystal.rowHover).allowsHitTesting(false)
            }
        }
        .onHover { hovered = $0 }
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    @ViewBuilder private func stateLabel(_ state: ModelLibrary.ItemState) -> some View {
        Group {
            switch state {
            case .installed: Label("Downloaded", systemImage: "checkmark").foregroundStyle(Crystal.ok)
            case .downloading(let f): Text("Downloading \(Int(f * 100))%").foregroundStyle(Crystal.ink2).monospacedDigit()
            case .unpacking, .compiling: Text("Preparing…").foregroundStyle(Crystal.ink2)
            case .available: Text(Format.bytes(info.approxBytes)).foregroundStyle(Crystal.ink2).monospacedDigit()
            }
        }
        .font(.system(size: 11, weight: .medium))
    }
}

/// The chosen model's download or load, or why it failed.
private struct ModelProgressLine: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let info = SpeechModelCatalog.resolve(model.settings.settings.model)
        switch model.modelProgress {
        case .preparing(let fraction):
            VStack(alignment: .leading, spacing: 6) {
                if let fraction {
                    ProgressView(value: fraction).tint(Crystal.clientAccent)
                } else {
                    ProgressView().progressViewStyle(.linear).tint(Crystal.clientAccent)
                }
                Text(fraction.map { "Downloading \(info.shortName): \(Int($0 * 100))% of \(Format.bytes(info.approxBytes)). You can carry on; it finishes in the background." }
                     ?? "Getting \(info.shortName) ready. You can carry on.")
                    .font(TypeScale.meta).foregroundStyle(Crystal.ink2)
            }
        case .ready:
            Label("\(info.shortName) is ready.", systemImage: "checkmark.circle.fill")
                .font(TypeScale.body).foregroundStyle(Crystal.ok)
        case .failed(let message):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Crystal.error)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(info.shortName) didn't download.").font(.system(size: 13, weight: .semibold)).foregroundStyle(Crystal.ink)
                    Text(message).font(TypeScale.meta).foregroundStyle(Crystal.ink2).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Check your connection and retry, or skip for now and download it later in Models.")
                        .font(TypeScale.meta).foregroundStyle(Crystal.ink2)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Crystal.error.opacity(0.08), in: .rect(cornerRadius: 10, style: .continuous))
        case .notStarted, .remote:
            EmptyView()
        }
    }
}

// MARK: - 5 Shortcut

private struct ShortcutStep: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.settings.settings
        VStack(alignment: .leading, spacing: 12) {
            StepHeader(title: "Your shortcut",
                       subtitle: "Use it in any app to start dictating. Press \(SetupGuide.keyLabel(HotkeyController.cancelShortcutSymbols ?? "⎋")) to cancel.")
            Card(padding: 20) {
                VStack(spacing: 16) {
                    if HotkeyController.hasShortcut {
                        ShortcutCaps(description: HotkeyController.currentShortcutSymbols, large: true)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    } else {
                        Label("No shortcut is set. Record one below.", systemImage: "exclamationmark.triangle.fill")
                            .font(TypeScale.body).foregroundStyle(Crystal.warn)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    HStack {
                        Text("Record a new shortcut").font(TypeScale.body).foregroundStyle(Crystal.ink2)
                        Spacer()
                        KeyboardShortcuts.Recorder(for: .dictation) { _ in model.mirrorShortcut() }
                    }
                }
            }
            HStack(spacing: 8) {
                ModeCard(mode: .pushToTalk, symbol: "hand.point.down.fill", title: "Hold to talk",
                         detail: "Hold the keys while you speak. Let go to insert.")
                ModeCard(mode: .toggle, symbol: "playpause.fill", title: "Press to start and stop",
                         detail: "Press once to start, and again to insert.")
            }
            .fixedSize(horizontal: false, vertical: true)
            Card(padding: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Also hold fn to dictate").font(.system(size: 13, weight: .medium)).foregroundStyle(Crystal.ink)
                            Text(s.fnPushToTalk && model.permissions.inputMonitoring.isGranted ? "Input Monitoring is allowed."
                                 : "Needs Input Monitoring.")
                                .font(TypeScale.meta).foregroundStyle(Crystal.ink2)
                        }
                        Spacer()
                        if s.fnPushToTalk && !model.permissions.inputMonitoring.isGranted {
                            Button("Allow") { model.permissions.request(.inputMonitoring) }
                        }
                        Toggle("Also hold fn to dictate", isOn: Binding(get: { s.fnPushToTalk }, set: { v in
                            model.settings.update { $0.fnPushToTalk = v }
                            if v && !model.permissions.inputMonitoring.isGranted { model.permissions.request(.inputMonitoring) }
                            model.applyFnSetting()
                        }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(Crystal.clientAccent)
                    }
                    if s.fnPushToTalk {
                        if Permissions.globeKeyAction != 0 {
                            Label("fn is set to “\(Permissions.globeKeyActionName)”. Set it to Do Nothing in Keyboard settings.",
                                  systemImage: "exclamationmark.triangle")
                                .font(TypeScale.meta).foregroundStyle(Crystal.warn)
                        }
                    }
                }
            }
        }
    }
}

private struct ModeCard: View {
    var mode: RecordingShortcutMode
    var symbol: String
    var title: String
    var detail: String
    @Environment(AppModel.self) private var model

    var body: some View {
        let selected = model.settings.settings.recordingShortcutMode == mode
        Button {
            model.settings.update { $0.recordingShortcutMode = mode }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    IconTile(symbol, color: selected ? Crystal.clientAccent : Crystal.Tile.gray, size: 28)
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16)).foregroundStyle(selected ? Crystal.clientAccent : Crystal.ink3)
                }
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Crystal.ink)
                Text(detail).font(TypeScale.meta).foregroundStyle(Crystal.ink2).fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .cardSurface(tint: selected ? Crystal.clientAccent : nil, selected: selected ? Crystal.clientAccent.opacity(0.7) : nil)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - 6 Try it

/// A message thread to dictate into. What you say appears as you speak, then lands in the thread
/// as you said it, with how long it took.
private struct TryItStep: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var messages: [Message]
    @State private var draft = ""
    /// The last attempt's failure, kept until the next attempt (the pill's message fades).
    @State private var lastError: String?
    @FocusState private var fieldFocused: Bool

    init(showcase: Bool = false) {
        _messages = State(initialValue: showcase ? Self.showcaseMessages() : [])
    }

    struct Message: Identifiable, Equatable {
        let id = UUID()
        var text: String
        /// Words and release-to-text time, for a dictated message.
        var stats: String?
    }

    var body: some View {
        let mode = model.settings.settings.recordingShortcutMode
        VStack(alignment: .leading, spacing: 8) {
            StepHeader(title: "Try it",
                       subtitle: "Click the message box, then \(mode == .pushToTalk ? "hold" : "press") \(HotkeyController.currentShortcutSymbols) and say something.")
            VStack(spacing: 0) {
                thread
                Hairline()
                composer
            }
            .cardSurface()
            .padding(.bottom, 4)
            if let lastError {
                Label("\(lastError). Try again, or go back to test the microphone.", systemImage: "exclamationmark.triangle.fill")
                    .font(TypeScale.meta).foregroundStyle(Crystal.warn)
                    .padding(.top, 6)
            }
            if case .preparing(let fraction) = model.modelProgress {
                Label(fraction.map { "The model is still downloading (\(Int($0 * 100))%). Dictation starts working when it's done." }
                      ?? "The model is getting ready. Dictation starts working in a moment.", systemImage: "arrow.down.circle")
                    .font(TypeScale.meta).foregroundStyle(Crystal.ink2)
                    .padding(.top, 6)
            }
        }
        .onChange(of: model.dictation.phase) { _, phase in
            switch phase {
            case .failed(let message): lastError = message
            case .listening: lastError = nil
            default: break
            }
        }
        .onChange(of: model.dictation.lastInAppResult) { _, result in
            guard let result else { return }
            draft = ""
            messages.append(Message(text: result.text, stats: "\(result.words) words · \(Format.ms(Double(result.latencyMs))) · on this Mac"))
        }
        .onAppear { if !AppInfo.isDemo { fieldFocused = true } }
    }

    private var thread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Bubble(text: "Try a sentence like “Book a follow-up in ten days and send the letter to Dr Byrne.”", mine: false)
                    ForEach(messages) { message in
                        VStack(alignment: .trailing, spacing: 4) {
                            Bubble(text: message.text, mine: true)
                            if let stats = message.stats {
                                Label(stats, systemImage: "checkmark.circle.fill")
                                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Crystal.ok)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .id(message.id)
                    }
                }
                .padding(16)
            }
            .frame(minHeight: 260, maxHeight: .infinity)
            // Messages sit by the message box, as in any thread.
            .defaultScrollAnchor(.bottom)
            .onChange(of: messages) { _, list in
                if let last = list.last {
                    withAnimation(Motion.unlessReduced(Motion.normal, reduceMotion)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var composer: some View {
        let dictation = model.dictation
        let listening = dictation.phase.isListening
        return HStack(spacing: 10) {
            ZStack(alignment: .leading) {
                TextField("Message", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(TypeScale.body)
                    .lineLimit(1...3)
                    .focused($fieldFocused)
                    .opacity(listening || dictation.phase == .transcribing ? 0 : 1)
                    .onSubmit(send)
                if listening || dictation.phase == .transcribing {
                    HStack(spacing: 8) {
                        if listening {
                            LevelBars(meter: dictation.meter, active: true, bars: 12, color: Crystal.live).frame(width: 52, height: 16)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                        Text(dictation.liveText.isEmpty ? (listening ? "Listening…" : "Transcribing…")
                             : LiveTranscript.displayTail(dictation.liveText, maxCharacters: 70))
                            .font(TypeScale.body)
                            .foregroundStyle(dictation.liveText.isEmpty ? Crystal.ink2 : Crystal.ink)
                            .lineLimit(1).truncationMode(.head)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: 36)
            .background(Crystal.well, in: .rect(cornerRadius: 10, style: .continuous))
            DictateButton(dictation: dictation, size: 32) { dictation.toggleFromUI() }
                .disabled(!model.models.engineState.isReady && model.modelProgress != .remote)
        }
        .padding(12)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        messages.append(Message(text: text, stats: nil))
        draft = ""
    }

    /// Screenshots: a thread with one dictated message.
    static func showcaseMessages() -> [Message] {
        [Message(text: "Book a follow-up in ten days and send the letter to Dr Byrne.", stats: "13 words · 71 ms · on this Mac")]
    }
}

private struct Bubble: View {
    var text: String
    var mine: Bool

    var body: some View {
        Text(text)
            .font(TypeScale.body)
            .foregroundStyle(mine ? Crystal.onAccent : Crystal.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(mine ? Crystal.clientAccent : Crystal.well, in: .rect(cornerRadius: 14, style: .continuous))
            .frame(maxWidth: 420, alignment: mine ? .trailing : .leading)
            .textSelection(.enabled)
    }
}

// MARK: - 7 Finish

/// A live checklist: what is set up, what isn't, and the fix for each.
private struct FinishStep: View {
    var micHeard: Bool?
    var go: (SetupGuide.Step) -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        let items = model.setupChecklist(micHeard: micHeard)
        let ready = SetupGuide.isReady(items)
        VStack(alignment: .leading, spacing: 8) {
            StepHeader(title: ready ? "You're all set" : "Almost there",
                       subtitle: ready
                           ? "\(model.settings.settings.recordingShortcutMode == .pushToTalk ? "Hold" : "Press") \(HotkeyController.currentShortcutSymbols) in any app to dictate. \(AppInfo.displayName) lives in the menu bar."
                           : "\(AppInfo.displayName) can't dictate until the items marked below are done.")
            Card(padding: 6) {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Hairline(inset: 48) }
                        ChecklistRow(item: item, go: go)
                    }
                }
            }
            Text("To keep recordings for training a model on your voice, turn on “Save recordings to improve models” in Settings › General.")
                .font(TypeScale.meta).foregroundStyle(Crystal.ink3)
                .padding(.top, 8)
        }
    }
}

private struct ChecklistRow: View {
    var item: SetupGuide.ChecklistItem
    var go: (SetupGuide.Step) -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(tint).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Crystal.ink)
                    if !item.required { Badge("Optional") }
                }
                Text(detail).font(TypeScale.meta).foregroundStyle(Crystal.ink2).lineLimit(2)
            }
            Spacer(minLength: 8)
            fix
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch item.kind {
        case .microphone: "Microphone allowed"
        case .model: "Speech model ready"
        case .accessibility: "Types into apps"
        case .micHeard: "Microphone tested"
        }
    }

    private var detail: String {
        switch item.state {
        case .done:
            switch item.kind {
            case .microphone: "Heard only while you dictate"
            case .model: model.modelProgress == .remote ? "Transcribing on your network device"
                : "\(SpeechModelCatalog.resolve(model.settings.settings.model).shortName) on this Mac"
            case .accessibility: "Your words go where you type"
            case .micHeard: "We heard you"
            }
        case .pending(let text), .problem(let text): text
        }
    }

    private var symbol: String {
        switch item.state {
        case .done: "checkmark.circle.fill"
        case .pending: item.required ? "circle.dashed" : "minus.circle"
        case .problem: "exclamationmark.circle.fill"
        }
    }

    private var tint: Color {
        switch item.state {
        case .done: Crystal.ok
        case .pending: item.required ? Crystal.warn : Crystal.ink3
        case .problem: Crystal.error
        }
    }

    @ViewBuilder private var fix: some View {
        if !item.isDone {
            switch item.kind {
            case .microphone:
                if model.permissions.microphone == .denied {
                    Button("Open Settings") { model.permissions.openSettings(.microphone) }
                } else {
                    Button("Allow") { model.permissions.request(.microphone) }
                }
            case .model:
                if case .preparing = model.modelProgress {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Fix") { go(.model) }
                }
            case .accessibility: Button("Allow") { model.permissions.request(.accessibility) }
            case .micHeard: Button("Test") { go(.microphone) }
            }
        }
    }
}
