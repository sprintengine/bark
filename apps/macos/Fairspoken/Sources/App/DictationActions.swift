import AppKit
import FairspokenCore

/// What can be done with a dictation in history: copy it, paste it into its app again, open the
/// app, transcribe its kept recording again, correct its text, delete it.
extension AppModel {
    func copy(_ item: TranscriptHistoryItem) {
        TextInserter.copy(item.text)
        notify("Copied")
    }

    /// Brings the dictation's app forward and pastes the text again (left on the clipboard when
    /// the app isn't running or can't take it).
    func pasteAgain(_ item: TranscriptHistoryItem) {
        guard let bundle = item.appBundleId, !item.isBarkNote,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else {
            TextInserter.copy(item.text)
            notify("Copied: \(DictationText.appName(item)) isn't open")
            return
        }
        app.activate()
        let s = settings.settings
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            switch await TextInserter.deliver(item.text, paste: true, restoreClipboard: s.restoreClipboard,
                                              expectedApp: app.processIdentifier) {
            case .pasted: notify("Pasted into \(app.localizedName ?? DictationText.appName(item))")
            case .copied: notify("Copied to the clipboard")
            }
        }
    }

    func canOpenApp(_ item: TranscriptHistoryItem) -> Bool {
        guard !item.isBarkNote, let bundle = item.appBundleId else { return false }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) != nil
    }

    func openApp(_ item: TranscriptHistoryItem) {
        if let host = item.destinationHost, let url = URL(string: "https://\(host)") {
            NSWorkspace.shared.open(url)
            return
        }
        guard let bundle = item.appBundleId, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Saves a corrected text. The words as heard (`rawText`) are kept, so the diff shows the
    /// correction too.
    func correct(_ item: TranscriptHistoryItem, to text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.text else { return }
        history.update(item.id) { entry in
            if entry.rawText == nil && !entry.isBarkNote { entry.rawText = entry.text }
            entry.text = trimmed
        }
        notify("Saved")
    }

    /// Deletes a dictation; the selection moves to its neighbour in `visible`, or back to Home.
    func deleteDictation(_ id: String, visible: [TranscriptHistoryItem]) {
        if selectedDictationID == id {
            let index = visible.firstIndex { $0.id == id }
            let neighbour = index.flatMap { i in visible.indices.contains(i + 1) ? visible[i + 1] : i > 0 ? visible[i - 1] : nil }
            selectedDictationID = neighbour?.id
        }
        history.delete(id)
    }

    // MARK: Retry

    /// The kept recording of a dictation, when post-training kept one (matched by its text and
    /// time).
    func keptRecording(for item: TranscriptHistoryItem) -> URL? {
        guard !item.isBarkNote else { return nil }
        let created = item.createdAt / 1000
        guard let entry = training.entries.first(where: { e in
            abs(e.createdAt - created) <= 300 && (e.finalText == item.text || (item.rawText != nil && e.rawText == item.rawText))
        }) else { return nil }
        let url = training.audioURL(for: entry.id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func canRetry(_ item: TranscriptHistoryItem) -> Bool { keptRecording(for: item) != nil }

    /// Transcribes the kept recording again with the model in use on this Mac, and replaces the
    /// dictation's text (it isn't pasted anywhere).
    func retry(_ item: TranscriptHistoryItem) {
        guard !retryingDictations.contains(item.id), let url = keptRecording(for: item),
              let data = try? Data(contentsOf: url), let wav = try? WAVFile.decode(data), wav.sampleRate == 16_000 else {
            notify("No recording was kept for this one")
            return
        }
        let samples = wav.samples.map { Float($0) / 32_768 }
        let s = settings.settings
        retryingDictations.insert(item.id)
        Task { @MainActor in
            defer { retryingDictations.remove(item.id) }
            do {
                let options = TranscriptionRequestOptions(
                    language: s.language, vocabularyHints: VocabularyPacks.hints(userTerms: s.vocabularyHints, enabledPacks: s.enabledPacks))
                let output = try await models.transcribeOnThisMac(samples, model: s.model, options: options)
                let text = await BasicPostProcessor().process(output.text, context: PostProcessContext(
                    appBundleID: item.appBundleId, vocabulary: s.vocabularyHints,
                    corrections: s.postProcess ? s.transcriptCorrections : [], speechModel: s.speechModelID))
                guard !text.isEmpty else { notify("No words this time"); return }
                history.update(item.id) { entry in
                    entry.rawText = output.text
                    entry.text = text
                    entry.model = output.model
                    entry.cleanupEdits = nil
                }
                notify("Transcribed again with \(models.activeModel.shortName)")
            } catch {
                notify(error.localizedDescription)
            }
        }
    }

    /// Says what an action did, for a moment, under the actions card (and to VoiceOver).
    func notify(_ message: String) {
        dictationNotice = message
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.2))
            if dictationNotice == message { dictationNotice = nil }
        }
    }
}

extension AppModel {
    /// Saves Home's composer as a note. Dictations made into it (`replacing`) are folded into the
    /// note rather than kept twice. Returns the note's id.
    func saveNote(_ text: String, replacing sources: [String]) -> String? {
        guard let id = history.addNote(text) else { return nil }
        for source in sources where source != id { history.delete(source) }
        return id
    }
}
