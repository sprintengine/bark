import Foundation

/// Post-processing for one dictation, in order: the user's vocabulary casing, cleanup (as the
/// style asks, within the user's switches), the user's corrections, then the style's layout.
/// Pure and synchronous: a typical dictation takes well under 2 ms.
public enum DictationPipeline {
    public static func process(_ raw: String, context: PostProcessContext) -> PostProcessResult {
        let style = context.style
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var edits: [PositionedEdit] = []
        var sequence = 0
        func add(_ kind: CleanupEdit.Kind, _ removed: String, _ inserted: String, at position: Int) {
            sequence += 1
            edits.append(PositionedEdit(position: position, sequence: sequence, edit: CleanupEdit(kind: kind, removed: removed, inserted: inserted)))
        }

        // 1. Vocabulary casing: only letter case changes, so words stay one-for-one.
        let cased = VocabularyCasing.apply(trimmed, vocabulary: context.vocabulary)
        if cased != trimmed {
            let before = trimmed.split(whereSeparator: \.isWhitespace)
            let after = cased.split(whereSeparator: \.isWhitespace)
            if before.count == after.count {
                for (n, (b, a)) in zip(before, after).enumerated() where b != a { add(.vocabulary, String(b), String(a), at: n) }
            }
        }

        // 2. Cleanup. Spoken line breaks are dropped where only one line fits.
        let options = style.cleanupOptions.restricted(by: context.cleanup)
        var (tokens, cleanupEdits) = TranscriptCleanup.run(TranscriptTokenizer.tokenize(cased), options: options)
        for e in cleanupEdits.sorted() { add(e.edit.kind, e.edit.removed, e.edit.inserted, at: e.position) }
        cleanupEdits = []

        // 3. The user's corrections, on the cleaned words.
        if !context.corrections.isEmpty {
            let before = TranscriptTokenizer.render(tokens)
            let corrected = TranscriptCorrections.apply(before, corrections: context.corrections, speechModel: context.speechModel)
            if corrected != before {
                let (aligned, changes) = Self.align(tokens, with: TranscriptTokenizer.tokenize(corrected))
                tokens = aligned
                for change in changes { add(.vocabulary, change.removed, change.inserted, at: change.position) }
            }
        }

        // 4. Layout.
        let text = TranscriptTokenizer.render(tokens, multiline: context.allowsMultiline)
        let (plain, html, layoutEdits) = StyleFormatter.format(tokens, style: style, multiline: context.allowsMultiline,
                                                               richText: context.allowsRichText, spokenCues: context.cleanup.spokenCommands)
        for e in layoutEdits.sorted() { add(e.edit.kind, e.edit.removed, e.edit.inserted, at: e.position) }
        return PostProcessResult(text: text, plainText: plain, html: html, edits: edits.sorted().map(\.edit),
                                 style: style, styleReason: context.styleReason)
    }

    struct Change: Equatable {
        var removed: String
        var inserted: String
        var position: Int
    }

    /// Re-tokenised text lined up with the words it came from, so the corrected words keep their
    /// original positions (and edits stay in transcript order). Common words keep their origin;
    /// each changed run becomes one change.
    static func align(_ old: [WordToken], with new: [WordToken]) -> ([WordToken], [Change]) {
        var result = new
        var changes: [Change] = []
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix].text == new[prefix].text { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix].text == new[new.count - 1 - suffix].text { suffix += 1 }
        for i in 0..<prefix { result[i].origin = old[i].origin; result[i].quoted = old[i].quoted }
        for k in 0..<suffix {
            result[new.count - 1 - k].origin = old[old.count - 1 - k].origin
            result[new.count - 1 - k].quoted = old[old.count - 1 - k].quoted
        }
        let a = Array(old[prefix..<(old.count - suffix)])
        let b = Array(new[prefix..<(new.count - suffix)])
        // Longest common subsequence over the middle.
        var lcs = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        if !a.isEmpty && !b.isEmpty {
            for i in stride(from: a.count - 1, through: 0, by: -1) {
                for j in stride(from: b.count - 1, through: 0, by: -1) {
                    lcs[i][j] = a[i].text == b[j].text ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }
        var i = 0, j = 0
        var removed: [String] = [], inserted: [String] = []
        var runPosition: Int?
        let fallback = prefix < old.count ? old[prefix].origin : (old.last?.origin ?? 0)
        func flush() {
            if !removed.isEmpty || !inserted.isEmpty {
                changes.append(Change(removed: removed.joined(separator: " "), inserted: inserted.joined(separator: " "),
                                      position: runPosition ?? fallback))
            }
            removed = []
            inserted = []
            runPosition = nil
        }
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i].text == b[j].text {
                flush()
                result[prefix + j].origin = a[i].origin
                i += 1
                j += 1
            } else if j < b.count, i == a.count || lcs[i][j + 1] >= lcs[i + 1][j] {
                inserted.append(b[j].text)
                result[prefix + j].origin = i < a.count ? a[i].origin : (a.last?.origin ?? fallback)
                runPosition = runPosition ?? result[prefix + j].origin
                j += 1
            } else {
                removed.append(a[i].text)
                runPosition = runPosition ?? a[i].origin
                i += 1
            }
        }
        flush()
        return (result, changes)
    }
}
