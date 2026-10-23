import AppKit
import SwiftUI

/// An `NSTextView` that takes keyboard focus as soon as it is in a window.
///
/// The widget opens as a non-activating panel, and SwiftUI's `@FocusState`
/// does not reliably reach the field editor on such a panel, so the composer
/// focuses itself once AppKit has attached it.
final class ComposerTextView: NSTextView {
    /// Called when the pasteboard holds an image instead of plain text. The
    /// image becomes a pending attachment and the text view stays untouched.
    var onPasteImages: (([(image: NSImage, name: String?)]) -> Void)?

    override func paste(_ sender: Any?) {
        let images = ComposerPasteboard.images()
        WidgetLog.event("composer-paste", "images=\(images.count)")
        if !images.isEmpty, let onPasteImages {
            onPasteImages(images)
            return
        }
        super.paste(sender)
    }

    /// The widget runs as an accessory app without a main menu, so ⌘V never
    /// reaches the standard Paste menu item. Route it to `paste(_:)` directly.
    private func isPasteShortcut(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
            && event.charactersIgnoringModifiers?.lowercased() == "v"
    }

    override func keyDown(with event: NSEvent) {
        if isPasteShortcut(event) {
            paste(nil)
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isPasteShortcut(event) {
            paste(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Image files dropped on the composer become pending attachments. The
    /// widget has no upload path, so anything that is not an image is handed
    /// back to AppKit (which inserts file names or text as before).
    private var hasRegisteredDragTypes = false

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let accepts = ComposerPasteboard.hasImages(from: sender.draggingPasteboard)
        WidgetLog.event("composer-drag-enter", "images=" + (accepts ? "1" : "0"))
        return accepts ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        ComposerPasteboard.hasImages(from: sender.draggingPasteboard)
            ? .copy
            : super.draggingUpdated(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        ComposerPasteboard.hasImages(from: sender.draggingPasteboard)
            ? true
            : super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let images = ComposerPasteboard.images(from: sender.draggingPasteboard)
        guard !images.isEmpty, let onPasteImages else {
            return super.performDragOperation(sender)
        }
        WidgetLog.event("composer-drop", "images=" + String(images.count))
        onPasteImages(images)
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if !hasRegisteredDragTypes {
            registerForDraggedTypes([.fileURL, .tiff, .png])
            hasRegisteredDragTypes = true
        }
        guard let window, window.firstResponder !== self else { return }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            window.makeFirstResponder(self)
        }
    }
}

/// Height holder for the composer. The SDK in this environment cannot expand
/// `@State`, so SwiftUI state lives in observable objects.
@MainActor
final class ComposerHeightState: ObservableObject {
    @Published var height: CGFloat = ComposerMetrics.minHeight
}

enum ComposerMetrics {
    /// One line of 13pt text plus the text container insets.
    static let minHeight: CGFloat = 30
    /// Enough room for roughly seven lines before the editor starts scrolling.
    static let maxHeight: CGFloat = 140
    static let inset = NSSize(width: 9, height: 6)
}

/// Multiline composer backed by a real text view.
///
/// `TextField(axis: .vertical)` hides Return inside its private field editor:
/// `onSubmit` cannot see modifier flags, and neither `insertNewline` nor
/// `insertText` keeps the SwiftUI binding in sync. Owning the text view keeps
/// native editing behaviour (caret, selection, undo, IME) and makes the keyboard
/// rules explicit: Return sends (see `ComposerKeyMonitor`), Shift+Return is
/// left to AppKit and inserts a line break.
///
/// The view also reports the height its text needs, so the composer starts as a
/// single line and grows one line per newline (up to `maxHeight`, then scrolls).
struct ComposerTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var onPasteImages: ([(image: NSImage, name: String?)]) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, height: $height, onPasteImages: onPasteImages)
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
        textView.textContainerInset = ComposerMetrics.inset
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = text
        textView.onPasteImages = context.coordinator.onPasteImages
        scroll.documentView = textView
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        // The model closure can change identity between updates; keep the text
        // view pointing at the current one.
        context.coordinator.onPasteImages = onPasteImages
        (textView as? ComposerTextView)?.onPasteImages = onPasteImages
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
        // Re-measure on every update: the first pass has no width yet, and a
        // clear after sending must collapse the composer back to one line.
        context.coordinator.reportHeight(for: textView)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>
        private let height: Binding<CGFloat>
        weak var textView: NSTextView?
        var isProgrammaticUpdate = false
        var onPasteImages: ([(image: NSImage, name: String?)]) -> Void
        private var pending = false
        private var retries = 0

        init(text: Binding<String>, height: Binding<CGFloat>,
             onPasteImages: @escaping ([(image: NSImage, name: String?)]) -> Void) {
            self.text = text
            self.height = height
            self.onPasteImages = onPasteImages
        }

        func textDidChange(_ notification: Notification) {
            guard !isProgrammaticUpdate,
                  let textView = notification.object as? NSTextView
            else { return }
            text.wrappedValue = textView.string
            reportHeight(for: textView)
        }

        func reportHeight(for textView: NSTextView) {
            guard !pending else { return }
            let width = max(textView.bounds.width, textView.enclosingScrollView?.contentSize.width ?? 0)
            if width < 40, retries < 6 {
                retries += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self, weak textView] in
                    guard let self, let textView else { return }
                    self.reportHeight(for: textView)
                }
                return
            }
            retries = 0
            pending = true
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self else { return }
                self.pending = false
                guard let textView,
                      let layoutManager = textView.layoutManager,
                      let container = textView.textContainer
                else { return }
                layoutManager.ensureLayout(for: container)
                let content = layoutManager.usedRect(for: container).height
                let wanted = ceil(content) + ComposerMetrics.inset.height * 2
                let clamped = min(max(wanted, ComposerMetrics.minHeight), ComposerMetrics.maxHeight)
                if abs(self.height.wrappedValue - clamped) > 0.5 {
                    self.height.wrappedValue = clamped
                }
            }
        }
    }
}
