import Testing
@testable import FairspokenCore

@Suite("Paste target")
struct PasteTargetTests {
    typealias E = PasteTarget.Element
    static let mail = "com.apple.mail"

    static func decide(_ element: E, app: String? = mail) -> PasteTarget.Decision {
        PasteTarget.decide(.element(element), appBundleID: app)
    }

    @Test(arguments: ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXWebArea"])
    func textRolesPaste(role: String) {
        #expect(Self.decide(E(role: role)) == .paste)
        #expect(Self.decide(E(role: role), app: PasteTarget.finderBundleID) == .paste)
    }

    @Test(arguments: ["AXButton", "AXList", "AXOutline", "AXImage", "AXMenuItem"])
    func controlsAndListsCopyOnly(role: String) {
        #expect(Self.decide(E(role: role)) == .copyOnly)
    }

    /// A selected cell in a spreadsheet or a keyboard-editable web grid takes ⌘V without
    /// reporting anything editable.
    @Test(arguments: ["AXTable", "AXRow", "AXColumn", "AXCell"])
    func gridsPasteWithoutEditableSignals(role: String) {
        #expect(Self.decide(E(role: role, isEditable: nil, hasEditableAncestor: false, valueIsSettable: nil)) == .paste)
        #expect(Self.decide(E(role: role, valueIsSettable: false)) == .paste)
    }

    @Test func editableSignalsWinOverTheRole() {
        #expect(Self.decide(E(role: "AXGroup", isEditable: true)) == .paste)
        #expect(Self.decide(E(role: "AXList", valueIsSettable: true)) == .paste)
        #expect(Self.decide(E(role: "AXStaticText", hasEditableAncestor: true)) == .paste)
        #expect(Self.decide(E(role: "AXTextField", subrole: "AXSearchField")) == .paste)
        #expect(Self.decide(E(role: "AXUnknown", subrole: "AXSearchField"), app: PasteTarget.finderBundleID) == .paste)
    }

    @Test func groupsCopyOnlyWhenTheySayTheyAreNotEditable() {
        #expect(Self.decide(E(role: "AXGroup")) == .paste)
        #expect(Self.decide(E(role: "AXGroup", valueIsSettable: false)) == .paste)
        #expect(Self.decide(E(role: "AXGroup", isEditable: false)) == .copyOnly)
    }

    @Test func ambiguousElementsPaste() {
        // Terminals, web-view shells and custom views report these for a place that takes text.
        #expect(Self.decide(E(role: nil)) == .paste)
        #expect(Self.decide(E(role: "AXWindow")) == .paste)
        #expect(Self.decide(E(role: "AXScrollArea")) == .paste)
        #expect(Self.decide(E(role: "AXUnknown")) == .paste)
        #expect(Self.decide(E(role: "AXSomethingNew")) == .paste)
    }

    @Test func finderDesktopAndFileViewsCopyOnly() {
        let finder = PasteTarget.finderBundleID
        #expect(PasteTarget.decide(.none(appHasFocusedWindow: nil), appBundleID: finder) == .copyOnly)
        #expect(PasteTarget.decide(.none(appHasFocusedWindow: true), appBundleID: finder) == .copyOnly)
        #expect(Self.decide(E(role: "AXGroup"), app: finder) == .copyOnly)
        #expect(Self.decide(E(role: "AXScrollArea"), app: finder) == .copyOnly)
        #expect(Self.decide(E(role: nil), app: finder) == .copyOnly)
    }

    @Test func noFocusedElementCopiesOnlyWithoutAWindow() {
        #expect(PasteTarget.decide(.none(appHasFocusedWindow: false), appBundleID: Self.mail) == .copyOnly)
        // A window but no focused element is often poor Accessibility support, not an empty app.
        #expect(PasteTarget.decide(.none(appHasFocusedWindow: true), appBundleID: Self.mail) == .paste)
        #expect(PasteTarget.decide(.none(appHasFocusedWindow: nil), appBundleID: Self.mail) == .paste)
        #expect(PasteTarget.decide(.none(appHasFocusedWindow: false), appBundleID: nil) == .copyOnly)
    }

    @Test func unknownFocusPastes() {
        #expect(PasteTarget.decide(.unknown, appBundleID: Self.mail) == .paste)
        #expect(PasteTarget.decide(.unknown, appBundleID: PasteTarget.finderBundleID) == .paste)
        #expect(PasteTarget.decide(.unknown, appBundleID: nil) == .paste)
    }
}
