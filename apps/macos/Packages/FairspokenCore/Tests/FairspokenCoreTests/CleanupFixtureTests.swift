import Foundation
import Testing
@testable import FairspokenCore

/// The golden fixtures (`Fixtures/cleanup-fixtures.jsonl`): realistic dictations, what cleanup
/// should make of them, and many that must come through unchanged. Reports the exact-match rate
/// per category and a harm count: content words cleanup wrongly removed or invented. Harm must be
/// zero; a missed fix is only a missed fix.
@Suite("Cleanup fixtures")
struct CleanupFixtureTests {
    struct Fixture: Decodable {
        var raw: String
        var expected: String
        var category: String
        var note: String
        var style: String?
    }

    static func load() throws -> [Fixture] {
        let url = try #require(Bundle.module.url(forResource: "cleanup-fixtures", withExtension: "jsonl", subdirectory: "Fixtures"))
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map {
            try JSONDecoder().decode(Fixture.self, from: Data($0.utf8))
        }
    }

    static func clean(_ fixture: Fixture) -> String {
        let style = fixture.style.flatMap(DictationStyle.ID.init(rawValue:)) ?? .clean
        return TranscriptCleanup.clean(fixture.raw, options: style.cleanupOptions).text
    }

    /// Lowercased words without punctuation, fillers and function words.
    static func contentWords(_ text: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        for word in text.lowercased().split(whereSeparator: { $0.isWhitespace }) {
            let core = word.trimmingCharacters(in: .punctuationCharacters.union(.symbols)).replacingOccurrences(of: "’", with: "'")
            guard !core.isEmpty, !CleanupLexicon.functionWords.contains(core), !CleanupLexicon.hardFillers.contains(core) else { continue }
            counts[core, default: 0] += 1
        }
        return counts
    }

    /// Content words the expected text keeps that cleanup removed, plus words in neither the raw
    /// nor the expected text that cleanup added.
    static func harm(raw: String, expected: String, actual: String) -> Int {
        let r = contentWords(raw), e = contentWords(expected), a = contentWords(actual)
        var harm = 0
        for (word, count) in e where (a[word] ?? 0) < count { harm += count - (a[word] ?? 0) }
        for (word, count) in a where count > max(e[word] ?? 0, r[word] ?? 0) { harm += count - max(e[word] ?? 0, r[word] ?? 0) }
        return harm
    }

    @Test func goldenFixtures() throws {
        let fixtures = try Self.load()
        #expect(fixtures.count >= 200)
        #expect(fixtures.filter { $0.category == "mustNotChange" }.count >= 80)
        var byCategory: [String: (pass: Int, total: Int)] = [:]
        var totalHarm = 0
        var failures: [String] = []
        for fixture in fixtures {
            let actual = Self.clean(fixture)
            let pass = actual == fixture.expected
            let harm = Self.harm(raw: fixture.raw, expected: fixture.expected, actual: actual)
            totalHarm += harm
            byCategory[fixture.category, default: (0, 0)].total += 1
            if pass { byCategory[fixture.category, default: (0, 0)].pass += 1 }
            if !pass { failures.append("[\(fixture.category)\(harm > 0 ? " HARM \(harm)" : "")] \(fixture.note)\n    raw:      \(fixture.raw)\n    expected: \(fixture.expected)\n    actual:   \(actual)") }
        }
        let passed = byCategory.values.reduce(0) { $0 + $1.pass }
        var report = String(format: "Cleanup fixtures: %d/%d exact (%.1f%%), harm %d\n", passed, fixtures.count, Double(passed) * 100 / Double(fixtures.count), totalHarm)
        for (category, result) in byCategory.sorted(by: { $0.key < $1.key }) {
            report += String(format: "  %-16@ %3d/%3d  %.0f%%\n", category as NSString, result.pass, result.total, Double(result.pass) * 100 / Double(result.total))
        }
        print(report + failures.joined(separator: "\n"))
        #expect(totalHarm == 0, "cleanup removed or added content words")
        let mustNotChange = byCategory["mustNotChange"] ?? (0, 0)
        #expect(mustNotChange.pass == mustNotChange.total, "a must-not-change case changed")
        #expect(Double(passed) / Double(fixtures.count) >= 0.9)
    }

    /// Typical dictations clean in well under 2 ms each.
    @Test func cleanupIsFast() {
        let samples = [
            "Um, so I was thinking we could, we could move the clinic to Thursday, no wait, Friday afternoon, if that suits everyone.",
            "Hi Aoife, I hope you're well. I've attached the audit results and, you know, we can go through them on Friday. Kind regards, Pádraig.",
            "The patient reports intermittent chest tightness on exertion for three weeks, no radiation, settles with rest. ECG today, bloods including troponin and lipids.",
            "Can we move the Thursday practice meeting to 1 pm? The new nurse starts that morning and I'd like her to sit in.",
        ]
        _ = samples.map { TranscriptCleanup.clean($0) } // warm up
        let runs = 200
        let start = ContinuousClock.now
        for _ in 0..<runs { for sample in samples { _ = TranscriptCleanup.clean(sample) } }
        let perDictation = (ContinuousClock.now - start) / Double(runs * samples.count)
        let ms = Double(perDictation.components.attoseconds) / 1e15 + Double(perDictation.components.seconds) * 1000
        print(String(format: "Cleanup: %.3f ms per typical dictation", ms))
        #expect(ms < 2)
    }
}
