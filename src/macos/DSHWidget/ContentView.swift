import SwiftUI
import AppKit

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .active
    }
}

struct ContentView: View {
    @ObservedObject var model: WidgetModel
    var onClose: () -> Void
    @StateObject private var keyMonitor = ComposerKeyMonitor()
    /// Follow the stream only while the reader is already at the bottom.
    @StateObject private var scroll = ScrollFollowState()
    /// Window-level image viewer for attachments.
    @StateObject private var viewer = ImageViewerState()
    /// Composer grows one line per newline, then scrolls.
    @StateObject private var composerHeight = ComposerHeightState()
    /// Phone pairing card (QR + 6-digit fallback).
    @StateObject private var pairing = PairingState()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.35)
            if let errorText = model.errorText {
                errorBanner(errorText)
            }
            messageList
            Divider().opacity(0.35)
            composer
            footer
        }
        .background(
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .overlay(ImageViewerOverlay(state: viewer))
        .overlay(PairingOverlay(state: pairing, model: model))
        .environmentObject(viewer)
        .onAppear {
            keyMonitor.onSend = { model.send() }
            keyMonitor.install()
            if ProcessInfo.processInfo.environment["DSHWIDGET_TEST"] == "1" {
                // Synthetic keystrokes follow the frontmost app; make the test
                // build frontmost so its keys cannot land in another window.
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        .onDisappear {
            keyMonitor.uninstall()
        }
    }

    /// Running sessions get a green dot prefix; idle ones stay plain.
    static func sessionLabel(_ session: SessionSummary, running: Bool) -> AttributedString {
        var title = AttributedString(session.displayTitle)
        if running {
            var dot = AttributedString("●  ")
            dot.foregroundColor = .green
            title = dot + title
        }
        return title
    }

    /// Gap above a bubble: a new speaker starts a new group, the same speaker
    /// continues tightly so a multi-bubble reply reads as one block.
    static func messageGap(previous: ChatMessage?, current: ChatMessage) -> CGFloat {
        guard let previous else { return 0 }
        return previous.role == current.role ? 6 : 16
    }

    private var header: some View {
        HStack(spacing: 8) {
            Menu {
                if model.workspaceSessions.isEmpty {
                    Button("当前工作区暂无会话") {}
                        .disabled(true)
                } else {
                    Section("当前工作区") {
                        ForEach(model.workspaceSessions) { session in
                            Button {
                                model.selectSession(session.id)
                            } label: {
                                if session.id == model.selectedSessionID {
                                    Label {
                                        Text(Self.sessionLabel(session, running: model.isLiveRunning(session)))
                                    } icon: {
                                        Image(systemName: "checkmark")
                                    }
                                } else {
                                    Text(Self.sessionLabel(session, running: model.isLiveRunning(session)))
                                }
                            }
                        }
                    }
                }
                Divider()
                Button("刷新会话") {
                    Task { await model.refreshSessions() }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(model.selectedTitle)
                        .lineLimit(1)
                        .font(.system(size: 13, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 240, alignment: .leading)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: false, vertical: true)
            .help("切换会话")

            Spacer(minLength: 4)

            Button {
                pairing.open(model: model)
            } label: {
                Image(systemName: "qrcode")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("手机配对")

            Button {
                model.newSession()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("新建会话")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("隐藏")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }


    private func errorBanner(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
            Text(text)
                .font(.system(size: 11))
                .lineLimit(3)
            Spacer(minLength: 4)
            Button {
                model.retry()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .help("重试连接并重新加载会话")
            Button {
                model.errorText = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.08))
    }

    /// Index of the reply that is still being written, if any. The status line
    /// renders immediately above it so the growing bubble appears underneath.
    private var streamingMessageIndex: Int? {
        model.visibleMessages.lastIndex { $0.role == "assistant" && $0.streaming }
    }

    private var messageList: some View {
        // The status line is a turn-level element pinned to the end of the
        // transcript: it never rides on a bubble, so a growing answer can't
        // shove it around or leave it stranded above an older message.
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if model.visibleMessages.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.system(size: 22, weight: .light))
                                .foregroundStyle(.secondary)
                            Text(model.emptyHint)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 50)
                    }
                    ForEach(Array(model.visibleMessages.enumerated()), id: \.element.id) { index, message in
                        // While an answer streams, the status line sits directly
                        // above that bubble: "上面在生成、下面出气泡" instead of the
                        // line trailing the bubble like a footnote.
                        if model.activity.isRunning, index == streamingMessageIndex {
                            ThinkingStatusView(activity: model.activity)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 10)
                                .transition(.opacity)
                        }
                        MessageRow(message: message)
                            .id(message.id)
                            .padding(.top, Self.messageGap(
                                previous: index > 0 ? model.visibleMessages[index - 1] : nil,
                                current: message
                            ))
                    }
                    if model.activity.isRunning, streamingMessageIndex == nil {
                        ThinkingStatusView(activity: model.activity)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 10)
                            .transition(.opacity)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .background(ScrollObserver { floatValue, overflows, live in
                    handleScroll(floatValue: floatValue, overflows: overflows, live: live)
                })
            }
            .onChange(of: model.scrollTick) { _, _ in
                followIfPinned(proxy)
            }
            .onChange(of: model.messages.count) { _, _ in
                followIfPinned(proxy)
            }
            .onChange(of: model.selectedSessionID) { _, _ in
                scroll.userScrolledAway = false
                scroll.atBottom = true
                scroll.showJump = false
                DispatchQueue.main.async {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onAppear {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .overlay(alignment: .bottomTrailing) {
                if scroll.showJump {
                    Button {
                        scroll.userScrolledAway = false
                        scroll.showJump = false
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(7)
                            .background(.regularMaterial, in: Circle())
                            .overlay(Circle().strokeBorder(.white.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 14)
                    .padding(.bottom, 10)
                    .help("回到底部")
                    .transition(.opacity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func handleScroll(floatValue: CGFloat, overflows: Bool, live: Bool) {
        let atBottom = ScrollFollow.isAtBottom(floatValue: floatValue, overflows: overflows)
        scroll.atBottom = atBottom
        if live && !atBottom { scroll.userScrolledAway = true }
        if atBottom { scroll.userScrolledAway = false }
        let jump = ScrollFollow.shouldShowJump(
            userScrolledAway: scroll.userScrolledAway,
            atBottom: atBottom
        )
        if jump != scroll.showJump {
            withAnimation(.easeOut(duration: 0.12)) { scroll.showJump = jump }
            WidgetLog.event("scroll-jump", "show=\(jump ? 1 : 0) fv=\(Int(floatValue * 1000))")
        }
    }

    private func followIfPinned(_ proxy: ScrollViewProxy) {
        guard ScrollFollow.shouldFollow(userScrolledAway: scroll.userScrolledAway) else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.composerImages.isEmpty {
                composerImageStrip
            }
            composerRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// Thumbnails of pasted-but-unsent images. Removing one is a click on the
    /// small badge; no extra button row is introduced.
    private var composerImageStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.composerImages) { image in
                    ZStack(alignment: .topTrailing) {
                        if let thumbnail = image.thumbnail {
                            Image(nsImage: thumbnail)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 46, height: 46)
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                        Button {
                            model.removeComposerImage(image.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.white, .black.opacity(0.55))
                        }
                        .buttonStyle(.plain)
                        .padding(2)
                        .help("移除这张图片")
                    }
                }
            }
            .padding(.leading, 2)
        }
        .frame(height: 48)
    }

    private var canSend: Bool {
        !model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !model.composerImages.isEmpty
    }

    private var composerRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ZStack(alignment: .topLeading) {
                ComposerTextEditor(
                    text: $model.input,
                    height: $composerHeight.height,
                    onPasteImages: { model.addPastedImages($0) }
                )
                    .frame(height: composerHeight.height)
                if model.input.isEmpty {
                    Text("发消息…（Shift+Enter 换行）")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 9)
                        .padding(.top, 6)
                        .allowsHitTesting(false)
                }
            }
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            if model.isRunning {
                Button {
                    model.cancel()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 30, height: 30)
                        .background(Color.red.opacity(0.18), in: Circle())
                }
                .buttonStyle(.plain)
                .help("停止")
            } else {
                Button {
                    model.send()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 30, height: 30)
                        .background(Color.accentColor.opacity(canSend ? 0.85 : 0.10), in: Circle())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help("发送（Enter），Shift+Enter 换行")
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Menu {
                if model.workspaces.isEmpty {
                    Button("暂无工作区") {}
                        .disabled(true)
                }
                ForEach(model.workspaces) { workspace in
                    Button {
                        model.selectWorkspace(workspace)
                    } label: {
                        if workspace.path == model.selectedWorkspace?.path {
                            Label(workspace.displayTitle, systemImage: "checkmark")
                        } else {
                            Text(workspace.displayTitle)
                        }
                    }
                }
                Divider()
                Button("刷新工作区") {
                    Task { await model.refreshSessions() }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.system(size: 9, weight: .medium))
                    Text(model.workspaceTitle)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: false, vertical: true)
            .help("切换工作区")

            Spacer(minLength: 4)

            if let status = model.syncStatus {
                Text(status)
                    .foregroundStyle(.secondary)
            }

            Button {
                model.syncHistory()
            } label: {
                if model.isSyncingHistory {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 9.5, weight: .medium))
                        .frame(width: 14, height: 14)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .disabled(model.isSyncingHistory || model.isLoadingHistory || model.connection != .connected)
            .help("同步历史记录（只补未同步的增量）")

            Circle()
                .fill(connectionColor)
                .frame(width: 5, height: 5)
            Text(model.connection.label)
            if !model.visibleMessages.isEmpty {
                Text("· \(model.visibleMessages.count) 条")
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var connectionColor: Color {
        switch model.connection {
        case .connected: return .green
        case .waiting: return .orange
        case .offline: return .red
        }
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    @StateObject private var hover = HoverState()
    @StateObject private var feedback = CopyFeedback()
    @EnvironmentObject private var viewer: ImageViewerState

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == "user" {
                Spacer(minLength: 36)
            }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 5) {
                // Photos render as a bare thumbnail strip above the text; only
                // the text gets the bubble fill. A message that is photos alone
                // draws no empty bubble.
                if !message.attachments.isEmpty || !message.localImages.isEmpty {
                    MessageImageStrip(attachments: message.attachments,
                                      localImages: message.localImages)
                }
                if !message.text.isEmpty {
                    textBubble
                }
            }
            if message.role != "user" {
                Spacer(minLength: 36)
            }
        }
    }


    /// The text part of a message, with its own bubble: photos sit above it as a
    /// bare thumbnail strip and never share the bubble fill.
    private var textBubble: some View {
        MarkdownMessageText(text: message.text, fillWidth: false)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .foregroundStyle(Color.primary)
            .background(bubbleBackground)
            .overlay(alignment: .topTrailing) {
                copyButton
            }
            .overlay(bubbleStroke)
            .shadow(color: shadowColor, radius: 6, y: 1)
            .onHover { hover.hovering = $0 }
    }

    private var copyButton: some View {
        Button {
            feedback.copy(message.text)
        } label: {
            Image(systemName: feedback.copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(4)
        }
        .buttonStyle(.plain)
        .help("复制这条消息")
        .opacity(hover.hovering || feedback.copied ? 1 : 0)
    }

    private var isUser: Bool { message.role == "user" }
    private var shadowColor: Color { Color.black.opacity(0.14) }

    private var bubbleBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(isUser ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.16))
    }

    private var bubbleStroke: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
    }
}

/// Small pulsing dot used while a reply streams in.
private struct StreamingPulse: View {
    @StateObject private var state = PulseState()

    var body: some View {
        Circle()
            .fill(Color.accentColor.opacity(0.85))
            .frame(width: 5, height: 5)
            .opacity(state.on ? 1 : 0.25)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    state.on = true
                }
            }
    }
}