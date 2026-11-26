import Foundation
import Testing
@testable import FairspokenCore

@Suite("Pill presentation")
struct PillPresentationTests {
    @Test func nothingHeardIsNeutral() {
        let f = PillPresentation.failure("No speech detected")
        #expect(f.kind == .nothingHeard)
        #expect(f.title == "Nothing heard")
        #expect(!f.isError)
        #expect(!f.canRetry)
    }

    @Test func tooShortKeepsItsAdvice() {
        let f = PillPresentation.failure("Too short — hold the shortcut while you speak")
        #expect(f.kind == .tooShort)
        #expect(f.title == "Too short")
        #expect(f.detail == "hold the shortcut while you speak")
        #expect(!f.isError)
    }

    @Test func savedToRetryIsCalm() {
        let failed = PillPresentation.failure("Couldn't transcribe — saved to retry")
        #expect(failed.kind == .savedToRetry)
        #expect(failed.title == "Couldn't transcribe")
        #expect(failed.detail == "saved to retry")
        #expect(!failed.isError)
        let cancelled = PillPresentation.failure("Cancelled — saved to retry")
        #expect(cancelled.title == "Cancelled")
        #expect(cancelled.kind == .savedToRetry)
    }

    @Test func microphoneFailuresAreErrors() {
        let busy = PillPresentation.failure("Couldn't start the microphone: The operation couldn’t be completed. (OSStatus error 560557684.)")
        #expect(busy.kind == .microphone)
        #expect(busy.title == "Microphone unavailable")
        #expect(busy.isError)
        #expect(busy.canRetry)
        let off = PillPresentation.failure("Microphone access is off")
        #expect(off.kind == .microphone)
        #expect(off.title == "Microphone access is off")
        #expect(!off.canRetry)
    }

    @Test func otherFailuresAreClipped() {
        let long = String(repeating: "The host answered with something odd ", count: 4)
        let f = PillPresentation.failure(long)
        #expect(f.kind == .other)
        #expect(f.isError)
        #expect(f.title.count <= 60)
        #expect(f.title.hasSuffix("…"))
    }

    @Test func copiedDetailDropsWhatThePillShows() {
        #expect(PillPresentation.copiedDetail("Copied to clipboard") == nil)
        #expect(PillPresentation.copiedDetail("Copied — press ⌘V to paste") == nil)
        #expect(PillPresentation.copiedDetail("Copied — no text field. Press ⌘V to paste.") == "no text field")
        #expect(PillPresentation.copiedDetail("Copied — you'd switched apps") == "you'd switched apps")
        #expect(PillPresentation.copiedDetail("Copied — allow Accessibility to paste") == "allow Accessibility to paste")
        #expect(PillPresentation.copiedDetail("Copied — secure field") == "secure field")
    }

    @Test func shortHostName() {
        #expect(PillPresentation.shortHostName("build-box.tail1234.ts.net") == "build-box")
        #expect(PillPresentation.shortHostName("mac-mini.local:48173") == "mac-mini")
        #expect(PillPresentation.shortHostName("100.64.0.7:48173") == "100.64.0.7")
    }
}

@Suite("Style chip")
struct StyleChipTests {
    let mail = DictationDestination(bundleID: "com.apple.mail", appName: "Mail")

    @Test func showsTheStyleAndWhy() throws {
        let rules = StyleRules()
        let chip = try #require(StyleChipState(resolution: rules.resolve(mail), target: rules.alwaysUseTarget(for: mail)))
        #expect(chip.label == "Email · Mail rule")
        #expect(!chip.isLocked)
        #expect(chip.entries.contains(.style(.email, checked: true)))
        #expect(chip.entries.filter { if case .style(_, true) = $0 { true } else { false } }.count == 1)
        #expect(chip.entries.last == .alwaysUse(title: "Always use Email for Mail", style: .email))
        // No choice made: nothing to go back to.
        #expect(!chip.entries.contains { if case .useRules = $0 { true } else { false } })
    }

    @Test func aChoiceOffersTheWayBack() throws {
        let rules = StyleRules()
        let chosen = rules.resolve(mail, override: .casual)
        let chip = try #require(StyleChipState(resolution: chosen, rulesResolution: rules.resolve(mail),
                                               target: rules.alwaysUseTarget(for: mail)))
        #expect(chip.label == "Casual · You chose this")
        #expect(chip.entries.contains(.style(.casual, checked: true)))
        #expect(chip.entries.contains(.useRules(title: "Back to Email (Mail rule)")))
        #expect(chip.entries.last == .alwaysUse(title: "Always use Casual for Mail", style: .casual))
    }

    @Test func terminalsAndSecureFieldsAreLocked() throws {
        let rules = StyleRules()
        let terminal = DictationDestination(bundleID: "com.apple.Terminal", appName: "Terminal")
        let chip = try #require(StyleChipState(resolution: rules.resolve(terminal), target: rules.alwaysUseTarget(for: terminal)))
        #expect(chip.isLocked)
        #expect(chip.label == "Verbatim · Terminal")
        #expect(chip.entries.isEmpty)
        let secure = DictationDestination(bundleID: "com.apple.Safari", appName: "Safari", isSecureField: true)
        let locked = try #require(StyleChipState(resolution: rules.resolve(secure), target: rules.alwaysUseTarget(for: secure)))
        #expect(locked.isLocked)
        #expect(locked.label == "Verbatim · Secure field")
    }

    @Test func websitesAreNamedInAlwaysUse() throws {
        let rules = StyleRules()
        let gmail = DictationDestination(bundleID: "com.apple.Safari", appName: "Safari", url: "https://mail.google.com/mail/u/0/")
        let chip = try #require(StyleChipState(resolution: rules.resolve(gmail), target: rules.alwaysUseTarget(for: gmail)))
        #expect(chip.label == "Email · mail.google.com")
        #expect(chip.entries.last == .alwaysUse(title: "Always use Email for mail.google.com", style: .email))
    }

    @Test func noteInBarkHasNoAlwaysUse() throws {
        let note = StyleResolution(style: .notes, reason: "Note in Bark", source: .builtInApp)
        let chip = try #require(StyleChipState(resolution: note, target: nil))
        #expect(chip.label == "Notes · Note in Bark")
        #expect(!chip.entries.contains { if case .alwaysUse = $0 { true } else { false } })
        #expect(StyleChipState(resolution: nil, target: nil) == nil)
    }

    @Test func reasonsAreShortened() {
        #expect(StyleChipState.shortReason("Your rule for Slack") == "Your Slack rule")
        #expect(StyleChipState.shortReason("Your rule for Microsoft Outlook") == "Your rule")
        #expect(StyleChipState.shortReason("Your rule for docs.google.com") == "Your rule")
        #expect(StyleChipState.shortReason("Mail rule") == "Mail rule")
        #expect(StyleChipState.shortReason("Default") == "Default")
    }
}

@Suite("Palette search")
struct PaletteSearchTests {
    struct Entry { var title: String; var app: String }

    func titles(_ items: [Entry], _ query: String, scattered: Bool = false) -> [String] {
        PaletteSearch.rank(items, query: query, allowScattered: scattered) {
            PaletteSearch.Fields(title: $0.title, other: [$0.app])
        }.map(\.title)
    }

    let dictations = [
        Entry(title: "Could you send the revised quote by Friday?", app: "Mail"),
        Entry(title: "Kitchen quote: worktop, two wall units", app: "Notes"),
        Entry(title: "running ten minutes late, start without me", app: "Slack"),
        Entry(title: "Quotes from the meeting", app: "Mail"),
        Entry(title: "Thanks Aoife, see you at the café", app: "Messages"),
    ]

    @Test func emptyQueryKeepsTheOrder() {
        #expect(titles(dictations, "") == dictations.map(\.title))
        #expect(titles(dictations, "   ") == dictations.map(\.title))
    }

    @Test func wholeWordsBeatWordStartsAndTiesKeepRecency() {
        // "quote" is a whole word in the first two, the start of "Quotes" in the fourth.
        #expect(titles(dictations, "quote") == [
            "Could you send the revised quote by Friday?",
            "Kitchen quote: worktop, two wall units",
            "Quotes from the meeting",
        ])
    }

    @Test func everyWordMustMatchSomewhere() {
        #expect(titles(dictations, "quote mail") == ["Could you send the revised quote by Friday?", "Quotes from the meeting"])
        #expect(titles(dictations, "quote slack").isEmpty)
    }

    @Test func appNamesMatchButCountLess() {
        let items = [Entry(title: "Slack status update", app: "Mail"), Entry(title: "On my way", app: "Slack")]
        #expect(titles(items, "slack") == ["Slack status update", "On my way"])
    }

    @Test func caseAndAccentsAreIgnored() {
        #expect(titles(dictations, "AOIFE") == ["Thanks Aoife, see you at the café"])
        #expect(titles(dictations, "cafe") == ["Thanks Aoife, see you at the café"])
    }

    @Test func aPhraseBeatsTheSameWordsApart() {
        let items = [Entry(title: "ten past the hour, minutes later", app: "Notes"),
                     Entry(title: "running ten minutes late", app: "Slack")]
        #expect(titles(items, "ten minutes").first == "running ten minutes late")
    }

    @Test func scatteredLettersOnlyWhenAsked() {
        let commands = [Entry(title: "Transcription", app: "Settings"), Entry(title: "Vocabulary", app: "Settings")]
        #expect(titles(commands, "trnscr").isEmpty)
        #expect(titles(commands, "trnscr", scattered: true) == ["Transcription"])
        // Too short to guess at.
        #expect(titles(commands, "vb", scattered: true).isEmpty)
    }

    @Test func limitCapsTheResult() {
        let ranked = PaletteSearch.rank(dictations, query: "", limit: 2) { PaletteSearch.Fields(title: $0.title) }
        #expect(ranked.count == 2)
    }

    @Test func matchRangesFindEachWord() {
        let text = "Could you send the revised quote by Friday?"
        let ranges = PaletteSearch.matchRanges("friday QUOTE", in: text)
        #expect(ranges.map { String(text[$0]) } == ["quote", "Friday"])
    }
}
