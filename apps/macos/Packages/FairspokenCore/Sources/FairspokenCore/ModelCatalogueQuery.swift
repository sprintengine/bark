import Foundation

/// What the Models library shows: search text, filters and sort order, applied to the catalogue.
public struct ModelCatalogueQuery: Equatable, Sendable {
    public enum LanguageFilter: String, CaseIterable, Sendable, Identifiable {
        case any, englishOnly, multilingual
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .any: "Any language"
            case .englishOnly: "English only"
            case .multilingual: "Multilingual"
            }
        }
    }

    public enum Sort: String, CaseIterable, Sendable, Identifiable {
        case recommended, name, speed, accuracy, size
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .recommended: "Recommended"
            case .name: "Name"
            case .speed: "Speed"
            case .accuracy: "Accuracy"
            case .size: "Size"
            }
        }
    }

    public var search = ""
    /// nil for every engine.
    public var engine: SpeechEngineKind?
    public var language: LanguageFilter = .any
    public var downloadedOnly = false
    public var localOnly = false
    public var sort: Sort = .recommended

    public init(search: String = "", engine: SpeechEngineKind? = nil, language: LanguageFilter = .any,
                downloadedOnly: Bool = false, localOnly: Bool = false, sort: Sort = .recommended) {
        self.search = search
        self.engine = engine
        self.language = language
        self.downloadedOnly = downloadedOnly
        self.localOnly = localOnly
        self.sort = sort
    }

    /// True when any filter (not the search or the sort) narrows the list.
    public var isFiltered: Bool { engine != nil || language != .any || downloadedOnly || localOnly }

    /// Matching rows, favourites first, then in the chosen order (ties by catalogue order).
    /// Speed, accuracy and size sort best-first: fastest, most accurate, smallest.
    public func apply(to models: [SpeechModelInfo], installed: Set<String> = [], favourites: Set<String> = []) -> [SpeechModelInfo] {
        let terms = search.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let rows = models.enumerated().filter { _, m in
            if let engine, m.engine != engine { return false }
            switch language {
            case .any: break
            case .englishOnly: if !m.englishOnly { return false }
            case .multilingual: if m.englishOnly { return false }
            }
            if downloadedOnly, !installed.contains(m.id) { return false }
            if localOnly, !m.isLocal { return false }
            if !terms.isEmpty {
                let haystack = [m.id, m.name, m.family, m.publisher, m.engine.label, m.engine.runtime, m.languages, m.summary]
                    .joined(separator: " ").lowercased()
                if !terms.allSatisfy(haystack.contains) { return false }
            }
            return true
        }
        return rows.sorted { a, b in
            let fa = favourites.contains(a.element.id), fb = favourites.contains(b.element.id)
            if fa != fb { return fa }
            if let order = Self.compare(a.element, b.element, by: sort) { return order }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// True/false when `a` and `b` differ on `sort`, nil on a tie.
    private static func compare(_ a: SpeechModelInfo, _ b: SpeechModelInfo, by sort: Sort) -> Bool? {
        switch sort {
        case .recommended:
            if a.isRecommended != b.isRecommended { return a.isRecommended }
            return nil
        case .name:
            let c = a.name.localizedStandardCompare(b.name)
            return c == .orderedSame ? nil : c == .orderedAscending
        case .speed:
            if a.speed != b.speed { return a.speed > b.speed }
            if let x = a.rtfx, let y = b.rtfx, x != y { return x > y }
            return nil
        case .accuracy:
            if a.accuracy != b.accuracy { return a.accuracy > b.accuracy }
            if let x = a.wer, let y = b.wer, x != y { return x < y }
            return nil
        case .size:
            return a.approxBytes == b.approxBytes ? nil : a.approxBytes < b.approxBytes
        }
    }
}
