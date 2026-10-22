import AppKit
import CoreGraphics
import SwiftUI

@main
struct DSHWidgetMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

final class WidgetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var panel: WidgetPanel!
    private var statusItem: NSStatusItem!
    private let model = WidgetModel()
    private let sizeKey = "dshWidget.size"
    private var positioning = false
    private var lastFrame: NSRect?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupPanel()
        setupStatusItem()
        model.start()
        panel.orderFrontRegardless()
    }

    private func setupPanel() {
        let stored = UserDefaults.standard.dictionary(forKey: sizeKey)
        let width = max(340, min(760, (stored?["width"] as? Double) ?? 400))
        let height = max(420, min(1000, (stored?["height"] as? Double) ?? 620))
        panel = WidgetPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        // Sit on the desktop, not above other apps: above Finder's desktop icons
        // but below normal window levels. It stays put across Spaces and is
        // hidden by full-screen apps instead of floating over them.
        let desktopLevel = Int(CGWindowLevelForKey(.desktopIconWindow)) + 1
        panel.level = NSWindow.Level(rawValue: desktopLevel)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.minSize = NSSize(width: 340, height: 420)
        panel.maxSize = NSSize(width: 760, height: 1000)
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.delegate = self

        let root = ContentView(model: model, onClose: { [weak self] in
            self?.panel.orderOut(nil)
        })
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = []
        panel.contentViewController = hosting
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.masksToBounds = true
        panel.contentMinSize = NSSize(width: 340, height: 420)
        panel.contentMaxSize = NSSize(width: 760, height: 1000)
        panel.setContentSize(NSSize(width: width, height: height))
        positionTopRight()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "DSH")
        statusItem.button?.toolTip = "DSH 桌面小组件"
        let menu = NSMenu()
        let toggle = NSMenuItem(title: "显示 / 隐藏", action: #selector(togglePanel), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc private func togglePanel() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            positionTopRight()
            panel.orderFrontRegardless()
        }
    }

    @objc private func quit() {
        model.stop()
        NSApp.terminate(nil)
    }

    private func positionTopRight() {
        guard let screen = NSScreen.main, panel != nil else { return }
        positioning = true
        defer { positioning = false }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let width = max(340, min(760, size.width))
        let height = max(420, min(1000, size.height))
        let origin = NSPoint(
            x: visible.maxX - width - 20,
            y: visible.maxY - height - 20
        )
        let frame = NSRect(origin: origin, size: NSSize(width: width, height: height))
        panel.setFrame(frame, display: true)
        lastFrame = frame
    }

    private func saveSize() {
        let size = panel.frame.size
        UserDefaults.standard.set(["width": size.width, "height": size.height], forKey: sizeKey)
    }

    func windowDidResize(_ notification: Notification) {
        guard !positioning else { return }
        let current = panel.frame
        let previous = lastFrame
        lastFrame = current
        saveSize()
        // Keep the top-right anchor while the window is grown from its left or
        // bottom edge. Growing from the right edge is left alone so that a
        // normal lower-right drag can widen the panel.
        guard let previous,
              abs(current.origin.x - previous.origin.x) > 0.5 ||
              abs(current.origin.y - previous.origin.y) > 0.5
        else { return }
        positionTopRight()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        panel.orderOut(nil)
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }
}
