import Foundation

/// Whether a dictation should be pasted (⌘V) into the frontmost app, or only left on the
/// clipboard because there is clearly nowhere to type.
///
/// Built from what the Accessibility API reports for the frontmost app's focused element. The
/// rule leans hard towards pasting: apps with poor Accessibility support (web-view shells,
/// terminals drawn on the GPU, custom views) often report nothing useful, and a wrong "copy only"
/// costs the user a keystroke on every dictation, while a wrong "paste" into nothing still leaves
/// the text recoverable from the clipboard. So only a clear "no text here" answer copies.
public enum PasteTarget {
    public enum Decision: Equatable, Sendable {
        case paste
        /// No text target: leave the dictation on the clipboard and say so.
        case copyOnly
    }

    /// What the frontmost app said about its focus.
    public enum Focus: Equatable, Sendable {
        /// The query failed, timed out or is not supported: we know nothing.
        case unknown
        /// The app answered that nothing is focused. `appHasFocusedWindow` is whether it has a
        /// focused window (`nil` when that could not be read either).
        case none(appHasFocusedWindow: Bool?)
        case element(Element)
    }

    public struct Element: Equatable, Sendable {
        public var role: String?
        public var subrole: String?
        /// `AXIsEditable` (web content); `nil` when the element does not report it.
        public var isEditable: Bool?
        /// Whether the element sits inside editable web content (`AXEditableAncestor` present).
        public var hasEditableAncestor: Bool
        /// Whether `AXValue` is settable; `nil` when that could not be read.
        public var valueIsSettable: Bool?

        public init(role: String?, subrole: String? = nil, isEditable: Bool? = nil,
                    hasEditableAncestor: Bool = false, valueIsSettable: Bool? = nil) {
            self.role = role
            self.subrole = subrole
            self.isEditable = isEditable
            self.hasEditableAncestor = hasEditableAncestor
            self.valueIsSettable = valueIsSettable
        }
    }

    public static let finderBundleID = "com.apple.finder"

    /// Roles that take typed or pasted text.
    static let textRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXWebArea",
    ]
    static let textSubroles: Set<String> = ["AXSearchField", "AXSecureTextField"]

    /// Controls and containers that never take pasted text themselves.
    static let nonTextRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXRadioGroup", "AXPopUpButton",
        "AXMenuButton", "AXDisclosureTriangle", "AXSlider", "AXIncrementor", "AXColorWell",
        "AXList", "AXOutline", "AXTable", "AXBrowser", "AXRow", "AXColumn", "AXCell",
        "AXImage", "AXTabGroup", "AXToolbar", "AXMenu", "AXMenuBar", "AXMenuBarItem",
        "AXMenuItem", "AXProgressIndicator", "AXLevelIndicator", "AXSplitter",
    ]

    public static func decide(_ focus: Focus, appBundleID: String?) -> Decision {
        let isFinder = appBundleID == finderBundleID
        switch focus {
        case .unknown:
            return .paste
        case .none(let hasWindow):
            // Finder with nothing focused is the desktop; an app without a window has no field.
            // A window with no focused element is often just poor Accessibility support.
            return isFinder || hasWindow == false ? .copyOnly : .paste
        case .element(let element):
            if element.isEditable == true || element.hasEditableAncestor || element.valueIsSettable == true {
                return .paste
            }
            if let role = element.role, textRoles.contains(role) { return .paste }
            if let subrole = element.subrole, textSubroles.contains(subrole) { return .paste }
            // Finder's only text targets are its rename and search fields, handled above.
            if isFinder { return .copyOnly }
            guard let role = element.role else { return .paste }
            if nonTextRoles.contains(role) { return .copyOnly }
            // A group is copy-only only when it says outright that it is not editable (web
            // content); a bare group is what many custom and web-view apps report for a field.
            if role == "AXGroup", element.isEditable == false { return .copyOnly }
            return .paste
        }
    }
}
