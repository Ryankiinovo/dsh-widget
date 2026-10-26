import Foundation
import Combine
import AppKit
import SwiftUI

/// Auto-follow rules for the transcript.
///
/// Streaming output should keep the newest text visible only while the reader
/// is at the bottom. Once they actively scroll up, stop dragging the viewport
/// back down; follow again when they return to the bottom.
enum ScrollFollow {
    /// NSScroller's floatValue is 1.0 at the very bottom; a hair of slack keeps
    /// trackpad inertia from pinning/unpinning on every pixel.
    static let bottomThreshold: CGFloat = 0.995

    static func isAtBottom(floatValue: CGFloat, overflows: Bool) -> Bool {
        !overflows || floatValue >= bottomThreshold
    }

    static func shouldFollow(userScrolledAway: Bool) -> Bool { !userScrolledAway }

    static func shouldShowJump(userScrolledAway: Bool, atBottom: Bool) -> Bool {
        userScrolledAway && !atBottom
    }
}

/// View state for the transcript's follow/jump behaviour. A plain
/// ObservableObject is used instead of `@State` because this app builds with the
/// CommandLineTools SwiftUI SDK, which ships property wrappers but not the
/// SwiftUI macro plugin that newer `@State` expands to.
@MainActor
final class ScrollFollowState: ObservableObject {
    /// Set only by an actual scroll gesture that left the bottom.
    @Published var userScrolledAway = false
    @Published var atBottom = true
    @Published var showJump = false
}

/// Reports the enclosing NSScrollView's position.
///
/// A GeometryReader inside a macOS ScrollView does not update while the user
/// scrolls (macOS 14 has no `onScrollGeometryChange`), so the widget reads the
/// real NSScrollView's scroller instead.
struct ScrollObserver: NSViewRepresentable {
    var onReport: (_ floatValue: CGFloat, _ overflows: Bool, _ isLiveScrolling: Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ObserverView()
        view.onReport = onReport
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ObserverView)?.onReport = onReport
    }

    final class ObserverView: NSView {
        var onReport: ((CGFloat, Bool, Bool) -> Void)?
        private weak var scrollView: NSScrollView?
        private var observers: [NSObjectProtocol] = []
        private var liveScrolling = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }

        private func attach() {
            guard let enclosing = enclosingScrollView else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.attach() }
                return
            }
            if scrollView === enclosing && !observers.isEmpty {
                report()
                return
            }
            detach()
            scrollView = enclosing
            enclosing.contentView.postsBoundsChangedNotifications = true
            let center = NotificationCenter.default
            observers.append(center.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: enclosing.contentView,
                queue: .main
            ) { [weak self] _ in self?.report() })
            observers.append(center.addObserver(
                forName: NSScrollView.willStartLiveScrollNotification,
                object: enclosing,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.liveScrolling = true
                self.report()
            })
            observers.append(center.addObserver(
                forName: NSScrollView.didEndLiveScrollNotification,
                object: enclosing,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.liveScrolling = false
                self.report()
            })
            report()
        }

        private func detach() {
            let center = NotificationCenter.default
            observers.forEach(center.removeObserver)
            observers.removeAll()
        }

        private var lastOvershootReport = Date.distantPast

        private func report() {
            guard let scrollView else { return }
            let scroller = scrollView.verticalScroller
            let floatValue = CGFloat(scroller?.floatValue ?? 1)
            let overflows = (scroller?.knobProportion ?? 1) < 0.999
            onReport?(floatValue, overflows, liveScrolling)

            // 「问完问题拖到最底，整屏都是空的」现场诊断（2026-10-26）：视口跑到
            // 真实内容下方时，floatValue 依然是 1，只有量出来的高度能区分。
            // 正常滚动永远不会进这里，所以按 2 秒节流就够。
            let contentHeight = scrollView.documentView?.frame.height ?? 0
            let offset = scrollView.contentView.bounds.origin.y
            let viewport = scrollView.contentView.bounds.height
            let slack = contentHeight - (offset + viewport)
            if slack < -2, Date().timeIntervalSince(lastOvershootReport) > 2 {
                lastOvershootReport = Date()
                WidgetLog.event(
                    "scroll-overshoot",
                    "content=\(Int(contentHeight)) offset=\(Int(offset)) viewport=\(Int(viewport)) slack=\(Int(slack))"
                )
            }
        }

        deinit { detach() }
    }
}
