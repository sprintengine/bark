import AVFoundation
import FairspokenCore
import FairspokenUI
import SwiftUI

/// Post-training: keep dictations (audio + what the model heard) so a later step can teach the
/// speech model this voice. Saving is live; the training step itself is not built yet, so its
/// button says what it is waiting for.
struct PostTrainingView: View {
    @Environment(AppModel.self) private var model
    @State private var player = ClipPlayer()
    @State private var confirmDeleteAll = false
    @State private var confirmDelete: TrainingEntry?

    var body: some View {
        let training = model.training
        SettingsPage(title: "Post-training", subtitle: "Collect recordings of your voice now; training on them arrives in a later update.") {
            SavingSection(training: training)
            SettingsSection("Your recordings") {
                ProgressRow(summary: training.summary)
            }
            TrainSection(summary: training.summary, capturing: model.settings.settings.trainingCapture)
            RecordingsSection(training: training, player: player, confirmDeleteAll: $confirmDeleteAll, confirmDelete: $confirmDelete)
        }
        .onAppear { training.refresh() }
        .onDisappear { player.stop() }
        .confirmationDialog("Delete all \(Format.number(training.summary.count)) recordings?", isPresented: $confirmDeleteAll) {
            Button("Move All to Trash", role: .destructive) {
                player.stop()
                training.delete(.all)
            }
        } message: {
            Text("Their audio and text move from \(training.folder.path) to the Trash.")
        }
        .confirmationDialog("Delete this recording?",
                            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            presenting: confirmDelete) { entry in
            Button("Move to Trash", role: .destructive) {
                if player.playingID == entry.id { player.stop() }
                training.delete(.one(entry.id))
            }
        } message: { _ in
            Text("It moves to the Trash.")
        }
        // Only reached when the Trash couldn't be used: nothing is gone yet.
        .confirmationDialog("Delete permanently?",
                            isPresented: Binding(get: { training.needsPermanentDeletion != nil },
                                                 set: { if !$0 { training.keepAfterTrashFailed() } }),
                            presenting: training.needsPermanentDeletion) { pending in
            Button(pending.deletion == .all ? "Delete All Permanently" : "Delete Permanently", role: .destructive) {
                player.stop()
                training.deletePermanently(pending)
            }
        } message: { pending in
            Text("\(pending.deletion == .all ? "These recordings" : "This recording") in \(pending.root.path) couldn't be moved to the Trash, so nothing was deleted. Deleting permanently can't be undone.")
        }
    }
}

/// The opt-in and where recordings go.
private struct SavingSection: View {
    var training: TrainingLibrary
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsSection("Recording", footer: "About 2 MB per minute of speech. Recordings can include anything you dictate, so keep them on a drive you control. Saved recordings stay until you delete them.",
                        first: true) {
            SettingsRow("Save recordings to improve models",
                        detail: "Keeps the audio of each dictation and what the model heard, so it can learn your voice later. Nothing is uploaded.") {
                SettingSwitch(label: "Save recordings to improve models", isOn: model.setting(\.trainingCapture))
            }
            SettingsRow("Saved to", detail: training.folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), mono: true) {
                Button("Show in Finder") { training.revealInFinder() }.cardButton().disabled(!training.isAvailable)
                Button("Change…") { training.chooseFolder() }.cardButton()
                if !training.usesDefaultFolder {
                    Button("Use Default") { training.useDefaultFolder() }
                        .cardButton()
                        .help("Save to \(TrainingLibrary.defaultFolder.path) on this Mac")
                }
            }
            if !training.isAvailable {
                warning("This folder isn't available. Connect its drive, or choose another folder. Dictation keeps working, but nothing is saved until then.")
            } else if let error = training.lastError {
                warning(error)
            }
        }
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 12)).foregroundStyle(Crystal.warn)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, SettingsMetrics.rowH)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// How much has been kept, against what training wants.
private struct ProgressRow: View {
    var summary: TrainingSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 32) {
                stat(Format.duration(summary.seconds), "of speech")
                stat(Format.number(summary.count), summary.count == 1 ? "recording" : "recordings")
                stat(Format.bytes(summary.bytes), "on disk")
            }
            ProgressView(value: summary.progress)
                .tint(Crystal.ink2)
                .accessibilityLabel("Toward the recommended \(Int(TrainingReadiness.recommendedSeconds / 3600)) hours")
            Text(caption)
                .font(.system(size: 12)).foregroundStyle(Crystal.ink2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, SettingsMetrics.rowH)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var caption: String {
        let minimum = Int(TrainingReadiness.minimumSeconds / 3600)
        let recommended = Int(TrainingReadiness.recommendedSeconds / 3600)
        if summary.seconds >= TrainingReadiness.recommendedSeconds {
            return "Plenty to train on. More still helps, especially of the words you use most."
        }
        if summary.isEnoughToTrain {
            return "Enough to try. \(recommended) hours is recommended for a dependable improvement."
        }
        return "Post-training needs at least \(minimum) hour of speech; \(recommended) hours is recommended."
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.mvNumber(24)).foregroundStyle(Crystal.ink).monospacedDigit()
            Text(label).font(.system(size: 12)).foregroundStyle(Crystal.ink3)
        }
        .accessibilityElement(children: .combine)
    }
}

/// What post-training does, and its button.
private struct TrainSection: View {
    var summary: TrainingSummary
    var capturing: Bool

    var body: some View {
        SettingsSection("Post-train") {
            step(1, "Save your dictations as you work.", done: capturing)
            step(2, "Transcribe them again with a larger, slower model, and find where Parakeet went wrong.")
            step(3, "Fine-tune Parakeet on your voice and accent.")
            step(4, "Test it on recordings it never trained on, and switch only if it's better.")
            SettingsRow("Post-train", detail: status) {
                Button("Post-train") {}.buttonStyle(PrimaryButtonStyle()).disabled(true)
            }
        }
    }

    private var status: String {
        if !summary.isEnoughToTrain {
            let left = TrainingReadiness.minimumSeconds - summary.seconds
            return "Available after \(Format.duration(TrainingReadiness.minimumSeconds)) of recordings (\(Format.duration(left)) to go). Training itself comes in a later update."
        }
        return "Your recordings are ready. Training itself comes in a later update."
    }

    private func step(_ n: Int, _ text: String, done: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(n).circle")
                .font(.system(size: 14))
                .foregroundStyle(done ? Crystal.ink : Crystal.ink3)
            Text(text).font(.system(size: 14)).foregroundStyle(Crystal.ink).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, SettingsMetrics.rowH)
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }
}

/// The latest kept dictations: listen to one, or delete it.
private struct RecordingsSection: View {
    var training: TrainingLibrary
    var player: ClipPlayer
    @Binding var confirmDeleteAll: Bool
    @Binding var confirmDelete: TrainingEntry?
    private static let shown = 30

    var body: some View {
        SettingsSection("Recent recordings",
                        footer: training.entries.count > Self.shown ? "And \(Format.number(training.entries.count - Self.shown)) more in the folder." : nil) {
            Button("Delete All…", role: .destructive) { confirmDeleteAll = true }
                .cardButton()
                .disabled(training.entries.isEmpty || !training.isAvailable)
        } content: {
            if training.entries.isEmpty {
                SettingsRow(training.isAvailable ? "Nothing saved yet" : "The folder isn't connected",
                            detail: training.isAvailable ? "Turn on saving above, then dictate as usual." : "Connect the drive to see saved recordings.")
            } else {
                ForEach(training.entries.prefix(Self.shown)) { entry in row(entry) }
            }
        }
    }

    private func row(_ entry: TrainingEntry) -> some View {
        let playing = player.playingID == entry.id
        return HStack(alignment: .center, spacing: 12) {
            Button {
                playing ? player.stop() : player.play(entry.id, url: training.audioURL(for: entry.id))
            } label: {
                Image(systemName: playing ? "stop.fill" : "play.fill")
                    .font(.system(size: 11))
                    .frame(width: 28, height: 28)
                    .background(Crystal.well, in: .circle)
                    .overlay(Circle().strokeBorder(Crystal.input))
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .foregroundStyle(playing ? Crystal.ink : Crystal.ink2)
            .accessibilityLabel(playing ? "Stop" : "Play recording")
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.rawText).font(.system(size: 14)).foregroundStyle(Crystal.ink)
                    .lineLimit(2).textSelection(.enabled)
                HStack(spacing: 6) {
                    Text("\(Format.relative(entry.date)) · \(Format.duration(entry.durationSeconds)) · \(SpeechModelCatalog.model(id: entry.speechModel)?.shortName ?? entry.speechModel)")
                        .font(.system(size: 12)).foregroundStyle(Crystal.ink3)
                    if entry.appCategory != AppCategory.other.rawValue {
                        Badge(entry.appCategory.capitalized)
                    }
                }
            }
            Spacer(minLength: 8)
            RemoveButton(label: "Move this recording to the Trash") { confirmDelete = entry }
        }
        .padding(.horizontal, SettingsMetrics.rowH)
        .padding(.vertical, 10)
    }
}

/// Plays one kept recording at a time.
@Observable
final class ClipPlayer: NSObject, AVAudioPlayerDelegate {
    private(set) var playingID: String?
    @ObservationIgnored private var player: AVAudioPlayer?

    func play(_ id: String, url: URL) {
        stop()
        guard let next = try? AVAudioPlayer(contentsOf: url) else { return }
        next.delegate = self
        next.play()
        player = next
        playingID = id
    }

    func stop() {
        player?.stop()
        player = nil
        playingID = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}
