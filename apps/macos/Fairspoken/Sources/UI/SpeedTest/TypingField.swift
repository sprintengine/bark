import AppKit
import SwiftUI

/// The keys of the typing step: an invisible text view laid over the passage, which draws what
/// was typed itself. Every keystroke is the typist's own: pasting and dropping text are refused,
/// and no spelling correction, text replacement, smart quotes, completion or prediction changes
/// what was typed.
struct TypingField: NSViewRepresentable {
    var text: String
    var onChange: (String) -> Void
    var onPasteRefused: () -> Void
    var onEscape: () -> Void

    func makeNSView(context: Context) -> KeystrokeTextView {
        let view = KeystrokeTextView()
        view.delegate = context.coordinator
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = false
        view.usesFindPanel = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticTextCompletionEnabled = false
        view.smartInsertDeleteEnabled = false
        view.inlinePredictionType = .no
        view.writingToolsBehavior = .none
        view.unregisterDraggedTypes()
        view.drawsBackground = false
        view.textColor = .clear
        view.insertionPointColor = .clear
        view.selectedTextAttributes = [.foregroundColor: NSColor.clear, .backgroundColor: NSColor.clear]
        view.font = .systemFont(ofSize: 17)
        view.setAccessibilityLabel("Type the passage")
        view.onPasteRefused = onPasteRefused
        view.onEscape = onEscape
        return view
    }

    func updateNSView(_ view: KeystrokeTextView, context: Context) {
        context.coordinator.parent = self
        view.onPasteRefused = onPasteRefused
        view.onEscape = onEscape
        if view.string != text { view.string = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TypingField
        init(parent: TypingField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.onChange(view.string)
        }
    }
}

/// Takes focus as soon as it is on screen, so typing starts without a click.
final class KeystrokeTextView: NSTextView {
    var onPasteRefused: (() -> Void)?
    var onEscape: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window === window else { return }
            window.makeFirstResponder(self)
        }
    }

    override func paste(_ sender: Any?) { onPasteRefused?() }
    override func pasteAsPlainText(_ sender: Any?) { onPasteRefused?() }
    override func pasteAsRichText(_ sender: Any?) { onPasteRefused?() }
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        onPasteRefused?()
        return false
    }

    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func complete(_ sender: Any?) { onEscape?() }
}
