import FairspokenCore
import FairspokenHost
import FairspokenUI
import FairspokenUpdates
import SwiftUI

/// Edits host-config.json. Limits, the accelerator, model assignments and the name apply at
/// once (the same path as `POST /v1/config`); address, port, token, workers and queue restart
/// the server. Who can connect and the pairing password live on Connect; any other address,
/// the port, the token and `tailscale serve` sit under Advanced.
struct ConfigurationView: View {
    @Environment(ServerController.self) private var controller
    @Environment(UpdateController.self) private var updates
    @State private var draft = HostConfiguration()
    @State private var loaded = false
    @State private var showToken = false
    @State private var showAdvanced = false
    @State private var message: (text: String, isError: Bool)?
    @State private var saving = false

    enum AddressChoice: Hashable {
        case loopback, tailscale, all, custom
    }

    var body: some View {
        let saved = controller.configuration
        let restartNeeded = draft.bindAddress != saved.bindAddress || draft.port != saved.port || draft.token != saved.token
            || draft.workerCount != saved.workerCount || draft.queueCapacity != saved.queueCapacity
            || (draft.pairingEnabled && draft.token.trimmingCharacters(in: .whitespaces).isEmpty)
        ScrollViewReader { proxy in
            SettingsPage(title: "Configuration", subtitle: "Saved in host-config.json. Limits and models apply at once; the address, port, token, workers and queue restart the server.") {
                if case .failed = controller.runState {
                    StartProblemBanner().padding(.top, 20)
                }
                server
                workers
                limits
                thisDevice
                // Applies at once, like This device; Save and Revert are for the host's file only.
                ServerUpdateSection(updates: updates)
                advanced
            }
            .task {
                // Screenshot mode: show the Advanced rows.
                guard controller.revealAdvanced else { return }
                try? await Task.sleep(for: .milliseconds(300))
                proxy.scrollTo("advanced-end", anchor: .bottom)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 12) {
                if let message {
                    if message.isError {
                        ErrorLabel(text: message.text)
                    } else {
                        Label(message.text, systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(Crystal.ink2)
                    }
                } else if restartNeeded {
                    Label("Saving restarts the server.", systemImage: "arrow.clockwise")
                        .font(.callout).foregroundStyle(Crystal.ink2)
                } else if draft != saved {
                    Text("Unsaved changes.").font(.callout).foregroundStyle(Crystal.ink2)
                }
                Spacer()
                Button("Revert") { draft = saved; message = nil }
                    .buttonStyle(OutlineButtonStyle())
                    .disabled(draft == saved)
                Button(saving ? "Saving…" : (restartNeeded ? "Save and Restart" : "Save")) { save() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(draft == saved || saving)
                    .keyboardShortcut("s", modifiers: .command)
            }
            .frame(maxWidth: SettingsMetrics.column - 32)
            .padding(.horizontal, 40)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(Crystal.canvas)
            .overlay(alignment: .top) { Rectangle().fill(Crystal.hairlineSoft).frame(height: 1) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            if !loaded { draft = controller.configuration; loaded = true }
            if controller.revealAdvanced { showAdvanced = true }
            controller.refreshAddresses()
        }
        .onChange(of: controller.configuration) { old, next in
            // Edits made elsewhere (Connect, the web dashboard, the Models page) show up here.
            guard !saving else { return }
            draft.maxActiveStreams = next.maxActiveStreams
            draft.maxRecordingSeconds = next.maxRecordingSeconds
            draft.useGpu = next.useGpu
            if draft.workerCount == next.workerCount { draft.workerModels = next.workerModels }
            if draft.pairingPassword == old.pairingPassword { draft.pairingPassword = next.pairingPassword }
            if draft.token == old.token { draft.token = next.token }
            if draft.bindAddress == old.bindAddress { draft.bindAddress = next.bindAddress }
            if draft.port == old.port { draft.port = next.port }
            // Links are edited on the Models page only.
            draft.modelLinks = next.modelLinks
        }
    }

    // MARK: Sections

    private var server: some View {
        SettingsSection("Server") {
            SettingsRow("Name other devices see", detail: "What a scan for servers shows. This Mac's name when left empty.") {
                SettingsTextField("Name", text: $draft.displayName, prompt: MachineName.current()).frame(width: 240)
            }
            SettingsRow("Who can connect", detail: accessLabel) {
                Button("Change…") { controller.section = .connect }.buttonStyle(OutlineButtonStyle())
            }
        }
    }

    private var accessLabel: String {
        switch controller.access {
        case .thisDevice: "This device only"
        case .tailnet: "Your Tailscale network"
        case .custom: "Custom (\(controller.configuration.bindAddr))"
        }
    }

    private var workers: some View {
        SettingsSection("Workers", footer: "Each worker transcribes one dictation at a time. Workers on the same model share it in memory.") {
            SettingsRow("Workers", detail: "How many dictations are transcribed side by side.") {
                ValueStepper(value: Binding(get: { draft.workerCount }, set: { n in
                    draft.workerCount = n
                    if draft.workerModels.count < n {
                        draft.workerModels += Array(repeating: draft.workerModels.last ?? HostConfiguration.defaultModel, count: n - draft.workerModels.count)
                    } else {
                        draft.workerModels = Array(draft.workerModels.prefix(n))
                    }
                }), range: HostConfiguration.workerCountRange, label: "Workers") { "\($0)" }
            }
            ForEach(0..<draft.workerModels.count, id: \.self) { i in
                let id = draft.workerModels[i]
                SettingsRow("Worker \(i + 1)") {
                    SelectMenu(controller.backend.catalog.first { $0.id == id }?.name ?? id, label: "Worker \(i + 1) model", minWidth: 200) {
                        Picker("Worker \(i + 1)", selection: Binding(get: { draft.workerModels[i] }, set: { draft.workerModels[i] = $0 })) {
                            ForEach(controller.backend.catalog) { m in
                                Text(m.name + (controller.backend.isInstalled(m.id) ? "" : " (not installed)")).tag(m.id)
                            }
                        }
                        .pickerStyle(.inline)
                    }
                }
            }
        }
    }

    private var limits: some View {
        SettingsSection("Limits") {
            SettingsRow("Dictations at once", detail: "Streams the server takes at the same time.") {
                ValueStepper(value: $draft.maxActiveStreams, range: HostConfiguration.maxActiveStreamsRange, label: "Dictations at once") { "\($0)" }
            }
            SettingsRow("Longest recording", detail: "A dictation longer than this is refused.") {
                ValueStepper(value: $draft.maxRecordingSeconds, range: HostConfiguration.maxRecordingSecondsRange, step: 10,
                             label: "Longest recording") { ServerFormat.duration(Double($0)) }
            }
            SettingsRow("Queue", detail: "When every worker is busy and the queue is full, new requests get 429 and clients retry.") {
                ValueStepper(value: $draft.queueCapacity, range: HostConfiguration.queueCapacityRange, label: "Queue") { "\($0) waiting" }
            }
        }
    }

    private var thisDevice: some View {
        SettingsSection("This Mac") {
            SettingsRow("Start at login", detail: "Opens the app in the menu bar when you log in. To serve with nobody logged in, see the README.") {
                Toggle("Start at login", isOn: Binding(get: { controller.loginItemEnabled }, set: { controller.setLoginItem($0) }))
                    .toggleStyle(.settingsSwitch).labelsHidden()
            }
            SettingsRow("Keep this Mac awake while serving", detail: "The display can still sleep.") {
                Toggle("Keep this Mac awake while serving", isOn: Binding(get: { controller.configuration.preventSleep }, set: {
                    controller.setPreventSleep($0)
                    draft.preventSleep = $0
                }))
                .toggleStyle(.settingsSwitch).labelsHidden()
            }
        }
    }

    // MARK: Advanced

    private var addressChoice: Binding<AddressChoice> {
        Binding {
            switch draft.bindAddress {
            case "127.0.0.1", "::1": .loopback
            case "0.0.0.0", "::": .all
            case controller.addresses.tailscale?.address ?? "-": .tailscale
            default: .custom
            }
        } set: { choice in
            switch choice {
            case .loopback: draft.bindAddress = "127.0.0.1"
            case .all: draft.bindAddress = "0.0.0.0"
            case .tailscale: draft.bindAddress = controller.addresses.tailscale?.address ?? draft.bindAddress
            case .custom: if ["127.0.0.1", "0.0.0.0"].contains(draft.bindAddress) { draft.bindAddress = controller.addresses.lan.first?.address ?? "" }
            }
        }
    }

    private var tailscaleCommand: String { "tailscale serve --bg \(String(draft.port))" }

    private var advanced: some View {
        SettingsSection("Advanced") {
            Button {
                withAnimation(.smooth(duration: 0.2)) { showAdvanced.toggle() }
            } label: {
                HStack {
                    Text(showAdvanced ? "Hide" : "Show").font(.system(size: 12, weight: .medium))
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                }
                .foregroundStyle(Crystal.ink2)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showAdvanced ? "Hide advanced settings" : "Show advanced settings")
        } content: {
            if showAdvanced {
                advancedRows
            } else {
                SettingsRow("Address, port, token and the Neural Engine", detail: "For a custom network set-up. Most servers never need these.")
            }
        }
    }

    @ViewBuilder private var advancedRows: some View {
        SettingsRow("Listen on", detail: addressChoice.wrappedValue == .custom ? nil : draft.bindAddress) {
            SelectMenu(addressTitle, label: "Listen on", minWidth: 220) {
                Picker("Listen on", selection: addressChoice) {
                    Text("This device only (127.0.0.1)").tag(AddressChoice.loopback)
                    if let t = controller.addresses.tailscale { Text("Your Tailscale network (\(t.address))").tag(AddressChoice.tailscale) }
                    Text("Every network (0.0.0.0)").tag(AddressChoice.all)
                    Text("One address…").tag(AddressChoice.custom)
                }
                .pickerStyle(.inline)
            }
        }
        if addressChoice.wrappedValue == .custom {
            SettingsRow("Address") {
                SettingsTextField("Address", text: $draft.bindAddress, prompt: "192.168.1.20", mono: true).frame(width: 200)
            }
        }
        SettingsRow("Port") {
            TextField("Port", value: $draft.port, format: .number.grouping(.never))
                .textFieldStyle(.plain).labelsHidden().font(.mono(12.5)).multilineTextAlignment(.trailing)
                .padding(.horizontal, 9).frame(width: 90, height: 28)
                .background(Crystal.well, in: .rect(cornerRadius: Radius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Crystal.input))
        }
        SettingsRow("Token", detail: draft.token.trimmingCharacters(in: .whitespaces).isEmpty
                    ? "Without a token, anything that can reach the server can use it." : "Clients send it with every request.") {
            SettingsTextField("Token", text: $draft.token, prompt: "none", secure: !showToken, mono: showToken).frame(width: 240)
            Button(showToken ? "Hide" : "Show") { showToken.toggle() }.buttonStyle(OutlineButtonStyle())
            Button("New") { draft.token = HostConfiguration.generateToken(); showToken = true }
                .buttonStyle(OutlineButtonStyle())
                .help("Make a new token. Every client then pairs again.")
            CopyButton(value: draft.token).disabled(draft.token.isEmpty)
        }
        SettingsRow("Publish with Tailscale", detail: tailscaleCommand, mono: true) {
            CopyButton(value: tailscaleCommand)
        }
        .help("Keeps the server on 127.0.0.1 and gives it an HTTPS name on your Tailscale network.")
        SettingsRow("Use the Neural Engine", detail: draft.useGpu ? "Transcription runs on the Neural Engine." : "The CPU is several times slower. Only for testing.") {
            Toggle("Use the Neural Engine", isOn: $draft.useGpu).toggleStyle(.settingsSwitch).labelsHidden()
        }
        SettingsRow("Configuration file", detail: controller.configURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), mono: true) {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([controller.configURL]) }
                .buttonStyle(OutlineButtonStyle())
        }
        .id("advanced-end")
    }

    private var addressTitle: String {
        switch addressChoice.wrappedValue {
        case .loopback: "This device only"
        case .tailscale: "Your Tailscale network"
        case .all: "Every network"
        case .custom: "One address"
        }
    }

    private func save() {
        saving = true
        message = nil
        Task {
            let outcome = await controller.save(draft)
            saving = false
            switch outcome {
            case .saved: message = ("Saved", false)
            case .restarted:
                if case .failed(let m) = controller.runState { message = (m, true) } else { message = ("Saved and restarted", false) }
            case .failed(let m): message = (m, true)
            }
            draft = controller.configuration
        }
    }
}

/// Updates in the settings idiom: the state with its action, the version, the channel and when
/// it last checked.
private struct ServerUpdateSection: View {
    var updates: UpdateController

    var body: some View {
        let p = updates.presentation
        SettingsSection("Updates", footer: "Checks every 6 hours and asks before installing. Only updates signed by Bark install.") {
            HStack(spacing: 12) {
                UpdateGlyph(presentation: p, style: .server, size: 28)
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
                    .buttonStyle(OutlineButtonStyle())
                    .disabled(updates.state == .checking || updates.state.primaryAction == .none)
            }
            .padding(.horizontal, SettingsMetrics.rowH)
            .padding(.vertical, SettingsMetrics.rowV)
            SettingsRow("Current version") {
                Text("\(updates.currentVersion) (\(updates.build))").font(.mono(12)).foregroundStyle(Crystal.ink2).textSelection(.enabled)
            }
            SettingsRow("Channel", detail: updates.channel.explanation + (updates.showsMoveToStableNote ? " You'll move to Stable with the next stable release." : "")) {
                SegmentedChoice("Update channel", selection: Binding(get: { updates.channel }, set: { updates.setChannel($0) }),
                                options: UpdateChannel.allCases.map { .init($0, $0.title) })
            }
            SettingsRow("Last checked") {
                Text(updates.lastChecked.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never")
                    .font(.system(size: 13)).foregroundStyle(Crystal.ink2)
            }
        }
    }
}
