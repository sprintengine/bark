import FairspokenCore
import FairspokenUI
import SwiftUI

/// Post-training: keep dictations (audio + what the model heard) so a later step can teach the
/// speech model this voice. Saving is live; the training step itself is not built yet.
struct PostTrainingView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmDeleteAll = false

    var body: some View {
        let training = model.training
        SettingsPage(title: "Post-training") {
            SavingSection(training: training)
            SettingsSection("Your recordings") {
                Button("Delete All…", role: .destructive) { confirmDeleteAll = true }
                    .cardButton()
                    .disabled(training.entries.isEmpty || !training.isAvailable)
            } content: {
                ProgressRow(summary: training.summary)
            }
        }
        .onAppear { training.refresh() }
        .confirmationDialog("Delete all \(Format.number(training.summary.count)) recordings?", isPresented: $confirmDeleteAll) {
            Button("Move All to Trash", role: .destructive) { training.delete(.all) }
        } message: {
            Text("Their audio and text move from \(training.folder.path) to the Trash.")
        }
        // Only reached when the Trash couldn't be used: nothing is gone yet.
        .confirmationDialog("Delete permanently?",
                            isPresented: Binding(get: { training.needsPermanentDeletion != nil },
                                                 set: { if !$0 { training.keepAfterTrashFailed() } }),
                            presenting: training.needsPermanentDeletion) { pending in
            Button(pending.deletion == .all ? "Delete All Permanently" : "Delete Permanently", role: .destructive) {
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
        SettingsSection("Recording", first: true) {
            SettingsRow("Save recordings to improve models") {
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

/// How much has been kept.
private struct ProgressRow: View {
    var summary: TrainingSummary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 32) {
            stat(Format.duration(summary.seconds), "of speech")
            stat(Format.number(summary.count), summary.count == 1 ? "recording" : "recordings")
            stat(Format.bytes(summary.bytes), "on disk")
        }
        .padding(.horizontal, SettingsMetrics.rowH)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.mvNumber(24)).foregroundStyle(Crystal.ink).monospacedDigit()
            Text(label).font(.system(size: 12)).foregroundStyle(Crystal.ink3)
        }
        .accessibilityElement(children: .combine)
    }
}
