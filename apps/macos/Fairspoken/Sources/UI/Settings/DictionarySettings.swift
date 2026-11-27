import FairspokenCore
import FairspokenUI
import SwiftUI

/// Settings › Dictionary: your terms, corrections, what Bark learned from your edits, and packs.
enum DictionarySettings {
    typealias Row = SettingsCatalog.Row
    typealias Section = SettingsCatalog.Section

    @MainActor
    static func sections(_ model: AppModel) -> [Section] {
        let s = model.settings.settings
        let suggestions = model.learned.suggestions
        var out: [Section] = []
        if !suggestions.isEmpty {
            out.append(Section("Suggestions",
                               rows: suggestions.map { item in
                                   Row(id: "suggestion-\(item.id)", searchText: "Suggestion learned \(item.heard) \(item.intended)",
                                       view: SuggestionRow(item: item))
                               }))
        }
        var terms: [Row] = [Row(id: "term-add", searchText: "Add a term word name dictionary vocabulary", view: AddTermRow())]
        terms += s.vocabularyHints.map { term in
            Row(id: "term-\(term)", searchText: "term word dictionary vocabulary \(term)", view: TermRow(term: term))
        }
        var corrections: [Row] = [Row(id: "correction-add", searchText: "Add a correction heard replace with misheard",
                                      view: AddCorrectionRow())]
        corrections += s.transcriptCorrections.enumerated().map { index, c in
            Row(id: "correction-\(index)-\(c.from)", searchText: "correction misheard replace \(c.from) \(c.to)",
                view: CorrectionRow(correction: c, index: index))
        }
        out += [
            Section("Your words",
                    trailing: AnyView(Count(used: s.vocabularyHints.count, of: AppSettings.maxVocabularyHints)), rows: terms),
            Section("Corrections",
                    trailing: AnyView(Count(used: s.transcriptCorrections.count, of: AppSettings.maxCorrections)), rows: corrections),
            Section("Learning", rows: [
                Row(id: "learn", searchText: "Learn from your corrections edits automatic learned", view: LearningRow()),
            ]),
            Section("Packs",
                    rows: VocabularyPacks.all.map { pack in
                        Row(pack.name, detail: pack.description, keywords: "pack vocabulary terms", id: "pack-\(pack.id)") {
                            SettingSwitch(label: pack.name, isOn: Binding(get: { model.settings.settings.enabledPacks.contains(pack.id) }, set: { on in
                                model.settings.update { s in
                                    s.enabledPacks.removeAll { $0 == pack.id }
                                    if on { s.enabledPacks.append(pack.id) }
                                }
                            }))
                        }
                    }),
        ]
        return out
    }
}

/// "12 of 50".
private struct Count: View {
    var used: Int
    var of: Int
    var body: some View {
        Text("\(used) of \(of)").font(.system(size: 12)).monospacedDigit().foregroundStyle(Crystal.ink3)
    }
}

private struct AddTermRow: View {
    @Environment(AppModel.self) private var model
    @State private var term = ""

    var body: some View {
        let full = model.settings.settings.vocabularyHints.count >= AppSettings.maxVocabularyHints
        HStack(spacing: 8) {
            SettingsTextField("Add a word", text: $term, prompt: full ? "Your 50 are full: remove one to add another" : "A name, a medicine or a term",
                              onSubmit: add)
                .disabled(full)
            Button("Add", action: add).cardButton().disabled(!canAdd)
        }
        .padding(.horizontal, SettingsMetrics.rowH)
        .padding(.vertical, 10)
    }

    private var canAdd: Bool {
        let t = term.trimmingCharacters(in: .whitespaces)
        let hints = model.settings.settings.vocabularyHints
        return !t.isEmpty && hints.count < AppSettings.maxVocabularyHints && !hints.contains(t)
    }

    private func add() {
        guard canAdd else { return }
        model.addToDictionary(term.trimmingCharacters(in: .whitespacesAndNewlines))
        term = ""
    }
}

private struct TermRow: View {
    var term: String
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            Text(term).font(.system(size: 14, weight: .medium)).foregroundStyle(Crystal.ink).textSelection(.enabled)
            if model.settings.settings.learnedVocabularyHints.contains(term) { LearnedTag(help: "Learned from your corrections") }
            Spacer()
            RemoveButton(label: "Remove \(term)") {
                model.settings.update { $0.vocabularyHints.removeAll { $0 == term } }
            }
        }
        .padding(.horizontal, SettingsMetrics.rowH)
        .frame(minHeight: 40)
    }
}

private struct AddCorrectionRow: View {
    @Environment(AppModel.self) private var model
    @State private var heard = ""
    @State private var replacement = ""

    var body: some View {
        HStack(spacing: 8) {
            SettingsTextField("Heard as", text: $heard, prompt: "Heard as", onSubmit: add)
            Image(systemName: "arrow.right").font(.system(size: 11, weight: .medium)).foregroundStyle(Crystal.ink3).accessibilityHidden(true)
            SettingsTextField("Replace with", text: $replacement, prompt: "Replace with", onSubmit: add)
            Button("Add", action: add).cardButton().disabled(!canAdd)
        }
        .padding(.horizontal, SettingsMetrics.rowH)
        .padding(.vertical, 10)
    }

    private var canAdd: Bool {
        model.settings.settings.transcriptCorrections.count < AppSettings.maxCorrections
            && !heard.trimmingCharacters(in: .whitespaces).isEmpty && !replacement.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func add() {
        guard canAdd else { return }
        model.settings.update { $0.transcriptCorrections.append(TranscriptCorrection(from: heard, to: replacement)) }
        heard = ""
        replacement = ""
    }
}

/// One correction: heard → replacement, its "Learned" marker, a switch and delete. A learned
/// correction that is deleted is never learned again.
private struct CorrectionRow: View {
    var correction: TranscriptCorrection
    var index: Int
    @Environment(AppModel.self) private var model

    var body: some View {
        let on = correction.enabled
        HStack(spacing: 8) {
            Text(correction.from).foregroundStyle(on ? Crystal.ink2 : Crystal.ink3)
            Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Crystal.ink3).accessibilityLabel("becomes")
            Text(correction.to).fontWeight(.medium).foregroundStyle(on ? Crystal.ink : Crystal.ink3)
            if correction.origin == .learned { LearnedTag(help: learnedHelp) }
            Spacer(minLength: 12)
            SettingSwitch(label: "Use “\(correction.from)” → “\(correction.to)”", isOn: Binding(get: { correction.enabled }, set: { v in
                model.settings.update { s in
                    guard s.transcriptCorrections.indices.contains(index) else { return }
                    s.transcriptCorrections[index].enabled = v
                }
            }))
            RemoveButton(label: "Delete correction \(correction.from)") {
                model.settings.update { s in
                    guard s.transcriptCorrections.indices.contains(index) else { return }
                    s.transcriptCorrections.remove(at: index)
                }
            }
        }
        .font(.system(size: 14))
        .padding(.horizontal, SettingsMetrics.rowH)
        .frame(minHeight: 44)
    }

    private var learnedHelp: String {
        let names = correction.models.map { id in
            id == "remote-host" ? "Bark Server" : (SpeechModelCatalog.model(id: id)?.shortName ?? id)
        }
        return names.isEmpty ? "Learned from your corrections."
            : "Learned from your corrections. Applies to \(names.joined(separator: ", "))."
    }
}

/// A fix Bark will not apply on its own, waiting for you.
private struct SuggestionRow: View {
    var item: LearnedItem
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsRow("\(item.heard) → \(item.intended)", detail: item.reason) {
            Button("Dismiss") { model.learned.dismiss(item.id) }.buttonStyle(GhostButtonStyle())
            Button("Accept") { model.learned.accept(item.id) }.cardButton()
        }
    }
}

private struct LearningRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.settings.settings
        let last = s.learnFromEdits ? model.learned.lastChange : nil
        SettingsRow("Learn from your corrections",
                    accessory: { EmptyView() },
                    below: {
                        if let last {
                            Label("Learned from your edit: \(last)", systemImage: "sparkles")
                                .font(.system(size: 12)).foregroundStyle(Crystal.info).padding(.top, 4)
                        }
                    },
                    control: { SettingSwitch(label: "Learn from your corrections", isOn: model.setting(\.learnFromEdits)) })
    }
}
