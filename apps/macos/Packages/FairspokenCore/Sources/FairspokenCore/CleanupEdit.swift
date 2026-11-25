import Foundation

/// One change cleanup made to what was said, in transcript order: a filler dropped, a repeat or
/// false start removed, a self-correction repaired, a spoken command or punctuation applied.
/// `removed` is the text as heard; `inserted` what replaced it (empty when it was just dropped).
public struct CleanupEdit: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case filler, repetition, restart, selfCorrection, spokenCommand, punctuation, formatting, vocabulary
    }

    public var kind: Kind
    public var removed: String
    public var inserted: String

    public init(kind: Kind, removed: String, inserted: String = "") {
        self.kind = kind
        self.removed = removed
        self.inserted = inserted
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // An unknown kind from a newer build reads as formatting rather than failing the item.
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .formatting
        removed = (try? c.decode(String.self, forKey: .removed)) ?? ""
        inserted = (try? c.decode(String.self, forKey: .inserted)) ?? ""
    }
}
