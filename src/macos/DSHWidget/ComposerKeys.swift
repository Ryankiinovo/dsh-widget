import AppKit
import SwiftUI

/// Turns a bare Return into a send while leaving every modified Return to
/// AppKit (`ComposerKey` holds the decision itself).
///
/// The widget owns its text view, so this monitor only has to intercept the
/// key before AppKit inserts a line break; it never touches text or focus.
final class ComposerKeyMonitor: ObservableObject {
    /// Sends the current draft, same path as the send button.
    var onSend: () -> Void = {}

    private var monitor: Any?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let editor = NSApp.keyWindow?.firstResponder as? ComposerTextView else { return event }
        switch ComposerKey.action(
            keyCode: event.keyCode,
            flags: event.modifierFlags,
            isComposing: editor.hasMarkedText()
        ) {
        case .passThrough:
            return event
        case .send:
            onSend()
            return nil
        }
    }
}
