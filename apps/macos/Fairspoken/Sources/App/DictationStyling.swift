import AppKit
import FairspokenCore

extension AppModel {
    /// Formats the dictation again from what was heard, in `style`, and saves it (nothing is
    /// pasted). A note keeps being a note.
    func restyle(_ item: TranscriptHistoryItem, as style: DictationStyle.ID) {
        let raw = (item.rawText?.isEmpty == false ? item.rawText : nil) ?? item.text
        let started = ContinuousClock.now
        let processed = DictationPipeline.process(raw, context: PostProcessContext(
            settings: settings.settings, appBundleID: item.appBundleId,
            resolution: StyleResolution(style: style, reason: "You chose this", source: .dictation)))
        let cleanupMs = Int((ContinuousClock.now - started) / .milliseconds(1))
        guard !processed.plainText.isEmpty else { notify("Nothing left to restyle"); return }
        history.update(item.id) { entry in
            if entry.rawText == nil { entry.rawText = raw }
            entry.text = processed.plainText
            entry.cleanupEdits = processed.edits
            entry.cleanupMs = cleanupMs
            entry.style = style.rawValue
            entry.styleReason = "You chose this"
        }
        notify("Restyled as \(style.displayName)")
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
