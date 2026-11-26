import FairspokenCore
import FairspokenUI
import FairspokenUpdates
import KeyboardShortcuts
import SwiftUI

// MARK: - General

/// The shortcut, the microphone, what happens when you stop speaking, startup, permissions and
/// the recordings kept for post-training.
enum GeneralSettings {
    typealias Row = SettingsCatalog.Row
    typealias Section = SettingsCatalog.Section

    @MainActor
    static func sections(_ model: AppModel) -> [Section] {
        let s = model.settings.settings
        var shortcut: [Row] = [
            Row("Dictation shortcut", detail: "Press it in any app to start dictating. Esc cancels a recording.",
                keywords: "hotkey keyboard key record") {
                KeyboardShortcuts.Recorder(for: .dictation) { _ in model.mirrorShortcut() }
            },
            Row("Shortcut mode", detail: s.recordingShortcutMode == .toggle
                ? "Press once to start and again to stop."
                : "Hold the shortcut while you speak; let go to finish.",
                keywords: "toggle push to talk hold press") {
                SegmentedChoice("Shortcut mode", selection: Binding(get: { s.recordingShortcutMode },
                                                                    set: { v in model.settings.update { $0.recordingShortcutMode = v } }),
                                options: [.init(.toggle, "Press to start and stop"), .init(.pushToTalk, "Hold to talk")])
            },
            Row("Hold fn to dictate", detail: "Hold the fn (globe) key and speak; let go and Bark types it.",
                keywords: "globe function key push to talk") {
                SettingSwitch(label: "Hold fn to dictate", isOn: Binding(get: { s.fnPushToTalk }, set: { v in
                    model.settings.update { $0.fnPushToTalk = v }
                    if v && !model.permissions.inputMonitoring.isGranted { model.permissions.request(.inputMonitoring) }
                    model.applyFnSetting()
                }))
            },
        ]
        if s.fnPushToTalk && Permissions.globeKeyAction != 0 {
            shortcut.append(Row(id: "globe-warning", searchText: "globe fn key keyboard settings",
                                view: GlobeKeyWarning()))
        }

        return [
            Section("Shortcut", rows: shortcut),
            Section("Microphone", rows: [
                Row(id: "microphone", searchText: "Microphone input device audio mic",
                    view: MicrophoneRow()),
                Row(id: "level", searchText: "Level test microphone input meter audio",
                    view: MicLevelRow()),
                Row("Longest recording", detail: "A recording stops on its own after this long.",
                    keywords: "maximum length duration limit audio") {
                    ValueStepper(value: Binding(get: { s.maxRecordingSeconds }, set: { v in model.settings.update { $0.maxRecordingSeconds = v } }),
                                 range: 10...600, step: 10, label: "Longest recording") { Format.duration(Double($0)) }
                },
            ]),
            Section("When you stop speaking", rows: [
                Row("Paste into the current app",
                    detail: "Types where your cursor is. Never into a password field; with no text field, it goes on the clipboard.",
                    keywords: "insert cursor command v accessibility") {
                    SettingSwitch(label: "Paste into the current app", isOn: model.setting(\.insertAtCursor))
                },
                Row("Restore the clipboard afterwards", detail: "Puts back what you had copied before the dictation.",
                    keywords: "pasteboard copy") {
                    SettingSwitch(label: "Restore the clipboard afterwards", isOn: model.setting(\.restoreClipboard))
                        .disabled(!s.insertAtCursor)
                },
                Row("Show text while speaking",
                    detail: "The recording pill shows your words as you say them. Not available with Bark Server.",
                    keywords: "live transcript pill preview words") {
                    SettingSwitch(label: "Show text while speaking", isOn: model.setting(\.showTextWhileSpeaking))
                },
                Row("Start and stop sounds", detail: "A soft click as recording starts and ends.",
                    keywords: "audio feedback chime sound") {
                    SettingSwitch(label: "Start and stop sounds", isOn: model.setting(\.interactionSounds))
                },
            ]),
            Section("Startup", rows: [
                Row(id: "login", searchText: "Launch at login start open when you log in startup", view: LaunchAtLoginRow()),
            ]),
            Section("Permissions", rows: [
                Row(id: "perm-mic", searchText: "Permissions Microphone allow privacy", view: PermissionRow(kind: .microphone)),
                Row(id: "perm-ax", searchText: "Permissions Accessibility allow type paste privacy", view: PermissionRow(kind: .accessibility)),
                Row(id: "perm-input", searchText: "Permissions Input Monitoring fn globe allow privacy",
                    view: PermissionRow(kind: .inputMonitoring, optional: !s.fnPushToTalk)),
                Row("Setup guide", detail: "Walk through permissions, the model and a first dictation again.",
                    keywords: "onboarding welcome tutorial") {
                    Button("Open Setup Guide…") { model.openOnboarding?() }.cardButton()
                },
            ]),
            Section("Post-training recordings", rows: [
                Row("Save recordings to improve models",
                    detail: "Keeps each dictation's audio and text on this Mac, for training a model on your voice. Nothing is uploaded.",
                    keywords: "training capture audio keep voice") {
                    SettingSwitch(label: "Save recordings to improve models", isOn: model.setting(\.trainingCapture))
                },
                Row(id: "saved-to", searchText: "Saved to folder recordings training data location",
                    view: SettingsRow("Saved to", detail: model.training.folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                                      mono: true) {
                        Button("Review Recordings") { model.section = .training }.cardButton()
                            .help("Choose the folder and review recordings in Post-training")
                    }),
            ]),
        ]
    }
}

/// The microphone dictation listens on.
private struct MicrophoneRow: View {
    @Environment(AppModel.self) private var model
    @State private var names: [String] = []

    var body: some View {
        let current = model.settings.settings.audioDevice
        SettingsRow("Microphone", detail: "Bark listens on this one only while you dictate.") {
            SelectMenu(Microphones.displayName(for: current), label: "Microphone", minWidth: 200) {
                Picker("Microphone", selection: Binding(get: { current }, set: { v in model.settings.update { $0.audioDevice = v } })) {
                    Text("System default\(Microphones.defaultName().map { " (\($0))" } ?? "")").tag("")
                    ForEach(names, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.inline)
            }
        }
        .onAppear { names = Microphones.names() }
    }
}

/// The level meter with a test that listens until stopped.
private struct MicLevelRow: View {
    @Environment(AppModel.self) private var model
    @State private var testing = false

    var body: some View {
        let live = testing || model.dictation.phase.isListening
        SettingsRow("Level", detail: testing ? "Speak as you would to dictate. The bars should reach past halfway."
                                             : "Test the microphone without dictating.") {
            LevelBars(meter: model.dictation.meter, active: live, bars: 24, color: Crystal.primary)
                .frame(width: 140, height: 18)
                .accessibilityHidden(true)
            Button(testing ? "Stop" : "Test") { toggle() }
                .cardButton()
                .disabled(model.dictation.phase.isActive && !testing)
        }
        .onDisappear { if testing { toggle() } }
    }

    private func toggle() {
        if testing {
            model.dictation.capture.stop()
            testing = false
        } else if model.permissions.microphone.isGranted {
            do {
                try model.dictation.capture.start(deviceName: model.settings.settings.audioDevice, maxSeconds: 30, sink: nil)
                testing = true
            } catch {
                testing = false
            }
        } else {
            model.permissions.request(.microphone)
        }
    }
}

/// "Launch at login" through SMAppService, read back from the system each time it changes.
private struct LaunchAtLoginRow: View {
    @State private var enabled = LoginItem.isEnabled
    @State private var needsApproval = LoginItem.needsApproval
    @State private var error: String?

    var body: some View {
        SettingsRow("Launch at login",
                    detail: error ?? (needsApproval ? "Waiting for approval in System Settings › General › Login Items."
                                                    : "Bark opens in the menu bar when you log in, ready to dictate.")) {
            if needsApproval {
                Button("Open Login Items") { LoginItem.openSystemSettings() }.cardButton()
            }
            SettingSwitch(label: "Launch at login", isOn: Binding(get: { enabled }, set: { v in
                do {
                    try LoginItem.set(v)
                    error = nil
                } catch {
                    self.error = "Couldn't change it: \(error.localizedDescription)"
                }
                enabled = LoginItem.isEnabled
                needsApproval = LoginItem.needsApproval
            }))
        }
    }
}

/// fn is set to do something else in Keyboard settings.
private struct GlobeKeyWarning: View {
    var body: some View {
        SettingsRow("fn is set to “\(Permissions.globeKeyActionName)”",
                    detail: "Set “Press fn key to” to Do Nothing, or holding fn will do both.") {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Crystal.warn).accessibilityHidden(true)
        } control: {
            Button("Keyboard Settings…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") { NSWorkspace.shared.open(url) }
            }
            .cardButton()
        }
    }
}

// MARK: - History

/// How much history is kept, and deleting it.
enum HistorySettings {
    typealias Row = SettingsCatalog.Row
    typealias Section = SettingsCatalog.Section

    @MainActor
    static func sections(_ model: AppModel) -> [Section] {
        let history = model.history
        let notes = history.items.filter(\.isBarkNote).count
        let dictations = history.items.count - notes
        return [
            Section("Keep", rows: [
                Row(id: "keep", searchText: "Keep the last retention limit cap history count older removed", view: RetentionRow()),
                Row("On this Mac",
                    detail: "\(Format.number(dictations)) dictation\(dictations == 1 ? "" : "s") and \(Format.number(notes)) note\(notes == 1 ? "" : "s"), in transcript-history.json.",
                    keywords: "file storage disk folder") {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([history.historyURL]) }.cardButton()
                },
            ]),
            Section("Delete", rows: [
                Row(id: "delete-all", searchText: "Delete all dictations notes clear erase history remove", view: DeleteAllRow()),
            ]),
        ]
    }
}

/// How many to keep. A smaller number that would remove dictations at once asks first.
private struct RetentionRow: View {
    @Environment(AppModel.self) private var model
    @State private var pending: Int?

    var body: some View {
        let history = model.history
        SettingsRow("Keep the last", detail: "Older dictations and notes are removed as new ones arrive. Your usage stats are kept either way.") {
            SelectMenu("\(Format.number(history.retentionLimit)) dictations", label: "Keep the last", minWidth: 150) {
                Picker("Keep the last", selection: Binding(get: { history.retentionLimit }, set: { limit in
                    if history.items.count > limit { pending = limit } else { history.setRetentionLimit(limit) }
                })) {
                    ForEach(HistoryStore.retentionChoices, id: \.self) { Text("\(Format.number($0)) dictations").tag($0) }
                }
                .pickerStyle(.inline)
            }
        }
        .confirmationDialog("Remove the \(Format.number(max(0, history.items.count - (pending ?? 0)))) oldest dictations and notes?",
                            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            presenting: pending) { limit in
            Button("Keep the Last \(Format.number(limit))", role: .destructive) { history.setRetentionLimit(limit) }
        } message: { _ in
            Text("They are removed from this Mac now. This can't be undone.")
        }
    }
}

private struct DeleteAllRow: View {
    @Environment(AppModel.self) private var model
    @State private var confirm = false

    var body: some View {
        let count = model.history.items.count
        SettingsRow("Delete all dictations and notes", detail: "Their text is removed from this Mac. Usage stats and any kept recordings stay.") {
            Button("Delete All…", role: .destructive) { confirm = true }
                .cardButton()
                .foregroundStyle(Crystal.error)
                .disabled(count == 0)
        }
        .confirmationDialog("Delete all \(count) dictations and notes?", isPresented: $confirm) {
            Button("Delete All", role: .destructive) {
                model.open(dictation: nil)
                model.section = .settings
                model.history.deleteAll()
            }
        } message: {
            Text("This can't be undone.")
        }
    }
}

// MARK: - Updates

enum UpdatesSettings {
    typealias Row = SettingsCatalog.Row
    typealias Section = SettingsCatalog.Section

    @MainActor
    static func sections(_ model: AppModel) -> [Section] {
        let updates = model.updates
        return [
            Section("This version", footer: "Bark checks every 6 hours and asks before installing. Only updates signed by Bark install.", rows: [
                Row(id: "status", searchText: "Updates status check install new version", view: UpdateStatusRow()),
                Row("Current version", detail: nil, keywords: "build number") {
                    Text("\(updates.currentVersion) (\(updates.build))")
                        .font(.mono(12)).foregroundStyle(Crystal.ink2).textSelection(.enabled)
                },
                Row("Channel", detail: updates.channel.explanation + (updates.showsMoveToStableNote ? " You'll move to Stable with the next stable release." : ""),
                    keywords: "nightly stable beta release") {
                    SegmentedChoice("Update channel", selection: Binding(get: { updates.channel }, set: { updates.setChannel($0) }),
                                    options: UpdateChannel.allCases.map { .init($0, $0.title) })
                },
                Row("Last checked", detail: nil, keywords: "updates") {
                    Text(updates.lastChecked.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never")
                        .font(.system(size: 13)).foregroundStyle(Crystal.ink2)
                },
            ]),
        ]
    }
}

private struct UpdateStatusRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let updates = model.updates
        let p = updates.presentation
        HStack(spacing: 12) {
            UpdateGlyph(presentation: p, style: .client, size: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(p.title).font(.system(size: 14, weight: .medium)).foregroundStyle(Crystal.ink)
                Text(p.detail).font(.system(size: 12)).foregroundStyle(Crystal.ink2).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(p.accessibilityLabel)
            switch updates.state {
            case .available(let version):
                Button("Install \(version)") { updates.installUpdate() }.buttonStyle(PrimaryButtonStyle())
            case .ready:
                Button("Restart to Update") { updates.relaunchToUpdate() }.buttonStyle(PrimaryButtonStyle())
            default:
                EmptyView()
            }
            Button(updates.state == .checking ? "Checking…" : "Check Now") { updates.checkForUpdates() }
                .cardButton()
                .disabled(updates.state == .checking || updates.state.primaryAction == .none)
        }
        .padding(.horizontal, SettingsMetrics.rowH)
        .padding(.vertical, SettingsMetrics.rowV)
    }
}

// MARK: - About

enum AboutSettings {
    typealias Row = SettingsCatalog.Row
    typealias Section = SettingsCatalog.Section

    @MainActor
    static func sections(_ model: AppModel) -> [Section] {
        let limit = Format.number(model.history.retentionLimit)
        return [
            .custom("about-header", AboutHeader()),
            Section("Details", rows: [
                Row("Bundle identifier", keywords: "about id") {
                    Text(AppInfo.bundleID).font(.mono(12)).foregroundStyle(Crystal.ink2).textSelection(.enabled)
                },
                Row("Speech engines", detail: "Parakeet through FluidAudio and Whisper through WhisperKit, on the Neural Engine.",
                    keywords: "about coreml fluidaudio whisperkit") {
                    EmptyView()
                },
                Row("Settings folder", detail: AppInfo.supportDirectory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                    keywords: "about files support directory") {
                    Button("Show in Finder") { NSWorkspace.shared.open(AppInfo.supportDirectory) }.cardButton()
                },
            ]),
            Section("Privacy", rows: [
                Row(id: "privacy", searchText: "Privacy audio data uploaded network",
                    view: Text("Audio stays in memory and is never saved, unless you turn on Save recordings to improve models. Your last \(limit) dictations stay on this Mac. With Bark Server, audio goes to that server only. To learn from your corrections, the text around a dictation is read again after you edit it, and only the corrected words are kept.")
                        .font(.system(size: 13))
                        .lineSpacing(3)
                        .foregroundStyle(Crystal.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, SettingsMetrics.rowH)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity, alignment: .leading)),
            ]),
        ]
    }
}

private struct AboutHeader: View {
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Crystal.canvas)
                .frame(width: 48, height: 48)
                .background(Crystal.ink, in: .rect(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(AppInfo.displayName).font(.system(size: 22, weight: .semibold)).tracking(-0.33).foregroundStyle(Crystal.ink)
                Text("Version \(AppInfo.version) (\(AppInfo.build))\(AppInfo.isDevBuild ? " · development build" : "")")
                    .font(.system(size: 13)).foregroundStyle(Crystal.ink2).textSelection(.enabled)
            }
            Spacer()
        }
        .padding(.horizontal, SettingsMetrics.rowH)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
