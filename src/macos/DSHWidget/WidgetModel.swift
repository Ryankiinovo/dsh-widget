import Foundation
import SwiftUI

@MainActor
final class WidgetModel: ObservableObject {
    enum Connection: Equatable {
        case waiting
        case connected
        case offline

        var label: String {
            switch self {
            case .waiting: return "等待 DSH"
            case .connected: return "已连接"
            case .offline: return "DSH 未连接"
            }
        }
    }

    @Published var sessions: [SessionSummary] = []
    @Published var workspaces: [WorkspaceSummary] = []
    @Published var messages: [ChatMessage] = []
    @Published var isLoadingHistory = false
    @Published var isSyncingHistory = false
    @Published var syncStatus: String?

    var visibleMessages: [ChatMessage] {
        var result = messages.filter { !$0.text.isEmpty || $0.pending }
        if let last = messages.last,
           last.role == "assistant",
           last.streaming,
           last.text.isEmpty,
           !result.contains(where: { $0.id == last.id }) {
            result.append(last)
        }
        return result
    }
    @Published var selectedSessionID: String?
    @Published var input: String = ""
    @Published var isRunning: Bool = false
    @Published var connection: Connection = .waiting
    @Published var errorText: String?
    @Published var scrollTick: Int = 0

    private var client: BridgeClient?
    private var streamTask: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var streamingID: String?
    private var streamFailures = 0
    private var autoSyncAfterReconnect = false
    private var syncTask: Task<Void, Never>?
    private var syncStatusTask: Task<Void, Never>?
    /// Full transcripts are cached per session so switching back is instant.
    /// The cache is deliberately small; recent sessions are the common case.
    private var fullHistoryCache: [String: [ChatMessage]] = [:]
    private var fullHistoryOrder: [String] = []
    private var fullHistoryLoaded: Set<String> = []
    private let selectedKey = "dshWidget.selectedSession"
    private let defaultCwd = NSHomeDirectory() + "/Documents/AI-Work"
    private let workspaceRegistryPath = NSHomeDirectory() + "/.dsh/storages/workspace.json"
    /// DSH's registry-global archive set. Archived sessions stay out of every
    /// picker, matching the DSH sidebar.
    private var archivedSessionIDs: Set<String> = []

    init() {
        if let saved = UserDefaults.standard.string(forKey: selectedKey) {
            selectedSessionID = saved
        }
        loadWorkspaces()
    }

    deinit {
        streamTask?.cancel()
        historyTask?.cancel()
        syncTask?.cancel()
        syncStatusTask?.cancel()
        connectTask?.cancel()
        refreshTask?.cancel()
    }

    func start() {
        guard connectTask == nil else { return }
        beginConnection()
    }

    private func beginConnection() {
        connectTask?.cancel()
        connectTask = Task { [weak self] in
            await self?.connectLoop()
        }
    }

    private func restartConnection() {
        streamTask?.cancel()
        historyTask?.cancel()
        syncTask?.cancel()
        syncStatusTask?.cancel()
        refreshTask?.cancel()
        connectTask?.cancel()
        streamTask = nil
        historyTask = nil
        syncTask = nil
        syncStatusTask = nil
        refreshTask = nil
        connectTask = nil
        client = nil
        isSyncingHistory = false
        connection = .waiting
        beginConnection()
    }

    func stop() {
        streamTask?.cancel()
        historyTask?.cancel()
        syncTask?.cancel()
        syncStatusTask?.cancel()
        connectTask?.cancel()
        refreshTask?.cancel()
    }

    var selectedSession: SessionSummary? {
        guard let selectedSessionID else { return nil }
        return sessions.first(where: { $0.id == selectedSessionID })
    }

    var selectedTitle: String {
        selectedSession?.displayTitle ?? "选择会话"
    }

    /// Sessions shown in the top-left switcher. Only the current workspace is
    /// listed so workspace rows (AI-Work, Documents, default-workspace) do not
    /// masquerade as conversations. Background subagent sessions are hidden.
    var workspaceSessions: [SessionSummary] {
        let path = selectedWorkspace?.path
        return sessions.filter { session in
            if let path, session.cwd != path { return false }
            if archivedSessionIDs.contains(session.id) { return false }
            if session.blank && session.id != selectedSessionID { return false }
            let title = session.displayTitle
            if title.hasPrefix("[dsh-mnemon:") { return false }
            if title.hasPrefix("AgentTeams automatic") { return false }
            if isPlaceholder(title) { return false }
            return true
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    var emptyHint: String {
        guard connection == .connected else { return "等待 DSH 启动…" }
        guard selectedSessionID != nil else { return "选一个会话，或新建会话" }
        if isLoadingHistory { return "正在载入历史…" }
        if selectedSession?.running == true {
            return "会话正在运行，完成后会显示最新回复"
        }
        return "这个会话最近没有可显示的消息"
    }

    var selectedWorkspace: WorkspaceSummary? {
        guard let cwd = selectedSession?.cwd?.trimmingCharacters(in: .whitespacesAndNewlines),
              isUsablePath(cwd) else { return nil }
        if let known = workspaces.first(where: { $0.path == cwd }) {
            return known
        }
        return WorkspaceSummary(
            id: "cwd:" + cwd,
            title: URL(fileURLWithPath: cwd).lastPathComponent,
            path: cwd
        )
    }

    var workspaceTitle: String {
        selectedWorkspace?.displayTitle ?? "选择工作区"
    }

    private func loadWorkspaces() {
        var byPath: [String: WorkspaceSummary] = [:]
        var ordered: [WorkspaceSummary] = []
        var archived: Set<String> = []
        if let data = try? Data(contentsOf: URL(fileURLWithPath: workspaceRegistryPath)),
           let registry = try? JSONDecoder().decode(WorkspaceRegistry.self, from: data) {
            archived = Set(registry.global?.archivedSessionIds ?? [])
            let defaultId = registry.global?.defaultWorkspaceId
            // DSH's ordered registry is authoritative. Fall back to the record
            // table only for older registries that predate workspaceIds.
            let orderedIDs = registry.global?.workspaceIds
                ?? registry.tables.workspaces.keys.sorted()
            for id in orderedIDs {
                guard let record = registry.tables.workspaces[id] else { continue }
                let path = record.path.trimmingCharacters(in: .whitespacesAndNewlines)
                guard isUsablePath(path), byPath[path] == nil else { continue }
                let rawTitle = (record.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let title: String
                if id == defaultId {
                    title = "默认工作区"
                } else if !rawTitle.isEmpty && !isPlaceholder(rawTitle) {
                    title = rawTitle
                } else {
                    title = URL(fileURLWithPath: path).lastPathComponent
                }
                let workspace = WorkspaceSummary(id: id, title: title, path: path)
                byPath[path] = workspace
                ordered.append(workspace)
            }
        }
        archivedSessionIDs = archived
        // Never synthesize a Workspace from a session cwd: DSH only lists
        // registry Workspaces, and removed/archived ones must stay hidden.
        // A current session in an unregistered cwd still gets a header title
        // through selectedWorkspace's fallback.
        workspaces = ordered.filter { workspace in
            !isPlaceholder(workspace.path) && !isPlaceholder(workspace.title)
        }
    }

    /// DSH has occasionally surfaced a literal "missing value" placeholder
    /// instead of a real cwd/title. Never turn that into a workspace row.
    private func isPlaceholder(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "missing value"
            || normalized == "null"
            || normalized == "(null)"
            || normalized == "undefined"
    }

    private func isUsablePath(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.hasPrefix("/") else { return false }
        if isPlaceholder(trimmed) { return false }
        return URL(fileURLWithPath: trimmed).lastPathComponent.lowercased() != "missing value"
    }

    func selectWorkspace(_ workspace: WorkspaceSummary) {
        guard workspaces.contains(where: { $0.path == workspace.path }) else { return }
        // 当前会话就在目标工作区时保持不动。
        if selectedSession?.cwd == workspace.path { return }
        let candidates = sessions.filter {
            $0.cwd == workspace.path && !archivedSessionIDs.contains($0.id)
        }
        guard !candidates.isEmpty else {
            createSession(cwd: workspace.path)
            return
        }
        // 回到工作区时优先留在当前会话；否则选最近的非空会话，避免落到空会话。
        let target = candidates.first(where: { $0.id == selectedSessionID })
            ?? candidates.filter { !$0.blank }.max(by: { $0.updatedAt < $1.updatedAt })
            ?? candidates.max(by: { $0.updatedAt < $1.updatedAt })
        if let target { selectSession(target.id) }
    }

    private func connectLoop() async {
        while !Task.isCancelled {
            if let info = Discovery.load() {
                let candidate = BridgeClient(info: info)
                do {
                    let listed = try await candidate.listSessions()
                    client = candidate
                    sessions = listed
                    loadWorkspaces()
                    connection = .connected
                    errorText = nil
                    if selectedSessionID == nil || !listed.contains(where: { $0.id == selectedSessionID }) {
                        selectedSessionID = listed.first?.id
                    }
                    if let id = selectedSessionID {
                        UserDefaults.standard.set(id, forKey: selectedKey)
                        isRunning = listed.first(where: { $0.id == id })?.running ?? false
                        startSession(id)
                    }
                    startRefresh()
                    return
                } catch {
                    connection = .offline
                }
            } else {
                connection = .waiting
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private func startRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if Task.isCancelled { return }
                await self?.refreshSessions()
            }
        }
    }

    func refreshSessions() async {
        guard let client else { return }
        do {
            let listed = try await client.listSessions()
            sessions = listed
            loadWorkspaces()
            connection = .connected
            if let selectedSessionID, let current = listed.first(where: { $0.id == selectedSessionID }) {
                isRunning = current.running
            }
        } catch {
            if Task.isCancelled { return }
            connection = .offline
            // A DSH restart invalidates the old port/token. Re-read discovery
            // instead of sitting on a dead client forever.
            restartConnection()
        }
    }

    func selectSession(_ id: String) {
        guard selectedSessionID != id else { return }
        if let current = selectedSessionID, fullHistoryLoaded.contains(current) {
            fullHistoryCache[current] = messages
        }
        selectedSessionID = id
        UserDefaults.standard.set(id, forKey: selectedKey)
        messages = []
        errorText = nil
        syncStatus = nil
        isSyncingHistory = false
        isLoadingHistory = true
        isRunning = sessions.first(where: { $0.id == id })?.running ?? false
        startSession(id)
    }

    /// Seed the transcript from /history, then attach the event stream so the
    /// conversation is visible immediately instead of waiting for a snapshot.
    private func startSession(_ id: String) {
        loadHistory(id)
        startStream(id)
    }

    private func loadHistory(_ id: String) {
        historyTask?.cancel()
        guard let client else { return }
        if let cached = fullHistoryCache[id] {
            applyHistory(cached)
            isLoadingHistory = false
            return
        }
        isLoadingHistory = true
        historyTask = Task { [weak self] in
            do {
                let page = try await client.history(sessionId: id, all: true)
                guard !Task.isCancelled, let self, self.selectedSessionID == id else { return }
                // Only a response that reached the oldest event is a complete
                // transcript. A 200-page guard stop still has hasMore=true and
                // must not be cached as "everything".
                if page.oldestSeq != nil && !page.hasMore {
                    self.storeFullHistory(page.messages, for: id)
                }
                self.applyHistory(page.messages)
                self.isLoadingHistory = false
                if page.hasMore {
                    self.setSyncStatus("已载入最近 \(page.messages.count) 条")
                }
            } catch {
                guard !Task.isCancelled, let self, self.selectedSessionID == id else { return }
                // A full import can hit the host's page guard or a timeout.
                // Fall back to the recent window instead of an empty widget.
                do {
                    let fallback = try await client.history(sessionId: id)
                    guard !Task.isCancelled, self.selectedSessionID == id else { return }
                    self.applyHistory(fallback.messages)
                    self.isLoadingHistory = false
                    self.errorText = "全量历史加载失败，已显示最近 \(fallback.messages.count) 条"
                    self.setSyncStatus("全量加载失败")
                } catch {
                    guard !Task.isCancelled, self.selectedSessionID == id else { return }
                    self.isLoadingHistory = false
                    if self.messages.isEmpty {
                        self.errorText = "历史加载失败：" + error.localizedDescription
                    }
                }
            }
        }
    }

    private func applyHistory(_ history: [ChatMessage]) {
        guard !history.isEmpty else { return }
        let known = Set(history.map(\.id))
        // Keep an in-flight optimistic user bubble or streaming reply that the
        // history endpoint does not know about yet. If history already carries
        // the final reply for the same turn/step, drop the streaming copy so
        // the transcript does not show it twice.
        let live = messages.filter { message in
            guard (message.pending || message.streaming), !known.contains(message.id) else { return false }
            if message.role == "assistant", message.turn != nil || message.step != nil {
                if history.contains(where: {
                    $0.role == "assistant" && $0.turn == message.turn && $0.step == message.step
                }) { return false }
            }
            return true
        }
        messages = deduplicated(history + live)
        scrollTick += 1
    }

    /// DSH can deliver the same assistant step twice: once from /history and
    /// once from the live stream, especially when a reconnect or a slow
    /// history request overlaps streaming. Keep one bubble per turn/step.
    /// Assistant messages without turn/step are left alone because they may be
    /// separate attempts.
    private func deduplicated(_ list: [ChatMessage]) -> [ChatMessage] {
        var result: [ChatMessage] = []
        var positions: [String: Int] = [:]
        for message in list {
            guard message.role == "assistant",
                  let turn = message.turn,
                  let step = message.step else {
                result.append(message)
                continue
            }
            let key = "\(turn)|\(step)"
            if let index = positions[key] {
                let existing = result[index]
                let shouldReplace = (existing.seq == nil && message.seq != nil)
                    || (existing.streaming && !message.streaming)
                if shouldReplace { result[index] = message }
                continue
            }
            positions[key] = result.count
            result.append(message)
        }
        return result
    }

    private func startStream(_ id: String) {
        streamTask?.cancel()
        guard let client else { return }
        autoSyncAfterReconnect = streamFailures > 0
        streamingID = nil
        streamTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    for try await event in client.stream(sessionId: id) {
                        if Task.isCancelled { return }
                        self?.handle(event)
                    }
                } catch {
                    if Task.isCancelled { return }
                    self?.streamFailures += 1
                    self?.setConnectionError(error)
                    if (self?.streamFailures ?? 0) >= 3 {
                        self?.restartConnection()
                        return
                    }
                }
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func setConnectionError(_ error: Error) {
        connection = .offline
        errorText = error.localizedDescription
    }

    private func handle(_ event: WidgetEvent) {
        switch event {
        case .snapshot(let snapshot, _):
            streamFailures = 0
            connection = .connected
            errorText = nil
            // The snapshot only covers the event window; never let it erase a
            // transcript already hydrated from /history.
            if messages.isEmpty {
                messages = deduplicated(snapshot)
                scrollTick += 1
            }
            streamingID = nil
            if autoSyncAfterReconnect {
                autoSyncAfterReconnect = false
                if !isLoadingHistory {
                    syncHistory()
                }
            }
        case .message(let message):
            merge(message)
        case .assistantStart(let turn, let step):
            let id = UUID().uuidString
            streamingID = id
            messages.append(ChatMessage(id: id, role: "assistant", text: "", turn: turn, step: step, streaming: true))
            cacheCurrentIfLoaded()
            scrollTick += 1
        case .assistantDelta(let text, let turn, let step):
            appendStreamText(text, turn: turn, step: step)
        case .assistantBlock(let text, let turn, let step):
            if let index = streamIndex(turn: turn, step: step), messages[index].text.isEmpty {
                messages[index].text = text
                scrollTick += 1
            }
        case .assistantEnd:
            if let streamingID, let index = messages.firstIndex(where: { $0.id == streamingID }) {
                messages[index].streaming = false
            }
            messages.removeAll { $0.role == "assistant" && $0.text.isEmpty }
            messages = deduplicated(messages)
            cacheCurrentIfLoaded()
            streamingID = nil
            isRunning = false
        case .serverError(let message):
            errorText = message
        }
    }

    private func merge(_ message: ChatMessage) {
        if message.role == "assistant" {
            let index: Int?
            if message.turn == nil && message.step == nil {
                // Some final messages lose their turn/step. Only collapse them
                // into the live streaming bubble; never into arbitrary history.
                index = messages.lastIndex(where: { $0.role == "assistant" && $0.streaming })
            } else {
                index = messages.firstIndex(where: {
                    $0.role == "assistant" && $0.turn == message.turn && $0.step == message.step
                })
            }
            if let index {
                messages[index].text = message.text
                messages[index].streaming = false
                messages[index].id = message.id
                messages[index].seq = message.seq
                messages[index].turn = message.turn
                messages[index].step = message.step
                messages = deduplicated(messages)
                streamingID = nil
                scrollTick += 1
                return
            }
        }
        if message.role == "user",
           let pendingIndex = messages.lastIndex(where: { $0.role == "user" && $0.pending && $0.text == message.text }) {
            messages[pendingIndex].pending = false
            messages[pendingIndex].id = message.id
            messages[pendingIndex].seq = message.seq
            scrollTick += 1
            return
        }
        if messages.contains(where: { $0.id == message.id && $0.role == message.role && $0.text == message.text }) {
            return
        }
        messages.append(message)
        messages = deduplicated(messages)
        cacheCurrentIfLoaded()
        scrollTick += 1
    }

    private func streamIndex(turn: Int?, step: Int?) -> Int? {
        if let streamingID, let index = messages.firstIndex(where: { $0.id == streamingID }) {
            return index
        }
        if turn == nil && step == nil {
            return messages.lastIndex(where: { $0.role == "assistant" && $0.streaming })
        }
        return messages.lastIndex(where: {
            $0.role == "assistant" && $0.turn == turn && $0.step == step
        })
    }

    private func appendStreamText(_ text: String, turn: Int?, step: Int?) {
        guard !text.isEmpty else { return }
        if let index = streamIndex(turn: turn, step: step) {
            messages[index].text += text
            messages[index].streaming = true
            cacheCurrentIfLoaded()
            scrollTick += 1
            return
        }
        let id = UUID().uuidString
        streamingID = id
        messages.append(ChatMessage(id: id, role: "assistant", text: text, turn: turn, step: step, streaming: true))
        cacheCurrentIfLoaded()
        scrollTick += 1
    }

    private var lastMessageSeq: Int? {
        messages.compactMap(\.seq).max()
    }

    /// Manual catch-up. The normal SSE stream already appends live messages;
    /// this button exists for gaps after a reconnect or a missed event. It asks
    /// only for messages newer than the newest sequence already on screen.
    func syncHistory() {
        guard let client,
              let id = selectedSessionID,
              !isSyncingHistory,
              !isLoadingHistory,
              connection == .connected else { return }
        let after = lastMessageSeq
        let full = after == nil
        isSyncingHistory = true
        syncStatus = nil
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            do {
                let page = try await client.history(sessionId: id, all: full, after: after)
                guard !Task.isCancelled, let self, self.selectedSessionID == id else { return }
                let added = self.mergeSynced(page.messages)
                if full && page.oldestSeq != nil && !page.hasMore {
                    self.storeFullHistory(self.messages, for: id)
                } else {
                    self.cacheCurrentIfLoaded()
                }
                self.isSyncingHistory = false
                self.setSyncStatus(added == 0 ? "已是最新" : "已同步 \(added) 条")
            } catch {
                guard !Task.isCancelled, let self, self.selectedSessionID == id else { return }
                self.isSyncingHistory = false
                self.setSyncStatus("同步失败")
                self.errorText = error.localizedDescription
            }
        }
    }

    @discardableResult
    private func mergeSynced(_ history: [ChatMessage]) -> Int {
        guard !history.isEmpty else { return 0 }
        let knownIDs = Set(messages.map(\.id))
        let knownSeq = Set(messages.compactMap(\.seq))
        let knownText = Set(messages.map { "\($0.role)|\($0.text)" })
        var additions: [ChatMessage] = []
        for message in history {
            if !message.id.isEmpty && knownIDs.contains(message.id) { continue }
            let key = "\(message.role)|\(message.text)"
            if let seq = message.seq {
                if knownSeq.contains(seq) { continue }
            } else if knownText.contains(key) {
                continue
            }
            additions.append(message)
        }
        guard !additions.isEmpty else { return 0 }
        messages.append(contentsOf: additions)
        messages = deduplicated(messages)
        cacheCurrentIfLoaded()
        scrollTick += 1
        return additions.count
    }

    private func storeFullHistory(_ history: [ChatMessage], for id: String) {
        fullHistoryCache[id] = history
        fullHistoryLoaded.insert(id)
        fullHistoryOrder.removeAll { $0 == id }
        fullHistoryOrder.append(id)
        while fullHistoryOrder.count > 3 {
            let evicted = fullHistoryOrder.removeFirst()
            fullHistoryCache.removeValue(forKey: evicted)
            fullHistoryLoaded.remove(evicted)
        }
    }

    private func cacheCurrentIfLoaded() {
        guard let id = selectedSessionID, fullHistoryLoaded.contains(id) else { return }
        fullHistoryCache[id] = messages
    }

    private func setSyncStatus(_ text: String) {
        syncStatus = text
        syncStatusTask?.cancel()
        syncStatusTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.syncStatus = nil
        }
    }

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let id = selectedSessionID, let client else { return }
        let pendingID = UUID().uuidString
        input = ""
        errorText = nil
        messages.append(ChatMessage(id: pendingID, role: "user", text: text, pending: true))
        cacheCurrentIfLoaded()
        scrollTick += 1
        isRunning = true
        Task {
            do {
                try await client.prompt(sessionId: id, text: text)
                await refreshSessions()
            } catch {
                isRunning = false
                // The bridge rejected the prompt or the request never reached
                // DSH; remove the optimistic bubble and restore the draft.
                messages.removeAll { $0.id == pendingID }
                if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    input = text
                }
                errorText = error.localizedDescription
                scrollTick += 1
            }
        }
    }

    func retry() {
        errorText = nil
        streamFailures = 0
        guard connection == .connected, let id = selectedSessionID else {
            restartConnection()
            return
        }
        startSession(id)
    }

    func cancel() {
        guard let id = selectedSessionID, let client else { return }
        Task {
            do {
                try await client.cancel(sessionId: id)
                isRunning = false
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    func newSession() {
        createSession(cwd: selectedWorkspace?.path ?? selectedSession?.cwd ?? defaultCwd)
    }

    private func createSession(cwd: String) {
        guard let client else { return }
        Task {
            do {
                let id = try await client.createSession(cwd: cwd)
                let listed = try await client.listSessions()
                sessions = listed
                loadWorkspaces()
                selectedSessionID = id
                UserDefaults.standard.set(id, forKey: selectedKey)
                messages = []
                isLoadingHistory = true
                startSession(id)
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}