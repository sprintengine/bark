import AppKit
import FairspokenCore

extension AppModel {
    /// What was heard, for formatting again: the raw text, or the text itself for an item kept
    /// before raw text was recorded.
    private func heard(_ item: TranscriptHistoryItem) -> String {
        (item.rawText?.isEmpty == false ? item.rawText : nil) ?? item.text
    }

    /// The item's destination as the rules resolve it with `style` chosen: a terminal or a
    /// password field stays Verbatim, a single-line field stays one line.
    private func resolution(for item: TranscriptHistoryItem, as style: DictationStyle.ID) -> StyleResolution {
        guard !item.isBarkNote else { return StyleResolution(style: style, reason: "You chose this", source: .dictation) }
        return settings.settings.styleRules.resolve(destination(of: item), override: style)
    }

    /// Bark never reshapes this destination (a terminal, a password manager), so it can't be restyled.
    func isStyleForced(_ item: TranscriptHistoryItem) -> Bool {
        !item.isBarkNote && settings.settings.styleRules.resolve(destination(of: item)).source == .forced
    }

    /// The text has been changed since it was formatted (Edit text, a composer command), so
    /// formatting again from what was heard would replace those changes.
    func hasEditsSinceFormatting(_ item: TranscriptHistoryItem) -> Bool {
        guard let style = item.styleID, item.rawText?.isEmpty == false else { return false }
        return DictationPipeline.process(heard(item), context: context(for: item, resolution(for: item, as: style))).plainText != item.text
    }

    /// The post-processing context for an item: today's settings, with the corrections scoped to
    /// the speech model that heard it rather than the one in use now.
    private func context(for item: TranscriptHistoryItem, _ resolution: StyleResolution) -> PostProcessContext {
        var context = PostProcessContext(settings: settings.settings, appBundleID: item.appBundleId, resolution: resolution)
        if item.location == "remote-host" {
            context.speechModel = "remote-host"
        } else if let model = item.model, !model.isEmpty {
            context.speechModel = model
        }
        return context
    }

    /// Formats the dictation again from what was heard, in `style`, and saves it (nothing is
    /// pasted). The same style again changes nothing; a destination that is always Verbatim
    /// stays so. A note can be restyled too; it stays a note.
    func restyle(_ item: TranscriptHistoryItem, as style: DictationStyle.ID) {
        guard style != item.styleID, !isStyleForced(item) else { return }
        let raw = heard(item)
        let started = ContinuousClock.now
        let resolution = resolution(for: item, as: style)
        let processed = DictationPipeline.process(raw, context: context(for: item, resolution))
        let cleanupMs = Int((ContinuousClock.now - started) / .milliseconds(1))
        guard !processed.plainText.isEmpty else { notify("Nothing left to restyle"); return }
        // Before the text changes, keep the link to its kept recording (found by its text).
        let recordingID = item.recordingID ?? keptRecordingID(for: item)
        history.update(item.id) { entry in
            entry.recordingID = recordingID
            if entry.rawText == nil { entry.rawText = raw }
            entry.text = processed.plainText
            entry.cleanupEdits = processed.edits
            entry.cleanupMs = cleanupMs
            entry.style = resolution.style.rawValue
            entry.styleReason = resolution.reason
        }
        notify("Restyled as \(resolution.style.displayName)")
    }

    /// Where a dictation went, as the style rules see it.
    func destination(of item: TranscriptHistoryItem) -> DictationDestination {
        DictationDestination(bundleID: item.appBundleId, appName: item.appName,
                             url: item.destinationHost.map { "https://\($0)/" })
    }

    /// What "Always use … for" would write a rule for, or nil (a note, a terminal).
    func alwaysUseTarget(for item: TranscriptHistoryItem) -> StyleRules.RuleTarget? {
        guard !item.isBarkNote else { return nil }
        return settings.settings.styleRules.alwaysUseTarget(for: destination(of: item))
    }

    /// Makes the dictation's style the rule for its app or site from now on.
    func alwaysUseStyle(of item: TranscriptHistoryItem) {
        guard let style = item.styleID, let target = alwaysUseTarget(for: item) else { return }
        settings.update { $0.styleRules.alwaysUse(style, for: destination(of: item)) }
        notify("\(style.displayName) from now on in \(target.label)")
    }

    /// Adds a word to the Dictionary (Your words), if there's room and it isn't there already.
    func addToDictionary(_ term: String) {
        let clean = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let hints = settings.settings.vocabularyHints
        if hints.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) {
            notify("“\(clean)” is already in your Dictionary")
            return
        }
        guard hints.count < AppSettings.maxVocabularyHints else {
            notify("Your Dictionary is full: remove a word in Settings first")
            return
        }
        settings.update { $0.vocabularyHints.append(clean) }
        notify("Added “\(clean)” to your Dictionary")
    }

    /// A word in the dictation worth adding to the Dictionary: the first name-like word (a
    /// capital not starting a sentence) that isn't there already. Nil when none stands out.
    func dictionaryCandidate(in item: TranscriptHistoryItem) -> String? {
        let known = Set(settings.settings.vocabularyHints.map { $0.lowercased() })
        let common: Set<String> = ["i", "i'm", "i'll", "i've", "i'd", "ok", "okay", "monday", "tuesday", "wednesday", "thursday",
                                   "friday", "saturday", "sunday", "january", "february", "march", "april", "may", "june",
                                   "july", "august", "september", "october", "november", "december", "hi", "hello", "dear",
                                   "thanks", "thank", "regards", "best", "cheers"]
        // Each line starts a sentence (a greeting, a paragraph, a list item).
        for line in item.text.split(whereSeparator: \.isNewline) {
            var sentenceStart = true
            for raw in line.split(whereSeparator: \.isWhitespace) {
                let word = raw.trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "'’-")))
                let startsSentence = sentenceStart || raw == "-" || raw == "•"
                sentenceStart = raw.last.map { ".?!:".contains($0) } ?? false || raw == "-" || raw == "•"
                guard !startsSentence, word.count >= 3, let first = word.first, first.isUppercase,
                      word.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "’" || $0 == "-" }),
                      !common.contains(word.lowercased()), !known.contains(word.lowercased()),
                      // All capitals is an acronym, usually already right.
                      !word.allSatisfy(\.isUppercase) else { continue }
                return word
            }
        }
        return nil
    }
}
