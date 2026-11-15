import Foundation

/// Learned dictionary entries (`src-tauri/src/learned.rs`): what the edit watcher saw the user
/// fix, and the rules that turn those fixes into vocabulary terms and corrections.
///
/// Each `heard → intended` pair is kept in `learned.json` with a sighting count and the speech
/// models that produced it. Only the word pair is stored, never the sentence around it.
/// Promotion:
/// - an uncommon capitalised name or term is added to the vocabulary the first time it is fixed;
/// - a mapping becomes a correction, scoped to those speech models, after it is seen twice;
/// - a mapping between two medicine-like words, a look-alike/sound-alike medicine, or a single
///   short word is never applied automatically: it waits in Suggestions for the user to accept
///   or dismiss.
///
/// Applied entries are marked `origin: learned` in settings. Once an item has been applied,
/// accepted or dismissed it is never promoted again, so a learned entry the user deletes stays
/// deleted.
public enum LearnedStatus: String, Codable, Sendable {
    /// Seen, not (yet) enough to act on.
    case observed
    /// Added to settings as a learned correction.
    case applied
    /// Waiting for the user on the Vocabulary screen.
    case suggested
    case accepted
    case dismissed
}

public struct LearnedItem: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var heard: String
    public var intended: String
    public var count: Int
    /// Epoch seconds.
    public var firstSeen: Int64
    public var lastSeen: Int64
    /// `AppSettings.speechModelID` of each model that produced `heard`.
    public var models: [String] = []
    /// The `heard → intended` correction's state.
    public var status: LearnedStatus = .observed
    /// `intended` has been offered to the vocabulary (added, or the dictionary was full); never
    /// offered twice.
    public var vocabulary = false
    /// Why a suggestion was not applied automatically.
    public var reason: String?

    public init(id: String = UUID().uuidString.lowercased(), heard: String, intended: String, count: Int = 1,
                firstSeen: Int64, lastSeen: Int64, models: [String] = [], status: LearnedStatus = .observed,
                vocabulary: Bool = false, reason: String? = nil) {
        self.id = id
        self.heard = heard
        self.intended = intended
        self.count = count
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.models = models
        self.status = status
        self.vocabulary = vocabulary
        self.reason = reason
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        heard = try c.decode(String.self, forKey: .heard)
        intended = try c.decode(String.self, forKey: .intended)
        count = c.lenientInt(.count) ?? 1
        firstSeen = Int64(c.lenientInt(.firstSeen) ?? 0)
        lastSeen = Int64(c.lenientInt(.lastSeen) ?? 0)
        models = c.lenient([String].self, .models) ?? []
        status = c.lenient(LearnedStatus.self, .status) ?? .observed
        vocabulary = c.lenient(Bool.self, .vocabulary) ?? false
        reason = c.lenient(String.self, .reason)
    }
}

/// A change to make in settings.
public enum Promotion: Equatable, Sendable {
    case vocabulary(String)
    case correction(from: String, to: String, models: [String])
}

/// The medicines in the bundled vocabulary packs (`is_drug_term` in vocabulary_packs.rs): each
/// `drug` term and its accepted spellings, compared ignoring case, spacing, hyphens and accents.
public struct DrugLexicon: Sendable {
    private let forms: Set<String>

    public static let empty = DrugLexicon(forms: [])

    public init(forms: Set<String>) { self.forms = forms }

    /// Reads a pack file (`src-tauri/packs/<id>.json`). Anything unreadable is an empty lexicon.
    public init(packs: [Data]) {
        struct Pack: Decodable {
            struct Term: Decodable {
                var term: String
                var accept: [String]?
                var category: String?
            }
            var terms: [Term]
        }
        var forms = Set<String>()
        for data in packs {
            guard let pack = try? JSONDecoder().decode(Pack.self, from: data) else { continue }
            for term in pack.terms where term.category == "drug" {
                for form in [term.term] + (term.accept ?? []) {
                    let key = Self.normalize(form)
                    if !key.isEmpty { forms.insert(key) }
                }
            }
        }
        self.forms = forms
    }

    public var isEmpty: Bool { forms.isEmpty }

    public func contains(_ term: String) -> Bool { forms.contains(Self.normalize(term)) }

    /// Lowercased, accents folded, letters and digits only (`phonetic_index::normalize`).
    static func normalize(_ text: String) -> String {
        String(text.lowercased().folding(options: [.diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber })
    }
}

public struct LearnedStore: Sendable {
    /// Sightings before a word mapping becomes a correction.
    public static let correctionSightings = 2
    /// Oldest items are forgotten beyond this many.
    public static let maxItems = 500

    public static let medicineReason = "Medicine names are never changed automatically. Check this before accepting it."
    public static let shortWordReason = "Short words are never replaced automatically."

    public private(set) var items: [LearnedItem]
    public var drugs: DrugLexicon

    public init(items: [LearnedItem] = [], drugs: DrugLexicon = .empty) {
        self.items = items
        self.drugs = drugs
    }

    // MARK: File

    private struct File: Codable {
        var items: [LearnedItem]
    }

    /// `learned.json`; a missing or unreadable file is an empty store.
    public static func load(_ data: Data?, drugs: DrugLexicon = .empty) -> LearnedStore {
        let items = data.flatMap { try? JSONDecoder().decode(File.self, from: $0) }?.items ?? []
        return LearnedStore(items: items, drugs: drugs)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(File(items: items))
    }

    // MARK: Learning

    public var suggestions: [LearnedItem] { items.filter { $0.status == .suggested } }

    /// Counts one sighting of `fix` from `model` and returns what it now earns.
    public mutating func observe(_ fix: Mishearing, model: String, now: Int64) -> [Promotion] {
        let heardKey = fix.heard.lowercased()
        let index: Int
        if let found = items.firstIndex(where: { $0.heard.lowercased() == heardKey && $0.intended == fix.intended }) {
            items[found].count += 1
            items[found].lastSeen = now
            index = found
        } else {
            items.append(LearnedItem(heard: fix.heard, intended: fix.intended, firstSeen: now, lastSeen: now))
            index = items.count - 1
        }
        if !model.isEmpty && !items[index].models.contains(model) { items[index].models.append(model) }
        let promotions = review(&items[index])
        forgetOldest()
        return promotions
    }

    /// Marks a suggestion accepted and returns the correction to apply.
    public mutating func accept(_ id: String) -> Promotion? {
        guard let index = items.firstIndex(where: { $0.id == id && $0.status == .suggested }) else { return nil }
        items[index].status = .accepted
        let item = items[index]
        return .correction(from: item.heard, to: item.intended, models: item.models)
    }

    @discardableResult
    public mutating func dismiss(_ id: String) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        items[index].status = .dismissed
        return true
    }

    private mutating func forgetOldest() {
        while items.count > Self.maxItems {
            // Suggestions wait for the user, so only settled items are dropped.
            let oldest = items.indices
                .filter { items[$0].status != .suggested }
                .min { items[$0].lastSeen < items[$1].lastSeen }
            guard let oldest else { break }
            items.remove(at: oldest)
        }
    }

    /// Applies the promotion rules to an item that was just seen again.
    private func review(_ item: inout LearnedItem) -> [Promotion] {
        var promotions: [Promotion] = []
        let medicine = involvesMedicine(item.heard, item.intended)
        if !item.vocabulary && !medicine && Self.isUncommonTerm(item.intended) {
            item.vocabulary = true
            promotions.append(.vocabulary(item.intended))
        }

        // A case-only fix ("niamh" → "Niamh") is a vocabulary matter: corrections match
        // case-insensitively, so one would rewrite every occurrence.
        if item.status != .observed || item.heard.lowercased() == item.intended.lowercased() { return promotions }
        if medicine {
            item.status = .suggested
            item.reason = Self.medicineReason
        } else if item.count >= Self.correctionSightings {
            if Self.isShortSingleWord(item.heard) {
                item.status = .suggested
                item.reason = Self.shortWordReason
            } else {
                item.status = .applied
                promotions.append(.correction(from: item.heard, to: item.intended, models: item.models))
            }
        }
        return promotions
    }

    // MARK: Applying

    /// Applies promotions to the dictionary, leaving anything the user already has alone and a
    /// full dictionary as it is. Returns a short description of each change made.
    @discardableResult
    public static func apply(_ promotions: [Promotion], to settings: inout AppSettings) -> [String] {
        var changes: [String] = []
        for promotion in promotions {
            switch promotion {
            case .vocabulary(let term):
                let known = settings.vocabularyHints.contains { $0.lowercased() == term.lowercased() }
                if known || settings.vocabularyHints.count >= AppSettings.maxVocabularyHints { continue }
                settings.vocabularyHints.append(term)
                settings.learnedVocabularyHints.append(term)
                changes.append("added \u{201C}\(term)\u{201D} to your vocabulary")
            case .correction(let from, let to, let models):
                let known = settings.transcriptCorrections.contains { $0.from.lowercased() == from.lowercased() }
                if known || settings.transcriptCorrections.count >= AppSettings.maxCorrections { continue }
                settings.transcriptCorrections.append(TranscriptCorrection(from: from, to: to, origin: .learned, models: models))
                changes.append("now corrects \u{201C}\(from)\u{201D} to \u{201C}\(to)\u{201D}")
            }
        }
        return changes
    }

    // MARK: Rules

    static func isShortSingleWord(_ phrase: String) -> Bool {
        !phrase.contains(where: \.isWhitespace) && phrase.count <= 3
    }

    /// A name, place, product or identifier worth biasing towards: some word is capitalised,
    /// mixed-case or identifier-like, and is not an everyday word that is merely capitalised at a
    /// sentence start.
    static func isUncommonTerm(_ phrase: String) -> Bool {
        phrase.split(whereSeparator: \.isWhitespace).contains { raw in
            var word = Substring(raw)
            while let first = word.first, !EditDiff.isAlphanumeric(first) { word = word.dropFirst() }
            while let last = word.last, !EditDiff.isAlphanumeric(last) { word = word.dropLast() }
            let capitalised = word.contains(where: \.isUppercase)
            let identifier = word.contains("_") || word.contains(".")
                || (word.contains(where: { $0.isASCII && $0.isNumber }) && word.contains(where: \.isLetter))
            return word.count >= 2 && (capitalised || identifier) && !commonWords.contains(word.lowercased())
        }
    }

    /// Everyday English words, including those that start sentences. A short list, not a
    /// frequency dictionary: it only has to stop sentence-initial capitals from looking like names.
    static let commonWords: Set<String> = Set("""
        a about above after again against all also am an and any are aren't as \
        at back be because been before being below between both but by can can't cannot could couldn't \
        did didn't do does doesn't doing don't down during each even every few first for from further \
        get gets go goes going good got great had hadn't has hasn't have haven't having he he'd he'll \
        he's her here here's hers herself hi him himself his how how's however i i'd i'll i'm i've if in \
        into is isn't it it's its itself just know last let let's like look made make many may me might \
        more most much must mustn't my myself need never new next no nor not now of off ok okay on once \
        one only or other ought our ours ourselves out over own please really right said same say see \
        shall shan't she she'd she'll she's should shouldn't so some still such sure take than thank \
        thanks that that's the their theirs them themselves then there there's these they they'd \
        they'll they're they've thing things think this those though through time to today tomorrow \
        too two under until up us very want was wasn't way we we'd we'll we're we've well were weren't \
        what what's when when's where where's which while who who's whom why why's will with won't \
        work would wouldn't yes yesterday yet you you'd you'll you're you've your yours yourself \
        yourselves monday tuesday wednesday thursday friday saturday sunday january february march \
        april june july august september october november december dear hello hey sorry maybe also \
        actually anyway great cheers best regards morning afternoon evening night week year month day
        """.split(whereSeparator: \.isWhitespace).map(String.init))

    /// Medicines whose names are easily confused with another medicine's (look-alike/sound-alike
    /// lists). A mapping touching one is never automatic.
    static let lookAlikeMedicines: Set<String> = [
        "hydroxyzine", "hydralazine", "carbamazepine", "carbimazole", "lamotrigine", "lamivudine",
        "prednisone", "prednisolone", "tramadol", "trazodone", "chlorpromazine", "chlorpropamide",
        "clonidine", "clonazepam", "risperidone", "ropinirole", "amlodipine", "amiloride",
        "metformin", "metronidazole", "sertraline", "cetirizine", "zolpidem", "zopiclone",
    ]

    /// Common medicines, mostly the HSE PCRS top prescribing list, for names the suffix rules miss.
    static let commonMedicines: Set<String> = [
        "levothyroxine", "colecalciferol", "aspirin", "paracetamol", "salbutamol", "co-codamol",
        "folic", "escitalopram", "amoxicillin", "mirtazapine", "pregabalin", "venlafaxine",
        "etofenamate", "macrogol", "quetiapine", "furosemide", "diazepam", "warfarin", "tolterodine",
        "ibuprofen", "insulin", "codeine", "morphine", "citalopram", "tamsulosin", "beclometasone",
        "formoterol", "dapagliflozin", "losartan", "candesartan", "apixaban", "rivaroxaban",
    ]

    /// Endings that mark a word as a medicine (`-prazole`, `-statin`, `-olol`…) or a clinical
    /// term (`-aemia`, `-itis`…).
    static let medicalSuffixes = [
        "prazole", "azole", "statin", "olol", "pril", "sartan", "dipine", "apine", "mycin", "cillin",
        "oxacin", "cycline", "tidine", "azepam", "zolam", "triptyline", "oxetine", "pramine",
        "gliptin", "gliflozin", "formin", "semide", "thiazide", "codone", "olone", "parin", "xaban",
        "gatran", "ciclovir", "navir", "tinib", "umab", "ximab", "aemia", "emia", "itis", "osis",
        "ectomy", "otomy", "algia", "opathy",
    ]

    static func phraseWords(_ phrase: String) -> [String] {
        phrase.split(whereSeparator: { !EditDiff.isAlphanumeric($0) && $0 != "-" }).map { $0.lowercased() }
    }

    /// The built-in heuristic plus every medicine in the bundled packs, enabled or not.
    func looksMedical(_ phrase: String) -> Bool {
        drugs.contains(phrase) || Self.phraseWords(phrase).contains { word in
            drugs.contains(word)
                || Self.commonMedicines.contains(word)
                || Self.lookAlikeMedicines.contains(word)
                || (word.count >= 6 && Self.medicalSuffixes.contains { word.hasSuffix($0) })
                || (word.count >= 8 && (word.hasPrefix("hyper") || word.hasPrefix("hypo")))
        }
    }

    static func isLookAlikeMedicine(_ phrase: String) -> Bool {
        phraseWords(phrase).contains { lookAlikeMedicines.contains($0) }
    }

    /// The clinical safety rule: silently rewriting one medicine into another is a
    /// patient-safety hazard.
    func involvesMedicine(_ heard: String, _ intended: String) -> Bool {
        (looksMedical(heard) && looksMedical(intended)) || Self.isLookAlikeMedicine(heard) || Self.isLookAlikeMedicine(intended)
    }
}
