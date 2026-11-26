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
        let name = app.localizedName ?? DictationText.appName(item)
        Task { @MainActor in
            // Wait for the app to come forward; never paste into whatever else is in front.
            for _ in 0..<15 where NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
                TextInserter.copy(item.text)
                notify("Copied: \(name) didn't come forward")
                return
            }
            switch await TextInserter.deliver(item.text, paste: true, restoreClipboard: s.restoreClipboard,
                                              expectedApp: app.processIdentifier, requireExpectedApp: true) {
            case .pasted: notify("Pasted into \(name)")
            case .copied(let reason): notify(reason)
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

    /// Saves a corrected text. The words as heard (`rawText`), when recorded, are kept, so the diff
    /// shows the correction too.
    func correct(_ item: TranscriptHistoryItem, to text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.text else { return }
        // Typed over the text as a command ("change Tuesday to Friday", "delete really",
        // "add see you then at the end"): applied to the text, and the change listed with its edits.
        if let result = NoteEditCommand.command(trimmed, for: item.text) {
            history.update(item.id) { entry in
                entry.recordingID = entry.recordingID ?? keptRecordingID(for: item)
                entry.text = result.text
                entry.cleanupEdits = (entry.cleanupEdits ?? []) + result.edits
            }
            notify("Changed")
            return
        }
        history.update(item.id) { entry in
            // Before a correction loses the words that found it, keep its recording's id.
            entry.recordingID = entry.recordingID ?? keptRecordingID(for: item)
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

    /// The id of a dictation's kept post-training recording: the one stored with it, or, for one
    /// kept before that, found by its words and time. Nil when the recording isn't on disk.
    func keptRecordingID(for item: TranscriptHistoryItem) -> String? {
        guard !item.isBarkNote else { return nil }
        let id: String
        if let recordingID = item.recordingID {
            id = recordingID
        } else {
            let created = item.createdAt / 1000
            guard let entry = training.entries.first(where: { e in
                abs(e.createdAt - created) <= 300 && (e.finalText == item.text || (item.rawText != nil && e.rawText == item.rawText))
            }) else { return nil }
            id = entry.id
        }
        return FileManager.default.fileExists(atPath: training.audioURL(for: id).path) ? id : nil
    }

    func canRetry(_ item: TranscriptHistoryItem) -> Bool { keptRecordingID(for: item) != nil }

    /// Transcribes the kept recording again with the model in use on this Mac, and replaces the
    /// dictation's text (it isn't pasted anywhere).
    func retry(_ item: TranscriptHistoryItem) {
        guard !retryingDictations.contains(item.id) else { return }
        guard let recordingID = keptRecordingID(for: item) else {
            notify("No recording was kept for this one")
            return
        }
        guard let data = try? Data(contentsOf: training.audioURL(for: recordingID)), let wav = try? WAVFile.decode(data), wav.sampleRate == 16_000 else {
            notify("The kept recording couldn't be read")
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
                // The style it had, or what the rules give its app now; nothing is pasted, so only the
                // text changes (a note keeps the notes style).
                let resolution = item.styleID.map { StyleResolution(style: $0, reason: item.styleReason ?? "As before", source: .dictation) }
                    ?? s.styleRules.resolve(DictationDestination(bundleID: item.appBundleId, appName: item.appName))
                let started = ContinuousClock.now
                let processed = DictationPipeline.process(output.text, context: PostProcessContext(settings: s, appBundleID: item.appBundleId,
                                                                                                    resolution: resolution))
                let cleanupMs = Int((ContinuousClock.now - started) / .milliseconds(1))
                let text = processed.plainText
                guard !text.isEmpty else { notify("No words this time"); return }
                history.update(item.id) { entry in
                    entry.recordingID = recordingID
                    entry.rawText = output.text
                    entry.text = text
                    entry.model = output.model
                    entry.backend = output.backend
                    entry.location = "local"
                    entry.timings = DictationTimings(transcribeMs: output.modelMs, speechModelMs: output.modelMs, totalMs: 0)
                    entry.cleanupEdits = processed.edits
                    entry.cleanupMs = cleanupMs
                    entry.style = resolution.style.rawValue
                    entry.styleReason = resolution.reason
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
    /// Saves Home's composer as a note. Dictations made into it (`replacing`) whose words are still
    /// in it are folded into the note rather than kept twice. Returns the note's id.
    func saveNote(_ text: String, replacing sources: [String]) -> String? {
        let folded = sources.compactMap { history.item($0) }.filter { $0.isBarkNote && text.contains($0.text) }
        guard let id = history.addNote(text) else { return nil }
        for source in folded where source.id != id { history.delete(source.id) }
        return id
    }
}
