import FairspokenUI
import FairspokenCore
import FairspokenWhisper
import SwiftUI

/// The Models library: every speech model the app can run, as a dense table with search,
/// filters and sorting. A row opens a detail sheet; the control at the right downloads, shows
/// progress (stop to cancel) or says the model is in use.
struct ModelsView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ModelCatalogueQuery()
    @State private var pendingDelete: SpeechModelInfo?

    var body: some View {
        let library = model.models
        let rows = query.apply(to: SpeechModelCatalog.all, installed: library.installedIDs,
                               favourites: Set(model.settings.settings.favoriteModels))
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.gap) {
                PageTitle("Models", subtitle: "Speech recognition on this Mac's Neural Engine")
                    .padding(.bottom, 4)
                ModelFilterBar(query: $query)
                ContentCard {
                    VStack(spacing: 0) {
                        ModelTableHeader(sort: $query.sort)
                        Hairline()
                        if rows.isEmpty {
                            Text("No models match. Clear the search or a filter.")
                                .font(.contentBody).foregroundStyle(Crystal.ink3)
                                .frame(maxWidth: .infinity, minHeight: 80)
                        }
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, info in
                            if index > 0 { Hairline(inset: ContentMetrics.rowPadding) }
                            ModelRow(info: info, open: { model.modelDetailID = info.id }, delete: { pendingDelete = info })
                        }
                    }
                }
                Text("Speed and accuracy: measured on an M4 Mac with the app's own engines, on 20 LibriSpeech test-clean clips (147 s). Rows marked “published” use the authors' figures.")
                    .font(.caption).foregroundStyle(Crystal.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal, Layout.pageH)
            .padding(.vertical, Layout.pageTop)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .onAppear { library.refresh() }
        .sheet(isPresented: Binding(get: { model.modelDetailID != nil }, set: { if !$0 { model.modelDetailID = nil } })) {
            if let info = model.modelDetailID.flatMap(SpeechModelCatalog.model(id:)) {
                ModelDetailSheet(info: info, delete: { pendingDelete = info })
                    .environment(model)
            }
        }
        .confirmationDialog("Delete \(pendingDelete?.name ?? "")?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let id = pendingDelete?.id { library.delete(id) }
                pendingDelete = nil
            }
        } message: {
            Text("This removes \(Format.bytes(library.diskBytes[pendingDelete?.id ?? ""] ?? pendingDelete?.approxBytes ?? 0)) of model files. You can download it again at any time.")
        }
    }
}

// MARK: Filters

private struct ModelFilterBar: View {
    @Binding var query: ModelCatalogueQuery

    var body: some View {
        HStack(spacing: 10) {
            ContentSearchField(text: $query.search, prompt: "Search models")
                .frame(maxWidth: 260)
            Picker("Engine", selection: $query.engine) {
                Text("All engines").tag(SpeechEngineKind?.none)
                ForEach(SpeechEngineKind.allCases) { kind in
                    Text(kind.label).tag(SpeechEngineKind?.some(kind))
                }
            }
            .fixedSize()
            Picker("Language", selection: $query.language) {
                ForEach(ModelCatalogueQuery.LanguageFilter.allCases) { Text($0.label).tag($0) }
            }
            .fixedSize()
            Toggle("Downloaded", isOn: $query.downloadedOnly).toggleStyle(.button)
            Toggle("On this Mac", isOn: $query.localOnly).toggleStyle(.button)
                .help("Models that run on this Mac (remote endpoints are coming)")
            Spacer(minLength: 0)
            Picker("Sort", selection: $query.sort) {
                ForEach(ModelCatalogueQuery.Sort.allCases) { Text($0.label).tag($0) }
            }
            .fixedSize()
        }
        .labelsHidden()
        .controlSize(.small)
        .font(.contentBody)
    }
}

// MARK: Table

/// Column widths shared by the header and every row.
private enum Column {
    static let star: CGFloat = 18
    static let engine: CGFloat = 22
    static let bar: CGFloat = 64
    static let size: CGFloat = 64
    static let action: CGFloat = 112
}

private struct ModelTableHeader: View {
    @Binding var sort: ModelCatalogueQuery.Sort

    var body: some View {
        HStack(spacing: ContentMetrics.columnSpacing) {
            Color.clear.frame(width: Column.star, height: 1)
            SortHeader("Name", active: sort == .name) { sort = .name }
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Engine").font(.contentCaption).foregroundStyle(Crystal.ink3)
                .frame(width: Column.engine + 22, alignment: .center)
            SortHeader("Speed", active: sort == .speed) { sort = .speed }.frame(width: Column.bar, alignment: .leading)
            SortHeader("Accuracy", active: sort == .accuracy) { sort = .accuracy }.frame(width: Column.bar, alignment: .leading)
            SortHeader("Size", active: sort == .size) { sort = .size }.frame(width: Column.size, alignment: .trailing)
            Color.clear.frame(width: Column.action, height: 1)
        }
        .padding(.horizontal, ContentMetrics.rowPadding)
        .frame(height: 28)
    }
}

struct ModelRow: View {
    var info: SpeechModelInfo
    var open: () -> Void
    var delete: () -> Void
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let library = model.models
        let favourite = model.settings.settings.favoriteModels.contains(info.id)
        HStack(spacing: ContentMetrics.columnSpacing) {
            Button { model.toggleFavourite(info.id) } label: {
                Image(systemName: favourite ? "star.fill" : "star")
                    .foregroundStyle(favourite ? Crystal.warn : Crystal.ink3.opacity(hovering ? 1 : 0.5))
                    .frame(width: Column.star)
            }
            .buttonStyle(.plain)
            .help(favourite ? "Remove from favourites" : "Add to favourites (listed first)")
            .accessibilityLabel(favourite ? "Remove \(info.name) from favourites" : "Add \(info.name) to favourites")

            HStack(spacing: 6) {
                Text(info.name).font(.contentBody.weight(.medium)).foregroundStyle(Crystal.ink).lineLimit(1)
                ModelBadges(info: info, inUse: library.activeModelID == info.id)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            EngineIcon(engine: info.engine).frame(width: Column.engine + 22)
            ScoreBar(value: info.speed, label: "Speed").frame(width: Column.bar, alignment: .leading)
                .help(info.rtfx.map { String(format: "%.0f× real time", $0) } ?? "")
            ScoreBar(value: info.accuracy, label: "Accuracy").frame(width: Column.bar, alignment: .leading)
                .help(info.wer.map { String(format: "%.1f%% word error rate", $0) } ?? "")
            Text(Format.bytes(library.diskBytes[info.id] ?? info.approxBytes))
                .font(.contentBody).monospacedDigit().foregroundStyle(Crystal.ink2)
                .frame(width: Column.size, alignment: .trailing)
            ModelActionControl(info: info, delete: delete).frame(width: Column.action, alignment: .trailing)
        }
        .padding(.horizontal, ContentMetrics.rowPadding)
        .frame(minHeight: ContentMetrics.rowHeight)
        .background(hovering ? Crystal.rowHover : .clear)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Show details", open)
    }
}

/// EN, NEW, Recommended, In use, beside a model's name.
struct ModelBadges: View {
    var info: SpeechModelInfo
    var inUse: Bool

    var body: some View {
        HStack(spacing: 4) {
            if inUse { Badge("In use", style: .positive) }
            if info.isRecommended { Badge("Recommended", style: .accent) }
            if info.englishOnly { Badge("EN", style: .outline).help("English only") }
            if info.isNew { Badge("NEW") }
            if info.isExperimental { Badge("Slow", style: .outline).help("Slow on the Neural Engine") }
        }
    }
}

struct EngineIcon: View {
    var engine: SpeechEngineKind
    var body: some View {
        Image(systemName: engine.symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Crystal.ink2)
            .frame(width: 22, height: 22)
            .background(Crystal.well, in: .rect(cornerRadius: 6, style: .continuous))
            .help("\(engine.label) · \(engine.runtime)")
            .accessibilityLabel("\(engine.label) engine")
    }
}

/// Download, progress with stop, Use, or In use: the right-hand control of a row.
struct ModelActionControl: View {
    var info: SpeechModelInfo
    var delete: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        let library = model.models
        let active = library.activeModelID == info.id
        HStack(spacing: 6) {
            switch library.state(of: info.id) {
            case .available:
                if library.downloadErrors[info.id] != nil {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Crystal.error)
                        .help(library.downloadErrors[info.id] ?? "")
                }
                Button("Download") { library.download(info.id) }
                    .help("Download \(Format.bytes(info.approxBytes))")
            case .downloading(let fraction):
                Text("\(Int(fraction * 100))%").font(.contentBody).monospacedDigit().foregroundStyle(Crystal.ink2)
                ProgressStopButton(fraction: fraction, action: { stop(library) })
                    .disabled(!library.isDownloading(info.id))
            case .unpacking, .compiling:
                Text(library.state(of: info.id) == .compiling ? "Optimising…" : "Unpacking…")
                    .font(.contentBody).foregroundStyle(Crystal.ink2).lineLimit(1)
                ProgressView().controlSize(.small)
            case .installed:
                if active {
                    let engine = library.engineState
                    if engine.isReady {
                        Label("In use", systemImage: "checkmark.circle.fill")
                            .font(.contentBody.weight(.medium)).foregroundStyle(Crystal.ok)
                    } else {
                        StatusDot(color: engine.tint, pulsing: engine.isBusy)
                        Text(engine.isBusy ? "Loading…" : "Failed").font(.contentBody).foregroundStyle(Crystal.ink2)
                            .help(engine.label)
                    }
                } else {
                    Menu {
                        Button("Delete…", role: .destructive, action: delete)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.borderless).fixedSize()
                    .accessibilityLabel("More for \(info.name)")
                    Button("Use") { model.useModel(info.id) }
                }
            }
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
    }

    private func stop(_ library: ModelLibrary) { library.cancelDownload(info.id) }
}

// MARK: Detail

struct ModelDetailSheet: View {
    var info: SpeechModelInfo
    var delete: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let library = model.models
        let state = library.state(of: info.id)
        let active = library.activeModelID == info.id
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                EngineIcon(engine: info.engine).scaleEffect(1.4).frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text(info.name).font(.title3.weight(.semibold)).foregroundStyle(Crystal.ink)
                    HStack(spacing: 6) {
                        Text("\(info.publisher) · \(info.family) · \(info.engine.runtime)")
                            .font(.contentBody).foregroundStyle(Crystal.ink2)
                        ModelBadges(info: info, inUse: active)
                    }
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Close")
            }
            Text(info.summary + " " + info.details)
                .font(.contentBody).foregroundStyle(Crystal.ink)
                .fixedSize(horizontal: false, vertical: true)

            ContentCard(padding: 14) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 9) {
                    GridRow {
                        label("Speed")
                        ScoreBar(value: info.speed, label: "Speed")
                        value(info.rtfx.map { String(format: "%.0f× real time", $0) } ?? "Not measured")
                    }
                    GridRow {
                        label("Accuracy")
                        ScoreBar(value: info.accuracy, label: "Accuracy")
                        value(info.wer.map { String(format: "%.1f%% word error rate", $0) } ?? "Not measured")
                    }
                    GridRow {
                        Color.clear.frame(width: 1, height: 1)
                        Text(sourceNote).font(.caption).foregroundStyle(Crystal.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                            .gridCellColumns(2)
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow { label("Languages"); value(info.languages).gridCellColumns(2) }
                    GridRow { label("Download"); value(Format.bytes(info.approxBytes)).gridCellColumns(2) }
                    GridRow { label("Memory"); value("About \(Format.bytes(info.memoryBytes)) while in use").gridCellColumns(2) }
                    GridRow { label("Runs on"); value("\(info.placement.label) · on this Mac").gridCellColumns(2) }
                    GridRow { label("Licence"); value(info.license).gridCellColumns(2) }
                    GridRow {
                        label("Source")
                        if let url = info.sourceURL {
                            Link(info.variant.map { "\(info.repository)/\($0)" } ?? info.repository, destination: url)
                                .font(.contentBody).lineLimit(1).truncationMode(.middle)
                                .gridCellColumns(2)
                        }
                    }
                }
            }

            if SpeechModels.supportsLinks(info.id) { linkSection(state: state) }
            if let error = library.downloadErrors[info.id] {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Crystal.error)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }

            HStack(spacing: 10) {
                if state == .installed, !active {
                    Button("Delete…", role: .destructive) {
                        dismiss()
                        delete()
                    }
                }
                Spacer()
                switch state {
                case .downloading(let f):
                    ProgressView(value: f).frame(width: 120).tint(Crystal.clientAccent)
                    Button("Stop") { library.cancelDownload(info.id) }.disabled(!library.isDownloading(info.id))
                case .unpacking, .compiling:
                    ProgressView().controlSize(.small)
                    Text(state == .compiling ? "Optimising for this device…" : "Unpacking…").font(.contentBody).foregroundStyle(Crystal.ink2)
                case .available:
                    // The link editor has its own Download.
                    if model.linkEditorModel != info.id {
                        Button("Download") { library.download(info.id) }
                    }
                case .installed:
                    EmptyView()
                }
                Button(active ? "In use" : "Use this model") {
                    model.useModel(info.id)
                    dismiss()
                }
                .buttonStyle(.borderedProminent).tint(Crystal.clientAccent)
                .disabled(active || state.isBusy)
                .help(state == .available ? "Downloads the model, then uses it for dictation" : "Use it for dictation")
            }
            .controlSize(.regular)
        }
        .padding(22)
        .frame(width: 520)
    }

    private var sourceNote: String {
        switch info.scoreSource {
        case .measured: "Measured on an M4 Mac: 20 LibriSpeech test-clean clips, median of warm runs."
        case .published: "Published figures (LibriSpeech test-clean), not measured on this Mac."
        case .none: "No figures yet; bars are an estimate."
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.contentBody).foregroundStyle(Crystal.ink2)
    }

    private func value(_ text: String) -> some View {
        Text(text).font(.contentBody).foregroundStyle(Crystal.ink).monospacedDigit()
    }

    /// "Download from Link…" and the saved link, for models that install from an archive.
    @ViewBuilder private func linkSection(state: ModelLibrary.ItemState) -> some View {
        let saved = model.settings.settings.modelLinks[info.id]
        if model.linkEditorModel == info.id, state == .available {
            ModelLinkEditor(text: Bindable(model).linkDraft, tint: Crystal.clientAccent,
                            submit: { model.downloadFromLink(info.id, $0) },
                            cancel: { model.linkEditorModel = nil })
        } else if saved != nil || state == .available {
            VStack(alignment: .leading, spacing: 6) {
                if let saved { ModelLinkSummary(link: saved) }
                HStack(spacing: 14) {
                    if state == .available {
                        Button("Download from Link…") { model.openLinkEditor(for: info.id) }
                    }
                    if saved != nil {
                        Button("Use Standard Download") { model.removeModelLink(info.id) }
                            .help("Download this model the usual way instead of from the link")
                    }
                }
                .buttonStyle(.link).font(.caption)
            }
        }
    }
}
