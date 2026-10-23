import SwiftUI
import AppKit

/// Small per-view state holders. `@State` is unavailable in this build setup
/// (the CommandLineTools SwiftUI SDK ships the property wrapper but not the
/// macro plugin it now expands to), so transient UI state lives in
/// ObservableObjects instead.
@MainActor
final class CopyFeedback: ObservableObject {
    @Published var copied = false

    func flash() {
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.copied = false
        }
    }

    func copy(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        flash()
    }
}

@MainActor
final class HoverState: ObservableObject {
    @Published var hovering = false
}

@MainActor
final class PulseState: ObservableObject {
    @Published var on = false
}

/// Loads one attachment through the bridge (bearer token from the discovery
/// file) and caches decoded images by attachment id.
@MainActor
final class AttachmentImageLoader: ObservableObject {
    @Published var image: NSImage?
    @Published var failed = false
    private static let cache = NSCache<NSString, NSImage>()

    func load(_ attachment: MessageAttachment) {
        guard image == nil, !failed else { return }
        let key = attachment.attachmentId as NSString
        if let cached = Self.cache.object(forKey: key) {
            image = cached
            return
        }
        guard let info = Discovery.load(),
              let base = URL(string: "http://127.0.0.1:" + String(info.port)) else {
            failed = true
            return
        }
        let url = base
            .appendingPathComponent("v1/attachments")
            .appendingPathComponent(attachment.attachmentId)
        var request = URLRequest(url: url)
        request.setValue("Bearer " + info.token, forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            DispatchQueue.main.async {
                if let data, let nsImage = NSImage(data: data) {
                    Self.cache.setObject(nsImage, forKey: key)
                    self.image = nsImage
                } else {
                    self.failed = true
                }
            }
        }.resume()
    }
}

/// Local file for a content-addressed attachment id; used by "open in Preview".
func attachmentFileURL(_ attachmentId: String) -> URL? {
    let prefix = "sha256:"
    guard attachmentId.hasPrefix(prefix) else { return nil }
    let hex = String(attachmentId.dropFirst(prefix.count))
    guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".dsh/attachments/v1/objects")
        .appendingPathComponent(String(hex.prefix(2)))
        .appendingPathComponent(hex)
}

/// One 56pt thumbnail of a message image strip. An overflow value turns the
/// last slot into a "+N" badge instead of one more photo.
struct MessageThumbnail: View {
    let attachment: MessageAttachment?
    let localImage: NSImage?
    let overflow: Int?
    let action: () -> Void
    @StateObject private var loader = AttachmentImageLoader()
    @StateObject private var hover = HoverState()

    init(attachment: MessageAttachment? = nil, localImage: NSImage? = nil,
         overflow: Int? = nil, action: @escaping () -> Void) {
        self.attachment = attachment
        self.localImage = localImage
        self.overflow = overflow
        self.action = action
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: MessageImageStripLayout.cornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.06))
            photo
            if let overflow {
                Color.black.opacity(0.55)
                Text("+" + String(overflow))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: MessageImageStripLayout.thumbnail, height: MessageImageStripLayout.thumbnail)
        .clipShape(RoundedRectangle(cornerRadius: MessageImageStripLayout.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MessageImageStripLayout.cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(hover.hovering ? 0.36 : 0.12), lineWidth: 0.5)
        )
        .scaleEffect(hover.hovering ? 1.04 : 1)
        .animation(.easeOut(duration: 0.1), value: hover.hovering)
        .onHover { hover.hovering = $0 }
        .onTapGesture(perform: action)
        .help(helpText)
        .contextMenu {
            if let attachment {
                Button("在预览中打开") {
                    if let url = attachmentFileURL(attachment.attachmentId) {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .onAppear { if let attachment { loader.load(attachment) } }
    }

    @ViewBuilder
    private var photo: some View {
        if let image = localImage ?? loader.image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
        } else if loader.failed {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        } else {
            ProgressView().controlSize(.mini)
        }
    }

    private var helpText: String {
        if let overflow { return "还有 " + String(overflow) + " 张" }
        return attachment?.name ?? "查看图片"
    }
}

/// A message's photos as a single row of thumbnails above the text bubble.
/// Past nine photos the row keeps nine slots and the last one shows "+N".
struct MessageImageStrip: View {
    let attachments: [MessageAttachment]
    let localImages: [NSImage]
    @EnvironmentObject private var viewer: ImageViewerState

    private var total: Int { localImages.count + attachments.count }
    private var plan: (shown: Int, overflow: Int) {
        MessageImageStripLayout.plan(count: total)
    }

    var body: some View {
        HStack(spacing: MessageImageStripLayout.spacing) {
            ForEach(0..<plan.shown, id: \.self) { index in
                thumbnail(at: index)
            }
        }
    }

    @ViewBuilder
    private func thumbnail(at index: Int) -> some View {
        let overflow: Int? = (index == plan.shown - 1 && plan.overflow > 0) ? plan.overflow : nil
        let open = {
            viewer.open(locals: localImages, attachments: attachments, start: index)
        }
        if index < localImages.count {
            MessageThumbnail(localImage: localImages[index], overflow: overflow, action: open)
        } else {
            MessageThumbnail(attachment: attachments[index - localImages.count],
                             overflow: overflow, action: open)
        }
    }
}

/// One page of the window-level image viewer: either a photo the message is
/// still previewing locally or an attachment that loads through the bridge.
struct ViewerPage: Identifiable {
    let id: String
    let title: String?
    let local: NSImage?
    let attachment: MessageAttachment?
}

/// Window-level image viewer; click anywhere (or Esc) closes it and the arrow
/// keys page through every photo of the message it was opened from.
@MainActor
final class ImageViewerState: ObservableObject {
    @Published var pages: [ViewerPage] = []
    @Published var index: Int = 0

    var isPresented: Bool { !pages.isEmpty }

    var current: ViewerPage? {
        guard pages.indices.contains(index) else { return nil }
        return pages[index]
    }

    func open(locals: [NSImage], attachments: [MessageAttachment], start: Int) {
        var built: [ViewerPage] = []
        for (offset, image) in locals.enumerated() {
            built.append(ViewerPage(id: "local-" + String(offset), title: "已发送图片",
                                    local: image, attachment: nil))
        }
        for attachment in attachments {
            built.append(ViewerPage(id: attachment.attachmentId,
                                    title: attachment.name ?? "图片",
                                    local: nil, attachment: attachment))
        }
        guard !built.isEmpty else { return }
        pages = built
        index = min(max(start, 0), built.count - 1)
    }

    func next() {
        guard !pages.isEmpty else { return }
        index = (index + 1) % pages.count
    }

    func previous() {
        guard !pages.isEmpty else { return }
        index = (index - 1 + pages.count) % pages.count
    }

    func close() {
        pages = []
        index = 0
    }
}

struct ImageViewerOverlay: View {
    @ObservedObject var state: ImageViewerState

    var body: some View {
        Group {
            if let page = state.current {
                ZStack {
                    Color.black.opacity(0.86)
                        .ignoresSafeArea()
                        .onTapGesture { state.close() }
                    ViewerImageView(page: page)
                        .id(page.id)
                        .padding(36)
                        .shadow(color: .black.opacity(0.45), radius: 24)
                    if state.pages.count > 1 {
                        HStack {
                            pagerButton("chevron.left") { state.previous() }
                            Spacer(minLength: 0)
                            pagerButton("chevron.right") { state.next() }
                        }
                        .padding(.horizontal, 14)
                    }
                    VStack {
                        topBar(page)
                        Spacer(minLength: 0)
                        if state.pages.count > 1 { hint }
                    }
                }
                .background(ViewerKeyMonitor(
                    onEscape: { state.close() },
                    onPrevious: { state.previous() },
                    onNext: { state.next() }
                ))
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: state.isPresented)
    }

    private func pagerButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Color.black.opacity(0.44), in: Circle())
        }
        .buttonStyle(.plain)
    }

    private func topBar(_ page: ViewerPage) -> some View {
        HStack(spacing: 8) {
            if let title = page.title, !title.isEmpty {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.black.opacity(0.4), in: Capsule())
            }
            if state.pages.count > 1 {
                Text(String(state.index + 1) + " / " + String(state.pages.count))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.black.opacity(0.4), in: Capsule())
            }
            Spacer(minLength: 0)
            Button { state.close() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 24, height: 24)
                    .background(Color.black.opacity(0.45), in: Circle())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .help("关闭（Esc）")
        }
        .padding(.horizontal, 12)
        // Keep the title chip and close button clear of the panel's own title bar
        // (fullSizeContentView draws content under it).
        .padding(.top, 40)
        .padding(.bottom, 12)
    }

    private var hint: some View {
        Text("← → 切换 · Esc 关闭")
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.55))
            .padding(.bottom, 14)
    }
}

/// The photo currently shown; remote attachments load through the bridge and
/// reuse the strip's cache.
struct ViewerImageView: View {
    let page: ViewerPage
    @StateObject private var loader = AttachmentImageLoader()

    var body: some View {
        Group {
            if let image = page.local ?? loader.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else if loader.failed {
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 22))
                    Text("图片加载失败")
                        .font(.system(size: 11))
                }
                .foregroundStyle(.white.opacity(0.65))
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .onAppear { if let attachment = page.attachment { loader.load(attachment) } }
    }
}

/// Local key monitor: Esc closes the viewer and the left/right arrows page
/// through photos. It swallows those keys while the viewer is up so the
/// composer does not also see them.
struct ViewerKeyMonitor: NSViewRepresentable {
    let onEscape: () -> Void
    let onPrevious: () -> Void
    let onNext: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onEscape: onEscape, onPrevious: onPrevious, onNext: onNext)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onEscape = onEscape
        context.coordinator.onPrevious = onPrevious
        context.coordinator.onNext = onNext
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    final class Coordinator {
        var onEscape: () -> Void
        var onPrevious: () -> Void
        var onNext: () -> Void
        private var monitor: Any?

        init(onEscape: @escaping () -> Void, onPrevious: @escaping () -> Void, onNext: @escaping () -> Void) {
            self.onEscape = onEscape
            self.onPrevious = onPrevious
            self.onNext = onNext
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                switch event.keyCode {
                case 53:
                    DispatchQueue.main.async { self.onEscape() }
                case 123:
                    DispatchQueue.main.async { self.onPrevious() }
                case 124:
                    DispatchQueue.main.async { self.onNext() }
                default:
                    return event
                }
                return nil
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
