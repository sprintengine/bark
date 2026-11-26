import FairspokenCore
import FairspokenSpeech
import FairspokenUI
import SwiftUI

// MARK: - Transcription

/// Where Bark listens, the model, and cleanup.
enum TranscriptionSettings {
    typealias Row = SettingsCatalog.Row
    typealias Section = SettingsCatalog.Section

    @MainActor
    static func sections(_ model: AppModel) -> [Section] {
        let s = model.settings.settings
        let remote = s.transcriptionLocation == .remoteHost
        var listens: [Row] = [
            Row("Transcribe on", detail: remote ? "Audio goes to your Bark Server and nowhere else."
                                                : "Audio never leaves this Mac unless you choose your Bark Server.",
                keywords: "location local remote host network device this mac server") {
                SegmentedChoice("Transcribe on", selection: Binding(get: { remote ? TranscriptionLocation.remoteHost : .local }, set: { v in
                    model.settings.update { $0.transcriptionLocation = v }
                    if v == .local { model.models.use(model.settings.settings.model) } else { model.hostStatus.refresh(force: true) }
                }), options: [.init(.local, "This Mac", symbol: "laptopcomputer"), .init(.remoteHost, "Bark Server", symbol: "server.rack")])
            },
        ]
        if remote || !s.remoteUrl.isEmpty {
            listens.append(Row(id: "server", searchText: "Bark Server host test reachable address",
                               view: ServerSummaryRow()))
        }
        var sections = [
            Section("Where Bark listens", rows: listens),
            Section("Model", trailing: AnyView(
                Button {
                    model.section = .models
                } label: {
                    HStack(spacing: 4) {
                        Text("Browse models")
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    }
                }
                .buttonStyle(GhostButtonStyle())
                .help("All models, in Models")),
                    rows: ModelChoices.ids(model).map { id in
                        Row(id: "model-\(id)", searchText: "Model speech recognition \(SpeechModelCatalog.resolve(id).name) \(SpeechModelCatalog.resolve(id).summary)",
                            view: ModelChoiceRow(id: id))
                    }),
        ]
        sections.append(contentsOf: cleanupSections(model))
        return sections
    }

    /// Cleanup: what it takes out, each switch with one line and a worked example. Verbatim never
    /// cleans up, whatever these say.
    @MainActor
    static func cleanupSections(_ model: AppModel) -> [Section] {
        [Section("Cleanup", footer: "Cleanup never guesses: when it isn't sure, it leaves your words as they were. The Verbatim style skips it.",
                 trailing: AnyView(CleanupResetButton()), rows: [
            Row(id: "cleanup-fillers", searchText: "Remove filler words um uh er you know like repeats stutters cleanup",
                view: CleanupRow(title: "Remove filler words",
                                 detail: "Drops “um”, “uh” and “er”, and “you know” or “like” when they are filler, not meaning. Stutters and repeated words go too.",
                                 key: \.cleanupFillers,
                                 example: [.removed("Um,"), .plain("can we"), .removed("the the"), .plain("meet at ten?")])),
            Row(id: "cleanup-corrections", searchText: "Fix self-corrections no wait sorry I mean scratch that actually restart cleanup",
                view: CleanupRow(title: "Fix self-corrections",
                                 detail: "Keeps what you meant when you change your mind mid-sentence: “no wait”, “sorry”, “I mean”, “scratch that”.",
                                 key: \.cleanupSelfCorrections,
                                 example: [.plain("by"), .removed("Thursday, no wait,"), .added("Friday")])),
            Row(id: "cleanup-commands", searchText: "Spoken commands smart punctuation new line new paragraph comma full stop question mark cleanup",
                view: CleanupRow(title: "Spoken commands and smart punctuation",
                                 detail: "Say “comma”, “full stop”, “new line” or “new paragraph” and get the mark; stray full stops and capitals are tidied.",
                                 key: \.cleanupSpokenCommands,
                                 example: [.plain("thanks"), .removed("comma new line"), .added(",⏎"), .plain("Sam")])),
        ])]
    }
}

/// One cleanup switch with its example.
private struct CleanupRow: View {
    var title: String
    var detail: String
    var key: WritableKeyPath<AppSettings, Bool>
    var example: [ExampleChip.Part]
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsRow(title, detail: detail, accessory: { EmptyView() }, below: {
            ExampleChip(example).opacity(model.settings.settings[keyPath: key] ? 1 : 0.55)
        }, control: {
            SettingSwitch(label: title, isOn: model.setting(key))
        })
    }
}

/// Turns every cleanup switch back on.
private struct CleanupResetButton: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let s = model.settings.settings
        let changed = !(s.cleanupFillers && s.cleanupSelfCorrections && s.cleanupSpokenCommands)
        if changed {
            Button {
                model.settings.update { $0.cleanupSettings = .all }
            } label: {
                Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(GhostButtonStyle())
        }
    }
}

/// The Bark Server in use: its address, whether it answers, Test and Change.
private struct ServerSummaryRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let status = model.hostStatus
        SettingsRow("Bark Server", detail: model.settings.settings.remoteUrl.isEmpty ? "None chosen yet." : status.hostName,
                    mono: !model.settings.settings.remoteUrl.isEmpty) {
            if !model.settings.settings.remoteUrl.isEmpty { HostStateBadge(status: status) }
        } control: {
            if !model.settings.settings.remoteUrl.isEmpty {
                Button(status.state == .checking ? "Testing…" : "Test") { status.refresh(force: true) }
                    .cardButton()
                    .disabled(status.state == .checking)
            }
            Button(model.settings.settings.remoteUrl.isEmpty ? "Choose…" : "Change…") { model.settingsTab = .host }.cardButton()
        }
        // Configured but not in use: nothing else asks it, so ask once here (answers are kept 20 s).
        .onAppear { status.refresh() }
    }
}

/// "Reachable", "Checking…", "Not reachable".
struct HostStateBadge: View {
    var status: HostStatus
    var body: some View {
        switch status.state {
        case .connected: Badge("Reachable", style: .info)
        case .checking: Badge("Checking…")
        case .failed: Badge("Not reachable", style: .error)
        case .notConfigured: Badge("Not set")
        }
    }
}

/// The models offered on Transcription: the one in use, the others on this Mac, then the
/// recommended ones not yet downloaded. Five at most; the rest are in Models.
enum ModelChoices {
    @MainActor
    static func ids(_ model: AppModel) -> [String] {
        let chosen = SpeechModelCatalog.resolve(model.settings.settings.model).id
        var ids = [chosen]
        for info in SpeechModelCatalog.all where info.id != chosen && model.models.state(of: info.id) == .installed { ids.append(info.id) }
        for info in SpeechModelCatalog.all where info.isRecommended && !ids.contains(info.id) { ids.append(info.id) }
        return Array(ids.prefix(5))
    }
}

/// One model: a radio, its name and state, a line about it, and its size.
private struct ModelChoiceRow: View {
    var id: String
    @Environment(AppModel.self) private var model
    @State private var hovered = false

    var body: some View {
        let info = SpeechModelCatalog.resolve(id)
        let chosen = SpeechModelCatalog.resolve(model.settings.settings.model).id == id
        let item = model.models.state(of: id)
        Button {
            model.useModel(id)
        } label: {
            HStack(alignment: .center, spacing: 14) {
                RadioMark(on: chosen)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(info.name).font(.system(size: 14, weight: .medium)).foregroundStyle(Crystal.ink)
                        badge(info: info, chosen: chosen, item: item)
                    }
                    Text(info.summary)
                        .font(.system(size: 12)).foregroundStyle(Crystal.ink2)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(Format.bytes(info.approxBytes))
                    Text(item == .installed ? "this Mac" : "download")
                }
                .font(.mono(12))
                .foregroundStyle(Crystal.ink3)
            }
            .padding(.horizontal, SettingsMetrics.rowH)
            .padding(.vertical, 12)
            .background(hovered ? Crystal.rowHover : .clear)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(info.name). \(info.summary)")
        .accessibilityValue(chosen ? "Chosen" : "")
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder private func badge(info: SpeechModelInfo, chosen: Bool, item: ModelLibrary.ItemState) -> some View {
        if chosen, model.settings.settings.transcriptionLocation == .local {
            let state = model.models.engineState
            if state.isReady { Badge("Ready") } else if case .failed = state { Badge("Failed", style: .error) } else { Badge(state.label) }
        } else if case .downloading(let f) = item {
            Badge("Downloading \(Int(f * 100))%", style: .info)
        } else if info.isRecommended {
            Badge("Recommended", style: .info)
        }
    }
}

// MARK: - Bark Server

/// The server in use, servers found on the network, and entering one by hand.
enum HostSettings {
    typealias Row = SettingsCatalog.Row
    typealias Section = SettingsCatalog.Section

    @MainActor
    static func sections(_ model: AppModel) -> [Section] {
        let s = model.settings.settings
        let finder = model.hostFinder
        let hosts = finder.hosts.filter(\.isThisMac) + finder.hosts.filter { !$0.isThisMac }
        var current: [Row] = [
            Row("Use Bark Server for dictation", detail: "Off, Bark transcribes on this Mac. You can switch in Transcription too.",
                keywords: "network device remote host location") {
                SettingSwitch(label: "Use Bark Server for dictation", isOn: Binding(get: { s.transcriptionLocation == .remoteHost }, set: { on in
                    model.settings.update { $0.transcriptionLocation = on ? .remoteHost : .local }
                    if on { model.hostStatus.refresh(force: true) } else { model.models.use(model.settings.settings.model) }
                }))
            },
        ]
        if !s.remoteUrl.isEmpty {
            current.append(Row(id: "current-host", searchText: "Bark Server current host address test status connected",
                               view: CurrentHostRow()))
        }
        var found: [Row] = hosts.map { host in
            Row(id: "host-\(host.id)", searchText: "Bark Server host found network \(host.name) \(host.machine)",
                view: DiscoveredHostRow(host: host, inUse: s.remoteUrl == host.url.absoluteString,
                                        pairing: finder.pairing?.id == host.id))
        }
        if found.isEmpty || finder.scan != .done {
            found.append(Row(id: "scan-status", searchText: "Find hosts scan search network Tailscale", view: ScanStatusRow()))
        }
        return [
            Section("Your server", rows: current),
            Section("On your network", trailing: AnyView(FindHostsButton()), rows: found),
            Section("Enter it yourself",
                    footer: "HTTPS is required beyond this Mac, your local network and your Tailscale network. The token is kept in your Keychain.",
                    rows: [
                        Row(id: "machine", searchText: "Machine name look up host manual address", view: MachineLookupRow()),
                        Row(id: "address", searchText: "Address URL host manual", view: AddressRow()),
                        Row(id: "token", searchText: "Token password secret key manual", view: TokenRow()),
                        Row("Timeout", detail: "How long to wait for the server before keeping the recording to try again.",
                            keywords: "seconds wait network") {
                            ValueStepper(value: Binding(get: { s.remoteTimeoutSeconds }, set: { v in model.settings.update { $0.remoteTimeoutSeconds = v } }),
                                         range: 5...300, step: 5, label: "Timeout") { "\($0) s" }
                        },
                    ]),
        ]
    }
}

private struct FindHostsButton: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let searching = model.hostFinder.scan == .searching
        HStack(spacing: 8) {
            if searching { ProgressView().controlSize(.small) }
            Button(searching ? "Searching…" : "Find Servers") { model.hostFinder.findHosts() }
                .cardButton()
                .disabled(searching)
        }
        .onAppear {
            if model.hostFinder.scan == .idle && AppInfo.screenshotDirectory == nil { model.hostFinder.findHosts() }
        }
    }
}

private struct ScanStatusRow: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let finder = model.hostFinder
        let (title, detail): (String, String) = switch finder.scan {
        case .idle: ("Not searched yet", "Find Servers looks for Bark Server on your Tailscale network.")
        case .searching: ("Searching your Tailscale network…", "Servers appear here as they answer.")
        case .failed(let message): ("Couldn't search", message)
        case .done: ("None found", "Nothing answered on your Tailscale network. On another port? Enter its address below.")
        }
        SettingsRow(title, detail: detail)
    }
}

/// The server in use: its address, whether it answers, and Test.
private struct CurrentHostRow: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let status = model.hostStatus
        SettingsRow(status.hostName, detail: [status.stateLabel, status.detail].compactMap { $0 }.joined(separator: " · ")) {
            HostStateBadge(status: status)
        } control: {
            Button(status.state == .checking ? "Testing…" : "Test") { status.refresh(force: true) }
                .cardButton()
                .disabled(status.state == .checking)
        }
        .onAppear { status.refresh() }
    }
}

/// One server that answered. Choosing one with a password opens the password field in place.
private struct DiscoveredHostRow: View {
    var host: DiscoveredHost
    var inUse: Bool
    var pairing: Bool
    @Environment(AppModel.self) private var model
    @State private var password = ""
    @FocusState private var focused: Bool

    var body: some View {
        let finder = model.hostFinder
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(host.name, detail: host.isThisMac ? "This Mac" : host.machine) {
                if host.auth == .password {
                    Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(Crystal.ink3)
                        .accessibilityLabel("Needs a password")
                }
            } control: {
                if inUse {
                    Label("In use", systemImage: "checkmark").font(.system(size: 13, weight: .medium)).foregroundStyle(Crystal.ink2)
                } else if !pairing {
                    Button(host.auth == .password ? "Pair…" : "Use") { finder.choose(host) }.cardButton()
                }
            }
            .help(host.url.absoluteString)
            if pairing {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        SecureField("Password", text: $password, prompt: Text("Password set on \(host.machine)"))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .focused($focused)
                            .onSubmit(pair)
                            .frame(maxWidth: 280)
                        if finder.pairingBusy { ProgressView().controlSize(.small) }
                        Button("Cancel") { finder.cancelPairing() }.cardButton().keyboardShortcut(.cancelAction)
                        Button("Pair", action: pair).buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction).disabled(!canPair)
                    }
                    if let error = finder.pairingError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12)).foregroundStyle(Crystal.error)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, SettingsMetrics.rowH)
                .padding(.bottom, 12)
            }
        }
        .onChange(of: pairing, initial: true) { _, on in
            if on { password = ""; focused = true }
        }
    }

    /// Pairing passwords are 6–128 characters.
    private var canPair: Bool { (6...128).contains(password.count) && !model.hostFinder.pairingBusy }

    private func pair() {
        guard canPair else { return }
        model.hostFinder.pair(password: password)
    }
}

/// A text field in a settings row, at a fixed width.
private struct RowField: View {
    var label: String
    @Binding var text: String
    var prompt: String
    var secure = false
    var width: CGFloat = 260
    var focusRequest = 0
    var onSubmit: () -> Void = {}

    var body: some View {
        SettingsTextField(label, text: $text, prompt: prompt, secure: secure, focusRequest: focusRequest, onSubmit: onSubmit)
            .frame(width: width)
    }
}

private struct MachineLookupRow: View {
    @Environment(AppModel.self) private var model
    @State private var machine = ""

    var body: some View {
        let finder = model.hostFinder
        SettingsRow("Machine name", detail: finder.lookupError ?? "Its name on your network; Bark finds the address.") {
            RowField(label: "Machine name", text: $machine, prompt: "studio-mac or studio-mac:48173", width: 220, onSubmit: lookUp)
            Button(finder.lookingUp ? "Looking…" : "Look Up", action: lookUp)
                .cardButton()
                .disabled(finder.lookingUp || machine.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func lookUp() {
        let entry = machine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entry.isEmpty else { return }
        model.hostFinder.lookUp(entry)
    }
}

private struct AddressRow: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        SettingsRow("Address", detail: "The server's address, with its port.") {
            RowField(label: "Address", text: Binding(get: { model.settings.settings.remoteUrl },
                                                     set: { v in model.settings.update { $0.remoteUrl = v } }),
                     prompt: "http://practice-mini.local:48173") { model.hostStatus.refresh(force: true) }
        }
    }
}

private struct TokenRow: View {
    @Environment(AppModel.self) private var model
    @State private var token = ""
    @State private var focusRequest = 0

    var body: some View {
        let finder = model.hostFinder
        let waiting = finder.needsToken.map { $0.url.absoluteString == model.settings.settings.remoteUrl && token.isEmpty } ?? false
        SettingsRow("Token", detail: waiting ? "\(finder.needsToken?.name ?? "This server") needs its token." : "From Bark Server › Connect, on the server.") {
            RowField(label: "Token", text: $token, prompt: "Paste the token", secure: true, focusRequest: focusRequest) {
                model.settings.remoteToken = token
                model.hostStatus.refresh(force: true)
            }
        }
        .onAppear { token = model.settings.remoteToken }
        .onChange(of: token) { _, v in model.settings.remoteToken = v }
        // Pairing writes the token; show it here too.
        .onChange(of: model.settings.remoteToken) { _, v in if token != v { token = v } }
        // A server that needs its token: the field waits for it.
        .onChange(of: finder.needsToken) { _, host in if host != nil { focusRequest += 1 } }
    }
}
