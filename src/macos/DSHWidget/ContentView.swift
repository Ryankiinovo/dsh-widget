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
                                    Label(session.displayTitle + (session.running ? " · 运行中" : ""), systemImage: "checkmark")
                                } else {
                                    Text(session.displayTitle + (session.running ? " · 运行中" : ""))
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

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
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
                    ForEach(model.visibleMessages) { message in
                        MessageRow(message: message)
                            .id(message.id)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
            .onChange(of: model.scrollTick) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onChange(of: model.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onAppear {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ZStack(alignment: .topLeading) {
                ComposerTextEditor(text: $model.input)
                    .frame(height: 62)
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
                        .background(Color.accentColor.opacity(model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.10 : 0.85), in: Circle())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("发送（Enter），Shift+Enter 换行")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == "user" {
                Spacer(minLength: 36)
            }
            VStack(alignment: .leading, spacing: 4) {
                if message.text.isEmpty && message.streaming {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("思考中…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    MarkdownMessageText(text: message.text, fillWidth: message.role != "user")
                        .fixedSize(horizontal: false, vertical: true)
                }
                if message.streaming && !message.text.isEmpty {
                    ProgressView().controlSize(.mini)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(message.role == "user" ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.07))
            )
            if message.role != "user" {
                Spacer(minLength: 36)
            }
        }
    }
}