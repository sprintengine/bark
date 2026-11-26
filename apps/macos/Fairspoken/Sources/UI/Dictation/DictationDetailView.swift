import AppKit
import FairspokenCore
import FairspokenUI
import SwiftUI

/// A dictation, opened as a conversation: what you said in a grey bubble (the words cleanup took
/// out dimmed), what Bark pasted as the reply, "Cleaned up in N ms" opening a table of the changes
/// and a word diff (blue added, orange removed), an actions card beside it, and a composer docked
/// at the bottom to correct the text.
struct DictationDetailView: View {
    var item: TranscriptHistoryItem
    @Environment(AppModel.self) private var model
    @AppStorage("DictationPanelHidden") private var panelHidden = false
    @State private var width: CGFloat = 900

    var body: some View {
        let side = !panelHidden && width >= 760
        ScrollView {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 0) {
                    Conversation(item: item)
                    if !panelHidden && !side {
                        ActionsCard(item: item).padding(.top, 24).frame(maxWidth: 320)
                    }
                }
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
                if side {
                    ActionsCard(item: item).frame(width: 244)
                }
            }
            .padding(.leading, 32)
            .padding(.trailing, 20)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .scrollEdgeEffectStyle(.soft, for: .all)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(alignment: .top, spacing: 20) {
                CorrectionComposer(item: item)
                    .frame(maxWidth: 620)
                    .frame(maxWidth: .infinity)
                if side { Color.clear.frame(width: 244, height: 1) }
            }
            .padding(.leading, 32)
            .padding(.trailing, 20)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

// MARK: - Conversation

private struct Conversation: View {
    var item: TranscriptHistoryItem
    @Environment(AppModel.self) private var model
    @AppStorage("DictationChangesShown") private var changesShown = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let raw = item.rawText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let heard = raw.flatMap { $0.isEmpty ? nil : $0 }
        let diff = heard.map { WordDiff(from: $0, to: item.text) }
        let changed = !(diff?.isUnchanged ?? true) || !(item.cleanupEdits ?? []).isEmpty
        VStack(alignment: .leading, spacing: 0) {
            if let heard, let diff, !item.isBarkNote {
                SaidBubble(raw: heard, diff: diff, edits: item.cleanupEdits)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                meta.padding(.top, 6)
            } else {
                meta.frame(maxWidth: .infinity, alignment: .leading)
            }

            if !item.isBarkNote {
                Button {
                    withAnimation(Motion.unlessReduced(Motion.normal, reduceMotion)) { changesShown.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text(headline(changed: changed))
                        if changed {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .rotationEffect(.degrees(changesShown ? 90 : 0))
                        }
                    }
                    .font(.system(size: 15))
                    .foregroundStyle(Crystal.ink2)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(!changed)
                .accessibilityLabel(headline(changed: changed))
                .accessibilityValue(changed ? (changesShown ? "Changes shown" : "Changes hidden") : "")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 18)
                .padding(.bottom, 12)
                .overlay(alignment: .bottom) { Rectangle().fill(Crystal.hairline).frame(height: 1) }
            }

            PastedText(item: item).padding(.top, item.isBarkNote ? 14 : 12)

            if changed && changesShown {
                ChangesTable(item: item, diff: diff).padding(.top, 14)
                if let diff, !diff.isUnchanged {
                    DiffCard(diff: diff).padding(.top, 14)
                }
            }
        }
    }

    private var meta: some View {
        var parts = [item.date.formatted(date: .omitted, time: .shortened)]
        if !Calendar.current.isDateInToday(item.date) { parts[0] = item.date.formatted(.dateTime.day().month(.abbreviated)) + " " + parts[0] }
        if item.durationSeconds > 0 { parts.append(String(format: "%.1f s", item.durationSeconds)) }
        if item.location == "remote-host" { parts.append("Bark Server") }
        if item.isBarkNote {
            parts.append("written in \(AppInfo.displayName)")
        } else {
            parts.append("→ \(DictationText.appName(item))\(item.clipboardOnly == true ? ", clipboard" : "")")
        }
        return HStack(spacing: 10) {
            ForEach(parts, id: \.self) { Text($0) }
        }
        .font(.mono(11))
        .foregroundStyle(Crystal.ink3)
        .frame(maxWidth: .infinity, alignment: item.isBarkNote || item.rawText == nil ? .leading : .trailing)
        .accessibilityElement(children: .combine)
    }

    private func headline(changed: Bool) -> String {
        let ms = item.cleanupMs ?? item.timings.map { $0.polishMs }.flatMap { $0 > 0 ? $0 : nil }
        if changed { return ms.map { "Cleaned up in \($0) ms" } ?? "Cleaned up" }
        if let total = item.timings?.totalMs, total > 0 { return "Pasted as heard, \(total) ms after you let go" }
        return "Pasted as heard"
    }
}

/// What you said, in a grey bubble: the words cleanup took out are dimmed.
private struct SaidBubble: View {
    var raw: String
    var diff: WordDiff
    var edits: [CleanupEdit]?

    var body: some View {
        Text(attributed)
            .font(.system(size: 15))
            .lineSpacing(5)
            .foregroundStyle(Crystal.ink)
            .textSelection(.enabled)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Crystal.message, in: .rect(cornerRadius: Radius.composer, style: .continuous))
            .frame(maxWidth: 570, alignment: .trailing)
            .accessibilityLabel("You said: \(raw)")
    }

    /// Dims each removed word: from the cleanup edits when they were recorded (found in order),
    /// else from the word diff.
    private var attributed: AttributedString {
        var out = AttributedString(raw)
        let dim = Crystal.ink3
        if let edits, !edits.isEmpty {
            var from = out.startIndex
            for edit in edits where !edit.removed.isEmpty {
                guard let range = out[from...].range(of: edit.removed, options: .caseInsensitive) else { continue }
                // Only what was taken out is dimmed; punctuation, formatting and commands rewrite words.
                if [.filler, .repetition, .restart, .selfCorrection].contains(edit.kind) {
                    // A correction keeps its last words ("Thursday, no wait, Friday" keeps "Friday").
                    var dimmed = range
                    if !edit.inserted.isEmpty, let kept = out[range].range(of: edit.inserted, options: [.caseInsensitive, .backwards]) {
                        dimmed = range.lowerBound..<kept.lowerBound
                    }
                    if dimmed.lowerBound < dimmed.upperBound { out[dimmed].foregroundColor = dim }
                }
                from = range.upperBound
            }
            return out
        }
        var words = diff.originalWords.makeIterator()
        var flags = diff.removedInOriginal.makeIterator()
        var from = out.startIndex
        while let word = words.next(), let removed = flags.next() {
            guard let range = out[from...].range(of: word) else { continue }
            if removed { out[range].foregroundColor = dim }
            from = range.upperBound
        }
        return out
    }
}

/// What Bark pasted (or the note), as the reply, paragraph by paragraph.
private struct PastedText: View {
    var item: TranscriptHistoryItem

    var body: some View {
        let paragraphs = item.text.components(separatedBy: "\n\n")
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, p in
                Text(p)
                    .font(item.style == "code" ? .mono(14) : .system(size: 15))
                    .lineSpacing(5)
                    .foregroundStyle(Crystal.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.isBarkNote ? "Note" : "Pasted"): \(item.text)")
    }
}

/// Step and result: each kind of change cleanup made, and the style.
private struct ChangesTable: View {
    var item: TranscriptHistoryItem
    var diff: WordDiff?

    var body: some View {
        let rows = Self.rows(item, diff: diff)
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                Text("Step").fontWeight(.semibold)
                Text("Result").fontWeight(.semibold)
            }
            .padding(.bottom, 9)
            Rectangle().fill(Crystal.hairline).frame(height: 1).gridCellUnsizedAxes(.horizontal)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(row.step).foregroundStyle(Crystal.ink2)
                        .frame(width: 190, alignment: .leading)
                    Text(row.result)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 8)
                Rectangle().fill(Crystal.hairline).frame(height: 1).gridCellUnsizedAxes(.horizontal)
            }
        }
        .font(.system(size: 14))
        .foregroundStyle(Crystal.ink)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Changes")
    }

    struct Row { var step: String; var result: AttributedString }

    /// Plain text, with `quoted` parts muted.
    static func text(_ parts: [(String, Bool)]) -> AttributedString {
        var out = AttributedString()
        for (string, muted) in parts {
            var part = AttributedString(string)
            if muted { part.foregroundColor = Crystal.ink2 }
            out += part
        }
        return out
    }

    static func quoted(_ list: [String]) -> String { list.map { "“\($0)”" }.joined(separator: ", ") }

    static func rows(_ item: TranscriptHistoryItem, diff: WordDiff?) -> [Row] {
        var rows: [Row] = []
        let edits = item.cleanupEdits ?? []
        let grouped = Dictionary(grouping: edits, by: \.kind)
        for kind in CleanupEdit.Kind.allCases {
            guard let list = grouped[kind], !list.isEmpty else { continue }
            switch kind {
            case .filler, .repetition, .restart:
                rows.append(Row(step: kind.stepName, result: text([("Removed ", false), (quoted(list.map(\.removed)), true)])))
            case .selfCorrection, .spokenCommand, .vocabulary:
                var parts: [(String, Bool)] = []
                for (i, edit) in list.enumerated() {
                    if i > 0 { parts.append(("; ", false)) }
                    parts.append(("“\(edit.removed)”", true))
                    parts.append((" became \(edit.inserted)", false))
                }
                rows.append(Row(step: kind.stepName, result: text(parts)))
            case .punctuation:
                rows.append(Row(step: kind.stepName, result: text([("\(list.count) mark\(list.count == 1 ? "" : "s") added or changed", false)])))
            case .formatting:
                rows.append(Row(step: kind.stepName,
                                result: text([("\(list.count) change\(list.count == 1 ? "" : "s") to capitals, spacing or layout", false)])))
            }
        }
        if edits.isEmpty, let diff, !diff.isUnchanged {
            rows.append(Row(step: "Words", result: text([("\(diff.removedCount) removed, \(diff.addedCount) added", false)])))
        }
        if let style = DictationText.styleName(item.style) {
            var parts: [(String, Bool)] = [("\(style) for \(DictationText.appName(item))", false)]
            if let reason = item.styleReason { parts.append((" · \(reason)", true)) }
            rows.append(Row(step: "Style", result: text(parts)))
        }
        return rows
    }
}

extension CleanupEdit.Kind {
    var stepName: String {
        switch self {
        case .filler: "Filler words"
        case .repetition: "Repeated words"
        case .restart: "False starts"
        case .selfCorrection: "Self-correction"
        case .spokenCommand: "Spoken commands"
        case .punctuation: "Punctuation"
        case .formatting: "Formatting"
        case .vocabulary: "Vocabulary"
        }
    }
}

/// The word diff: what you said against what was pasted, in mono, blue for added and orange for
/// removed (struck through).
private struct DiffCard: View {
    var diff: WordDiff
    @Environment(AppModel.self) private var model

    var body: some View {
        let changes = diff.changeCount
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("\(changes) edit\(changes == 1 ? "" : "s") vs what you said").font(.system(size: 14)).foregroundStyle(Crystal.ink)
                Text("+\(diff.addedCount)").font(.mono(12)).foregroundStyle(Crystal.info)
                Text("−\(diff.removedCount)").font(.mono(12)).foregroundStyle(Crystal.removed)
                Spacer()
                IconButton(symbol: "doc.on.doc", label: "Copy the diff", size: 24) {
                    TextInserter.copy(plain)
                    model.notify("Copied the diff")
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.vertical, 7)
            Text(attributed)
                .lineSpacing(6)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            .font(.mono(12.5))
            .padding(.horizontal, 14)
            .padding(.top, 2)
            .padding(.bottom, 14)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken)
        }
        .background(Crystal.card, in: .rect(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Crystal.hairlineSoft))
    }

    /// Kept words muted; additions blue on a blue wash; removals orange, struck, on an orange wash.
    private var attributed: AttributedString {
        var out = AttributedString()
        for (i, run) in diff.runs.enumerated() {
            if i > 0 { out += AttributedString(" ") }
            var part = AttributedString(run.text)
            switch run.kind {
            case .same:
                part.foregroundColor = Crystal.ink2
            case .added:
                part.foregroundColor = Crystal.info
                part.backgroundColor = Crystal.info.opacity(0.12)
            case .removed:
                part.foregroundColor = Crystal.removed
                part.backgroundColor = Crystal.removed.opacity(0.10)
                part.strikethroughStyle = Text.LineStyle(pattern: .solid, color: Crystal.removed.opacity(0.6))
            }
            out += part
        }
        return out
    }

    private var plain: String {
        diff.runs.map { run in
            switch run.kind {
            case .same: run.text
            case .added: "{+\(run.text)+}"
            case .removed: "[-\(run.text)-]"
            }
        }.joined(separator: " ")
    }

    private var spoken: String {
        diff.runs.compactMap { run in
            switch run.kind {
            case .same: nil
            case .added: "added \(run.text)"
            case .removed: "removed \(run.text)"
            }
        }.joined(separator: "; ")
    }
}

// MARK: - Actions

/// What can be done with it: open its app, copy, paste again, its style, transcribe again, delete.
private struct ActionsCard: View {
    var item: TranscriptHistoryItem
    @Environment(AppModel.self) private var model
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.canOpenApp(item) {
                ActionRow(label: "Open \(DictationText.appName(item))", accessory: .symbol("arrow.up.right.square")) {
                    AppMonogram(appName: DictationText.monogramName(item), bundleID: item.appBundleId)
                } action: { model.openApp(item) }
            }
            ActionRow(label: "Copy text", accessory: .keys("⇧⌘C")) { icon("doc.on.doc") } action: { model.copy(item) }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            if !item.isBarkNote {
                ActionRow(label: "Paste again", accessory: .none) { icon("doc.on.clipboard") } action: { model.pasteAgain(item) }
            }
            ActionRow(label: "Edit text", accessory: .keys("⏎")) { icon("pencil") } action: { model.editRequest += 1 }
            Rectangle().fill(Crystal.hairline).frame(height: 1).padding(.horizontal, 2).padding(.vertical, 6)
            StyleMenuRow(item: item)
            if model.retryingDictations.contains(item.id) {
                InfoRow(symbolView: AnyView(ProgressView().controlSize(.small)), title: "Transcribing again", detail: nil, help: nil)
            } else if model.canRetry(item) {
                ActionRow(label: "Retry", detail: "with \(model.models.activeModel.shortName)", accessory: .none) {
                    icon("arrow.counterclockwise")
                } action: { model.retry(item) }
            }
            AddToDictionaryRow(item: item)
            ActionRow(label: "Delete", accessory: .keys("⌫"), destructive: true) {
                Image(systemName: "trash").font(.system(size: 14)).foregroundStyle(Crystal.error)
            } action: { confirmDelete = true }
            if let notice = model.dictationNotice {
                Text(notice)
                    .font(.system(size: 12))
                    .foregroundStyle(Crystal.ink3)
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
                    .padding(.bottom, 2)
                    .transition(.opacity)
            }
        }
        .padding(6)
        .background(Crystal.card, in: .rect(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Crystal.hairline))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Actions")
        .confirmationDialog("Delete this dictation?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                model.deleteDictation(item.id, visible: model.history.visible(query: model.historyQuery, filter: model.historyFilter))
            }
        } message: {
            Text("“\(DictationText.title(item))” is removed from history. This can't be undone.")
        }
    }

    private func icon(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(Crystal.ink2)
    }
}

private struct ActionRow<Icon: View>: View {
    enum Accessory { case none, keys(String), symbol(String) }
    var label: String
    var detail: String?
    var accessory: Accessory
    var destructive = false
    @ViewBuilder var icon: Icon
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                icon.frame(width: 18)
                Text(label).foregroundStyle(destructive ? Crystal.error : Crystal.ink).lineLimit(1)
                if let detail { Text(detail).foregroundStyle(Crystal.ink2).lineLimit(1) }
                Spacer(minLength: 6)
                switch accessory {
                case .none: EmptyView()
                case .keys(let keys): Keycap(label: keys)
                case .symbol(let symbol): Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(Crystal.ink2)
                }
            }
            .font(.system(size: 14))
            .padding(.horizontal, 8)
            .frame(height: 34)
            .background(hovered ? Crystal.selected : .clear, in: .rect(cornerRadius: 6, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(detail.map { "\(label) \($0)" } ?? label)
    }
}

/// The dictation's style, and a menu to restyle it: the formatter runs again on what was heard
/// and the result is saved. "Always use" makes the style the rule for its app or site.
private struct StyleMenuRow: View {
    var item: TranscriptHistoryItem
    @Environment(AppModel.self) private var model
    @State private var hovered = false

    var body: some View {
        let current = item.styleID
        let target = model.alwaysUseTarget(for: item)
        Menu {
            Picker("Restyle as", selection: Binding(get: { current ?? .clean }, set: { model.restyle(item, as: $0) })) {
                ForEach(DictationStyle.all) { style in Text(style.name).tag(style.id) }
            }
            .pickerStyle(.inline)
            if let current, let target {
                Divider()
                Button("Always Use \(current.displayName) in \(target.label)") { model.alwaysUseStyle(of: item) }
                    .disabled(alreadyTheRule(current))
            }
        } label: {
            HStack(spacing: 10) {
                TypeGlyph(size: 15, color: Crystal.ink2).frame(width: 18)
                Text(current?.displayName ?? "No style").foregroundStyle(Crystal.ink)
                Text("style").foregroundStyle(Crystal.ink2)
                Spacer(minLength: 6)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Crystal.ink2)
            }
            .font(.system(size: 14))
            .padding(.horizontal, 8)
            .frame(height: 34)
            .background(hovered ? Crystal.selected : .clear, in: .rect(cornerRadius: 6, style: .continuous))
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .onHover { hovered = $0 }
        .help(item.styleReason.map { "Chosen by: \($0). Restyle as another style." } ?? "Restyle as another style")
        .accessibilityLabel("Style, \(current?.displayName ?? "none")")
        .accessibilityHint("Restyles this dictation from what you said")
    }

    /// The style is already what the rules give its app or site.
    private func alreadyTheRule(_ style: DictationStyle.ID) -> Bool {
        let resolution = model.settings.settings.styleRules.resolve(model.destination(of: item))
        return (resolution.source == .app || resolution.source == .site) && resolution.style == style
    }
}

/// "Add “Aoife” to Dictionary" for a name-like word in the text, or a field to type one.
private struct AddToDictionaryRow: View {
    var item: TranscriptHistoryItem
    @Environment(AppModel.self) private var model
    @State private var asking = false
    @State private var word = ""

    var body: some View {
        let candidate = model.dictionaryCandidate(in: item)
        ActionRow(label: candidate.map { "Add “\($0)” to Dictionary" } ?? "Add to Dictionary…", accessory: .none) {
            Image(systemName: "book.closed").font(.system(size: 14)).foregroundStyle(Crystal.ink2)
        } action: {
            if let candidate {
                model.addToDictionary(candidate)
            } else {
                word = ""
                asking = true
            }
        }
        .contextMenu {
            Button("Add Another Word…") { word = candidate ?? ""; asking = true }
        }
        .popover(isPresented: $asking, arrowEdge: .leading) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Add to Dictionary").font(.system(size: 13, weight: .semibold)).foregroundStyle(Crystal.ink)
                Text("Spelt your way in every dictation from now on.").font(.system(size: 12)).foregroundStyle(Crystal.ink2)
                HStack(spacing: 8) {
                    SettingsTextField("Word", text: $word, prompt: "A name or a term", onSubmit: add).frame(width: 180)
                    Button("Add", action: add).buttonStyle(PrimaryButtonStyle())
                        .disabled(word.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(14)
        }
    }

    private func add() {
        let clean = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        model.addToDictionary(clean)
        asking = false
    }
}

private struct InfoRow: View {
    var symbolView: AnyView
    var title: String
    var detail: String?
    var help: String?

    var body: some View {
        HStack(spacing: 10) {
            symbolView.frame(width: 18)
            Text(title).foregroundStyle(Crystal.ink)
            if let detail { Text(detail).foregroundStyle(Crystal.ink2) }
            Spacer(minLength: 0)
        }
        .font(.system(size: 14))
        .padding(.horizontal, 8)
        .frame(height: 34)
        .help(help ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityHint(help ?? "")
    }
}

// MARK: - Composer

/// Docked at the bottom: correct the text. Clicking in starts from the text as it is; ⏎ saves
/// it to history, ⇧⏎ starts a new line, esc puts it back.
private struct CorrectionComposer: View {
    var item: TranscriptHistoryItem
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @State private var editing = false
    @FocusState private var focused: Bool

    var body: some View {
        let dirty = editing && draft.trimmingCharacters(in: .whitespacesAndNewlines) != item.text && !draft.isEmpty
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                if !editing {
                    Text("Correct the text: click here, change it, press ⏎ to save")
                        .font(.system(size: 15))
                        .foregroundStyle(Crystal.ink2)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $draft)
                    .font(.system(size: 15))
                    .foregroundStyle(Crystal.ink)
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .frame(minHeight: 24, maxHeight: 180)
                    .fixedSize(horizontal: false, vertical: true)
                    .onKeyPress(.return, phases: .down) { press in
                        // ⇧⏎ is a new line; ⏎ while an input method is composing commits the text.
                        if press.modifiers.contains(.shift) || Self.isComposing { return .ignored }
                        save()
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        cancel()
                        return .handled
                    }
                    .accessibilityLabel("Correct the text")
                    .accessibilityHint("Return saves, Escape puts it back")
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            HStack(spacing: 4) {
                if let style = DictationText.styleName(item.style) {
                    HStack(spacing: 6) {
                        TypeGlyph(size: 13, color: Crystal.ink2)
                        Text(style)
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Crystal.ink)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                }
                if editing {
                    Text(dirty ? "⏎ saves · esc puts it back" : "esc to stop editing")
                        .font(.system(size: 12)).foregroundStyle(Crystal.ink3).padding(.leading, 6)
                }
                Spacer()
                if let model = item.model {
                    HStack(spacing: 6) {
                        Image(systemName: item.location == "remote-host" ? "server.rack" : "laptopcomputer").font(.system(size: 12))
                        Text(SpeechModelCatalog.model(id: model)?.shortName ?? model)
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Crystal.ink2)
                    .padding(.horizontal, 8)
                    .help("Heard by this model")
                }
                Button(action: save) {
                    Image(systemName: "arrow.up").font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(dirty ? Crystal.onAccent : Crystal.ink2)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(dirty ? Crystal.primary : Crystal.hairline))
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .disabled(!dirty)
                .help("Save the corrected text (⏎)")
                .accessibilityLabel("Save the corrected text")
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
        .background(Crystal.card, in: .rect(cornerRadius: Radius.composer, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.composer, style: .continuous)
            .strokeBorder(focused ? Crystal.input : Crystal.hairline))
        .composerShadow()
        .background(Crystal.canvas.padding(.top, 20).padding(.bottom, -16))
        .onChange(of: focused) { _, now in if now { begin() } }
        .onChange(of: model.editRequest) { begin(); focused = true }
    }

    /// An input method has marked text in the focused field (a candidate not yet committed).
    private static var isComposing: Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() ?? false
    }

    private func begin() {
        guard !editing else { return }
        draft = item.text
        editing = true
    }

    private func save() {
        guard editing else { return }
        model.correct(item, to: draft)
        cancel()
    }

    private func cancel() {
        editing = false
        draft = ""
        focused = false
    }
}
