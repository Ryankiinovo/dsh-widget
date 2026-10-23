import AppKit
import SwiftUI

/// An `NSTextView` that takes keyboard focus as soon as it is in a window.
///
/// The widget opens as a non-activating panel, and SwiftUI's `@FocusState`
/// does not reliably reach the field editor on such a panel, so the composer
/// focuses itself once AppKit has attached it.
final class ComposerTextView: NSTextView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, window.firstResponder !== self else { return }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            window.makeFirstResponder(self)
        }
    }
}

/// Multiline composer backed by a real text view.
///
/// `TextField(axis: .vertical)` hides Return inside its private field editor:
/// `onSubmit` cannot see modifier flags, and neither `insertNewline` nor
/// `insertText` keeps the SwiftUI binding in sync. Owning the text view keeps
/// native editing behaviour (caret, selection, undo, IME) and makes the keyboard
/// rules explicit: Return sends (see `ComposerKeyMonitor`), Shift+Return is
/// left to AppKit and inserts a line break.
struct ComposerTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let textView = ComposerTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = text
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        // While the user is editing, the text view is authoritative and the
        // binding follows it. Pushing a binding value back here would race the
        // keystrokes still in flight and can eat a character or a line break, so
        // only mirror a clear from outside (after sending) and initial values.
        if text.isEmpty, !textView.string.isEmpty {
            context.coordinator.isProgrammaticUpdate = true
            textView.string = ""
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            context.coordinator.isProgrammaticUpdate = false
        } else if textView.window?.firstResponder !== textView, textView.string != text {
            context.coordinator.isProgrammaticUpdate = true
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            context.coordinator.isProgrammaticUpdate = false
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>
        var isProgrammaticUpdate = false

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard !isProgrammaticUpdate,
                  let textView = notification.object as? NSTextView
            else { return }
            text.wrappedValue = textView.string
        }
    }
}
