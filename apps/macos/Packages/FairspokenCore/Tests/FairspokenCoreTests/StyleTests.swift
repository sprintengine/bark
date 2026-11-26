import Foundation
import Testing
@testable import FairspokenCore

@Suite("Style formatters")
struct StyleFormatterTests {
    func run(_ raw: String, _ style: DictationStyle.ID, multiline: Bool = true) -> PostProcessResult {
        DictationPipeline.process(raw, context: PostProcessContext(appBundleID: nil, vocabulary: [], style: style, allowsMultiline: multiline))
    }

    @Test func emailGreetingBodyAndSignOff() {
        let r = run("Hi Aoife, um, I hope you're well. We can go through them on Thursday, no wait, Friday. Kind regards, Pádraig.", .email)
        #expect(r.plainText == "Hi Aoife,\n\nI hope you're well. We can go through them on Friday.\n\nKind regards,\nPádraig")
        #expect(r.html == "<div>Hi Aoife,</div><div><br></div><div>I hope you're well. We can go through them on Friday.</div><div><br></div><div>Kind regards,</div><div>Pádraig</div>")
        #expect(r.text == "Hi Aoife, I hope you're well. We can go through them on Friday. Kind regards, Pádraig.")
        #expect(r.style == .email)
    }

    @Test func emailWithTitleAndSpokenParagraph() {
        let r = run("Dear Mr Byrne, thank you for your letter. New paragraph. The appointment is confirmed for 3 pm. Many thanks.", .email)
        #expect(r.plainText == "Dear Mr Byrne,\n\nThank you for your letter.\n\nThe appointment is confirmed for 3 pm.\n\nMany thanks")
        #expect(r.html == "<div>Dear Mr Byrne,</div><div><br></div><div>Thank you for your letter.</div><div><br></div><div>The appointment is confirmed for 3 pm.</div><div><br></div><div>Many thanks</div>")
    }

    @Test func emailNeverInventsAGreetingOrSignOff() {
        let r = run("Thanks for the update, see you Friday.", .email)
        #expect(r.plainText == "Thanks for the update, see you Friday.")
        let body = run("Can you send the minutes when you get a chance? Thanks for your help with the audit.", .email)
        #expect(body.plainText == "Can you send the minutes when you get a chance?\n\nThanks for your help with the audit.".replacingOccurrences(of: "\n\n", with: " "))
        // "Best" alone isn't a sign-off; with a name it is.
        #expect(run("See you then. Best.", .email).plainText == "See you then. Best.")
        #expect(run("See you then. Best, Niamh.", .email).plainText == "See you then.\n\nBest,\nNiamh")
    }

    @Test func emailTopicParagraphsOnlyInLongBodies() {
        let short = run("Hello team. The rota is up. Also, the party is on the 19th. Cheers, Niamh.", .email)
        #expect(short.plainText == "Hello team,\n\nThe rota is up. Also, the party is on the 19th.\n\nCheers,\nNiamh")
        let long = run("Hello team. The rota is up. It covers December. Also, the party is on the 19th. Separately, can everyone check their leave?", .email)
        #expect(long.plainText == "Hello team,\n\nThe rota is up. It covers December.\n\nAlso, the party is on the 19th.\n\nSeparately, can everyone check their leave?")
    }

    @Test func emailInASingleLineFieldStaysOneLine() {
        let r = run("Hi Aoife, see you Friday. Thanks, Pádraig.", .email, multiline: false)
        #expect(r.plainText == "Hi Aoife, see you Friday. Thanks, Pádraig.")
        #expect(r.html == nil)
    }

    @Test func notesHeadingAndBullets() {
        let r = run("Heading: shopping list. Bullet point milk bullet point eggs, bullet point bread and", .notes)
        #expect(r.plainText == "Shopping list\n\n- Milk\n- Eggs\n- Bread")
        #expect(r.html == "<h2>Shopping list</h2><ul><li>Milk</li><li>Eggs</li><li>Bread</li></ul>")
        #expect(r.edits.filter { $0.kind == .formatting }.map(\.removed) == ["Heading:", "Bullet point", "bullet point", "bullet point"])
    }

    @Test func notesNumberedList() {
        let r = run("Things to do today. Number one, ring the pharmacy. Number two, send the referral. Number three, book the room.", .notes)
        #expect(r.plainText == "Things to do today.\n\n1. Ring the pharmacy\n2. Send the referral\n3. Book the room")
        #expect(r.html == "<div>Things to do today.</div><ol><li>Ring the pharmacy</li><li>Send the referral</li><li>Book the room</li></ol>")
    }

    @Test func listEndsWithItsLastSentence() {
        let r = run("Number one, ring the pharmacy. Number two, book the room. Let me know if that works.", .notes)
        #expect(r.plainText == "1. Ring the pharmacy\n2. Book the room\n\nLet me know if that works.")
        #expect(r.html == "<ol><li>Ring the pharmacy</li><li>Book the room</li></ol><div>Let me know if that works.</div>")
    }

    @Test func spokenCommandsSwitchKeepsLayoutCuesAsWords() {
        let raw = "Heading: shopping list. Bullet point milk bullet point eggs"
        let r = DictationPipeline.process(raw, context: PostProcessContext(appBundleID: nil, vocabulary: [], style: .notes,
                                                                           cleanup: CleanupSettings(spokenCommands: false)))
        #expect(r.plainText == raw)
    }

    @Test func documentOrdinalList() {
        let r = run("First, we need to update the consent form. Second, the audit is due. Third, the new nurse starts Monday.", .document)
        #expect(r.plainText == "1. We need to update the consent form\n2. The audit is due\n3. The new nurse starts Monday")
        #expect(r.html == "<ol><li>We need to update the consent form</li><li>The audit is due</li><li>The new nurse starts Monday</li></ol>")
    }

    @Test func structuredStylesLeaveOrdinaryWordsAlone() {
        for raw in ["Heading home now.", "Add a bullet point here.", "She is my number one priority.", "First of all, thanks for coming.",
                    "The first patient is at nine and the second at ten.", "Use bullet points for the summary.",
                    "We should use bullet points here and keep it short.", "Put it in bullet point form."] {
            #expect(run(raw, .notes).plainText == raw)
            #expect(run(raw, .document).plainText == raw)
        }
    }

    @Test func htmlIsEscapedAndMinimal() {
        let r = run("Bullet point fish & chips bullet point <b>bold</b>", .notes)
        #expect(r.html == "<ul><li>Fish &amp; chips</li><li>&lt;b&gt;bold&lt;/b&gt;</li></ul>")
        #expect(!(r.html ?? "").contains("style"))
    }

    @Test func casualCleanAndVerbatim() {
        #expect(run("Grand, see you at 8 so.", .casual).plainText == "Grand, see you at 8 so")
        #expect(run("um so the the meeting's at 3, sorry, 4.", .casual).plainText == "so the meeting's at 4")
        #expect(run("um so the the meeting's at 3, sorry, 4.", .clean).plainText == "So the meeting's at 4.")
        #expect(run("um so the the meeting's at 3, sorry, 4.", .verbatim).plainText == "um so the the meeting's at 3, sorry, 4.")
        #expect(run("um so the the meeting's at 3, sorry, 4.", .clean).html == nil)
    }

    @Test func codeKeepsPunctuationAndIdentifiers() {
        let r = run("um the getUserName function, uh, returns nil. period", .code)
        #expect(r.plainText == "the getUserName function returns nil.")
        #expect(r.html == nil)
    }

    @Test func spokenLineBreaksBecomeSpacesInSingleLineFields() {
        #expect(run("Milk new line eggs", .clean).plainText == "Milk\nEggs")
        #expect(run("Milk new line eggs", .clean, multiline: false).plainText == "Milk Eggs")
    }
}

@Suite("Style rules")
struct StyleRulesTests {
    @Test func builtInDefaults() {
        let rules = StyleRules()
        #expect(rules.resolve(.init(bundleID: "com.apple.mail", appName: "Mail")).style == .email)
        #expect(rules.resolve(.init(bundleID: "com.apple.mail", appName: "Mail")).reason == "Mail rule")
        #expect(rules.resolve(.init(bundleID: "com.apple.Notes")).style == .notes)
        #expect(rules.resolve(.init(bundleID: "md.obsidian")).style == .notes)
        #expect(rules.resolve(.init(bundleID: "com.microsoft.Word")).style == .document)
        #expect(rules.resolve(.init(bundleID: "com.tinyspeck.slackmacgap")).style == .casual)
        #expect(rules.resolve(.init(bundleID: "com.apple.MobileSMS")).style == .casual)
        #expect(rules.resolve(.init(bundleID: "com.apple.dt.Xcode")).style == .code)
        #expect(rules.resolve(.init(bundleID: "com.microsoft.VSCode")).style == .code)
        #expect(rules.resolve(.init(bundleID: "com.example.unknown")).style == .clean)
        #expect(rules.resolve(.init(bundleID: "com.example.unknown")).source == .global)
        let gmail = DictationDestination(bundleID: "com.google.Chrome", url: "https://mail.google.com/mail/u/0/?tab=rm#inbox")
        #expect(rules.resolve(gmail).style == .email)
        #expect(rules.resolve(gmail).reason == "mail.google.com")
        #expect(rules.resolve(.init(bundleID: "com.apple.Safari", url: "https://docs.google.com/document/d/x/edit")).style == .document)
        #expect(rules.resolve(.init(bundleID: "com.apple.Safari", url: "https://github.com/org/repo/pull/1")).style == .code)
        #expect(rules.resolve(.init(bundleID: "com.apple.Safari", url: "https://www.notion.so/page")).style == .document)
        #expect(rules.resolve(.init(bundleID: "com.apple.Safari", url: "https://example.com/")).style == .clean)
    }

    @Test func precedence() {
        var rules = StyleRules(defaultStyle: .casual)
        let chromeGmail = DictationDestination(bundleID: "com.google.Chrome", appName: "Chrome", url: "https://mail.google.com/mail/")
        #expect(rules.resolve(chromeGmail).source == .builtInSite)
        rules.setSite("mail.google.com", style: .clean)
        #expect(rules.resolve(chromeGmail).style == .clean)
        #expect(rules.resolve(chromeGmail).source == .site)
        rules.setApp("com.google.Chrome", appName: "Chrome", style: .verbatim)
        #expect(rules.resolve(chromeGmail).style == .verbatim)
        #expect(rules.resolve(chromeGmail).reason == "Your rule for Chrome")
        #expect(rules.resolve(chromeGmail, override: .notes).style == .notes)
        #expect(rules.resolve(chromeGmail, override: .notes).reason == "You chose this")
        // The user's default beats nothing but itself.
        #expect(rules.resolve(.init(bundleID: "com.example.unknown")).style == .casual)
        #expect(rules.resolve(.init(bundleID: "com.apple.mail")).style == .email)
    }

    @Test func sitePathPrefixAndSubdomains() {
        var rules = StyleRules()
        rules.setSite("example.com", style: .notes)
        rules.setSite("example.com", pathPrefix: "/wiki", style: .document)
        #expect(rules.resolve(.init(url: "https://example.com/blog")).style == .notes)
        #expect(rules.resolve(.init(url: "https://www.example.com/wiki/page")).style == .document)
        #expect(rules.resolve(.init(url: "https://team.example.com/")).style == .notes)
        #expect(rules.resolve(.init(url: "https://notexample.com/")).style == .clean)
    }

    @Test func terminalsAndSecureFieldsAreVerbatimAndPlain() {
        let rules = StyleRules()
        let terminal = rules.resolve(.init(bundleID: "com.apple.Terminal"))
        #expect(terminal.style == .verbatim)
        #expect(!terminal.allowsMultiline && !terminal.allowsRichText)
        let secure = rules.resolve(.init(bundleID: "com.apple.mail", isSecureField: true), override: .email)
        #expect(secure.style == .verbatim)
        #expect(secure.source == .forced)
        #expect(rules.resolve(.init(bundleID: "com.1password.1password")).style == .verbatim)
        // Not even a choice in the pill reshapes what a terminal runs, and no rule is written for one.
        #expect(rules.resolve(.init(bundleID: "com.apple.Terminal"), override: .clean).style == .verbatim)
        var writable = rules
        let wrote = writable.alwaysUse(.clean, for: .init(bundleID: "com.apple.Terminal"))
        #expect(!wrote)
        #expect(writable.apps.isEmpty)
        #expect(rules.alwaysUseTarget(for: .init(bundleID: "com.apple.mail", isSecureField: true)) == nil)
    }

    @Test func singleLineFieldsGetNoLayouts() {
        let r = StyleRules().resolve(.init(bundleID: "com.apple.mail", isSingleLineField: true))
        #expect(r.style == .email)
        #expect(!r.allowsMultiline)
        #expect(!r.allowsRichText)
    }

    @Test func alwaysUseWritesASiteOrAppRule() {
        var rules = StyleRules()
        let site = rules.alwaysUse(.casual, for: .init(bundleID: "com.google.Chrome", url: "https://mail.google.com/mail/"))
        #expect(site)
        #expect(rules.sites == [SiteStyleRule(host: "mail.google.com", style: .casual)])
        let app = rules.alwaysUse(.notes, for: .init(bundleID: "com.apple.mail", appName: "Mail"))
        #expect(app)
        #expect(rules.apps == [AppStyleRule(bundleID: "com.apple.mail", appName: "Mail", style: .notes)])
        let nowhere = rules.alwaysUse(.notes, for: .init())
        #expect(!nowhere)
        rules.removeApp("com.apple.mail")
        rules.removeSite("mail.google.com")
        #expect(rules.apps.isEmpty && rules.sites.isEmpty)
        // With a rule for the browser itself, a site rule would never be reached: the browser's
        // rule is the one updated, so "always use" keeps working.
        rules.setApp("com.google.Chrome", appName: "Chrome", style: .verbatim)
        let gmail = DictationDestination(bundleID: "com.google.Chrome", appName: "Chrome", url: "https://mail.google.com/mail/")
        #expect(rules.alwaysUseTarget(for: gmail) == .app(bundleID: "com.google.Chrome", name: "Chrome"))
        let updated = rules.alwaysUse(.email, for: gmail)
        #expect(updated)
        #expect(rules.resolve(gmail).style == .email)
        #expect(rules.sites.isEmpty)
    }

    @Test func urlsKeepOnlySchemeHostAndPath() {
        let d = DictationDestination(url: "https://user:secret@www.Example.com:8443/inbox/42?token=abc#frag")
        #expect(d.url == "https://example.com/inbox/42")
        #expect(d.host == "example.com")
        #expect(DictationDestination(url: "file:///Users/dev/notes.txt").url == nil)
        #expect(DictationDestination(url: "about:blank").host == nil)
    }

    @Test func replyFromWindowTitle() {
        #expect(DictationDestination(windowTitle: "Re: Thursday's clinic").isReply)
        #expect(!DictationDestination(windowTitle: "Thursday's clinic").isReply)
    }

    @Test func rulesNormalise() {
        var rules = StyleRules(apps: [AppStyleRule(bundleID: " com.apple.mail ", style: .notes), AppStyleRule(bundleID: "com.apple.mail", style: .casual),
                                      AppStyleRule(bundleID: "", style: .notes)],
                               sites: [SiteStyleRule(host: "HTTPS://WWW.Example.com/x", pathPrefix: "/", style: .notes)])
        rules = rules.normalized()
        #expect(rules.apps == [AppStyleRule(bundleID: "com.apple.mail", style: .casual)])
        #expect(rules.sites == [SiteStyleRule(host: "example.com", pathPrefix: nil, style: .notes)])
    }
}

@Suite("Pipeline")
struct PipelineTests {
    @Test func orderIsCasingCleanupCorrectionsThenLayout() {
        var correction = TranscriptCorrection(from: "neve", to: "Niamh")
        correction.enabled = true
        let context = PostProcessContext(appBundleID: nil, vocabulary: ["HbA1c"], corrections: [correction], style: .clean)
        let r = DictationPipeline.process("  um, neve's hba1c is 48, sorry, 52.  ", context: context)
        #expect(r.plainText == "Niamh's HbA1c is 52.")
        // Sentence case is part of cleanup, so it capitalises "neve's" before the correction runs.
        #expect(r.edits.map(\.kind) == [.filler, .punctuation, .vocabulary, .vocabulary, .selfCorrection])
        #expect(r.edits[2] == CleanupEdit(kind: .vocabulary, removed: "Neve's", inserted: "Niamh's"))
        #expect(r.edits[3] == CleanupEdit(kind: .vocabulary, removed: "hba1c", inserted: "HbA1c"))
    }

    @Test func switchesTurnStagesOff() {
        let raw = "Um, see you Tuesday, no wait, Wednesday comma thanks"
        func run(_ c: CleanupSettings) -> String {
            DictationPipeline.process(raw, context: PostProcessContext(appBundleID: nil, vocabulary: [], cleanup: c)).plainText
        }
        #expect(run(.all) == "See you Wednesday, thanks")
        #expect(run(CleanupSettings(removeFillers: false)) == "Um, see you Wednesday, thanks")
        #expect(run(CleanupSettings(fixSelfCorrections: false)) == "See you Tuesday, no wait, Wednesday, thanks")
        // "comma" after the repair is a word now, so the repair no longer stands alone: left as heard.
        #expect(run(CleanupSettings(spokenCommands: false)) == "See you Tuesday, no wait, Wednesday comma thanks")
        #expect(DictationPipeline.process("See you Tuesday, no wait, Wednesday", context: PostProcessContext(
            appBundleID: nil, vocabulary: [], cleanup: CleanupSettings(spokenCommands: false))).plainText == "See you Wednesday")
    }

    @Test func emptyAfterCleanup() {
        let r = DictationPipeline.process("Um.", context: PostProcessContext(appBundleID: nil, vocabulary: []))
        #expect(r.plainText.isEmpty)
    }

    @Test func editsAreInTranscriptOrder() {
        let r = DictationPipeline.process("Hi Aoife, um, the the meeting is on Tuesday, sorry, Wednesday. Thanks, Niamh.",
                                          context: PostProcessContext(appBundleID: nil, vocabulary: [], style: .email))
        #expect(r.edits.map(\.kind) == [.formatting, .filler, .repetition, .selfCorrection, .formatting, .formatting])
    }

    @Test func alignKeepsOriginsThroughCorrections() {
        let old = TranscriptTokenizer.tokenize("send it to neve today")
        let new = TranscriptTokenizer.tokenize("send it to Niamh Byrne today")
        let (aligned, changes) = DictationPipeline.align(old, with: new)
        #expect(aligned.map(\.origin) == [0, 1, 2, 3, 3, 4])
        #expect(changes == [DictationPipeline.Change(removed: "neve", inserted: "Niamh Byrne", position: 3)])
    }
}

@Suite("Note edit commands")
struct NoteEditCommandTests {
    @Test func changeAndReplace() {
        #expect(NoteEditCommand.apply("change Tuesday to Wednesday", to: "See you Tuesday.")?.text == "See you Wednesday.")
        #expect(NoteEditCommand.apply("Replace \"the shop\" with the cafe.", to: "Meet at the shop.")?.text == "Meet at the cafe.")
        let r = NoteEditCommand.apply("change go to the shop to go to the cafe", to: "I need to go to the shop later.")
        #expect(r?.text == "I need to go to the cafe later.")
        #expect(r?.edits == [CleanupEdit(kind: .selfCorrection, removed: "go to the shop", inserted: "go to the cafe")])
        // A capital stays a capital.
        #expect(NoteEditCommand.apply("change thanks to cheers", to: "Thanks, Niamh.")?.text == "Cheers, Niamh.")
        #expect(NoteEditCommand.apply("change Friday to Monday", to: "See you Tuesday.") == nil)
    }

    @Test func ambiguousTargetsAreLeftAlone() {
        #expect(NoteEditCommand.apply("delete it", to: "Put it on the desk and leave it there.") == nil)
        #expect(NoteEditCommand.apply("change 3 to 4", to: "Room 3 at 3 pm.") == nil)
        #expect(NoteEditCommand.apply("change room 3 to room 4", to: "Room 3 at 3 pm.")?.text == "Room 4 at 3 pm.")
        // A delete in lowercase text keeps it lowercase.
        #expect(NoteEditCommand.apply("delete really", to: "the getUserName call is really slow")?.text == "the getUserName call is slow")
    }

    @Test func deleteAndAdd() {
        #expect(NoteEditCommand.apply("delete really", to: "It was really good.")?.text == "It was good.")
        #expect(NoteEditCommand.apply("remove the last sentence", to: "Hello.") == nil)
        #expect(NoteEditCommand.apply("delete Hi Aoife,", to: "Hi Aoife, see you soon.")?.text == "See you soon.")
        #expect(NoteEditCommand.apply("add see you then at the end", to: "Meet at 3.")?.text == "Meet at 3. See you then")
        #expect(NoteEditCommand.apply("add Hi Aoife, at the start", to: "See you soon.")?.text == "Hi Aoife, See you soon.")
        #expect(NoteEditCommand.apply("make it shorter", to: "Hello.") == nil)
    }
}

@Suite("Style settings and history compatibility")
struct StyleCompatibilityTests {
    @Test func oldSettingsDecodeWithDefaults() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"model":"parakeet-tdt-0.6b-v3","polishEnabled":true}"#.utf8))
        #expect(s.styleRules == StyleRules())
        #expect(s.cleanupSettings == .all)
        #expect(s.polishEnabled)
    }

    @Test func styleSettingsRoundTrip() throws {
        var s = AppSettings()
        s.styleRules.setApp("com.apple.mail", appName: "Mail", style: .casual)
        s.styleRules.setSite("mail.google.com", pathPrefix: "/mail", style: .verbatim)
        s.styleRules.defaultStyle = .casual
        s.cleanupSettings = CleanupSettings(removeFillers: false, fixSelfCorrections: true, spokenCommands: false)
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
        #expect(back.cleanupFillers == false && back.cleanupSpokenCommands == false)
    }

    @Test func malformedStyleRulesDecodeLeniently() throws {
        let json = #"{"styleRules":{"defaultStyle":"sparkly","apps":[{"bundleID":"com.apple.mail","style":"email"},{"bundleID":7},{"bundleID":"x","style":"nope"}],"sites":"oops"},"cleanupFillers":"yes"}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(s.styleRules.defaultStyle == .clean)
        #expect(s.styleRules.apps.map(\.bundleID) == ["com.apple.mail", "x"])
        #expect(s.styleRules.apps.last?.style == .clean)
        #expect(s.styleRules.sites.isEmpty)
        #expect(s.cleanupFillers)
    }

    @Test func oldHistoryFileStillDecodes() throws {
        // As the Rust app and earlier Mac builds wrote it: none of the new fields.
        let json = #"[{"id":"transcript-1","createdAt":1759600000000,"text":"Hello","backend":"parakeet","location":"local","durationSeconds":1.5,"polished":false,"timings":{"transcribeMs":120,"speechModelMs":80,"polishMs":0,"totalMs":130},"model":"parakeet-tdt-0.6b-v3","appName":"Mail","appBundleId":"com.apple.mail"}]"#
        let items = try JSONDecoder().decode([TranscriptHistoryItem].self, from: Data(json.utf8))
        #expect(items.count == 1)
        #expect(items[0].cleanupEdits == nil && items[0].style == nil && items[0].isNote == nil && items[0].cleanupMs == nil)
        #expect(items[0].appName == "Mail")
    }

    @Test func newHistoryFieldsRoundTripAndAreOmittedWhenNil() throws {
        let item = TranscriptHistoryItem(id: "t", createdAt: 1, text: "See you Wednesday.", backend: "parakeet", location: "local",
                                         durationSeconds: 2, rawText: "see you Tuesday, sorry, Wednesday",
                                         cleanupEdits: [CleanupEdit(kind: .selfCorrection, removed: "Tuesday, sorry,")],
                                         style: "clean", styleReason: "Default", destinationHost: "example.com", isNote: false, cleanupMs: 1)
        let data = try JSONEncoder().encode(item)
        #expect(try JSONDecoder().decode(TranscriptHistoryItem.self, from: data) == item)
        let bare = try JSONEncoder().encode(TranscriptHistoryItem(id: "t", createdAt: 1, text: "x", backend: "b", location: "local", durationSeconds: 0))
        let keys = try #require(JSONSerialization.jsonObject(with: bare) as? [String: Any]).keys
        #expect(!keys.contains("cleanupEdits") && !keys.contains("isNote") && !keys.contains("style"))
    }

    @Test func unknownEditKindsAreKept() throws {
        let json = #"{"id":"t","createdAt":1,"text":"x","cleanupEdits":[{"kind":"somethingNew","removed":"a","inserted":"b"},{"kind":"filler","removed":"um"},7]}"#
        let item = try JSONDecoder().decode(TranscriptHistoryItem.self, from: Data(json.utf8))
        #expect(item.cleanupEdits == [CleanupEdit(kind: .formatting, removed: "a", inserted: "b"), CleanupEdit(kind: .filler, removed: "um")])
    }

    @Test func notes() {
        let note = TranscriptHistoryItem.note("Ring the pharmacy", at: Date(timeIntervalSince1970: 10))
        #expect(note.isNote == true)
        #expect(note.styleID == .notes)
        #expect(note.id == "note-10000")
    }

    @Test func historyKeepsAThousandAndAddsQuickly() {
        var items: [TranscriptHistoryItem] = []
        for i in 0..<1_100 {
            items = TranscriptHistory.adding(TranscriptHistoryItem(id: "\(i)", createdAt: Int64(i), text: "dictation number \(i) about the clinic",
                                                                   backend: "parakeet", location: "local", durationSeconds: 1), to: items)
        }
        #expect(items.count == TranscriptHistory.maxItems)
        let start = ContinuousClock.now
        items = TranscriptHistory.adding(TranscriptHistoryItem(id: "x", createdAt: 9_999, text: "DICTATION number  1099 about the clinic",
                                                               backend: "parakeet", location: "local", durationSeconds: 1), to: items)
        #expect(ContinuousClock.now - start < .milliseconds(50))
        #expect(items.first?.id == "x")
        #expect(!items.contains { $0.id == "1099" })
    }
}
