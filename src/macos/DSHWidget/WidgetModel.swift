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
    /// Live status for the running turn: phase, clock, reasoning tail, steps.
    @Published var activity = ThinkingActivity()
    @Published var isLoadingHistory = false
    @Published var isSyncingHistory = false
    /// The host has more messages above the current window. A 500+ turn session
    /// is opened as its recent page and grows only when the reader asks.
    @Published var hasEarlier = false
    @Published var isLoadingEarlier = false
    @Published var syncStatus: String?

    var visibleMessages: [ChatMessage] {
        // An image-only user turn has no text, so attachments count as content.
        var result = messages.filter {
            !$0.text.isEmpty || $0.pending || !$0.attachments.isEmpty || !$0.localImages.isEmpty
        }
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
    /// Images pasted into the composer, waiting for the next send.
    @Published var composerImages: [ComposerImage] = []
    static let maxComposerImages = 6
    @Published var isRunning: Bool = false
    /// Sessions the event stream has seen start a turn. The list dot flips on
    /// this immediately instead of waiting for the next /v1/sessions poll.
    @Published private(set) var liveRunningIDs: Set<String> = []
    @Published var connection: Connection = .waiting
    @Published var errorText: String?
    /// A host restart owns the status line while it runs, so the widget never
    /// reports "DSH 未连接" for what is actually a deliberate ~15s restart.
    @Published var isRestarting = false
    @Published var restartError: String?
    @Published var scrollTick: Int = 0

    private var client: BridgeClient?
    private var streamTask: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var streamingID: String?
    /// Last moment a stream frame touched the transcript. Reconcile uses it so a
    /// one-second gap between two steps is not mistaken for a finished turn.
    private var lastStreamAt = Date.distantPast
    private var streamFailures = 0
    private var reconcileTask: Task<Void, Never>?
    private var isTailSyncing = false
    private var idleTicks = 0
    private var autoSyncAfterReconnect = false
    private var syncTask: Task<Void, Never>?
    private var syncStatusTask: Task<Void, Never>?
    /// Recent-window cache per session so switching back is instant.
    /// The cache is deliberately small; recent sessions are the common case.
    private struct CachedTranscript {
        var messages: [ChatMessage]
        var hasEarlier: Bool
        var earliestSeq: Int?
    }
    private var fullHistoryCache: [String: CachedTranscript] = [:]
    private var fullHistoryOrder: [String] = []
    /// Oldest sequence in the window on screen; the cursor for "load earlier".
    private var earliestSeq: Int?
    /// Bubbles pulled per page. Large enough to fill the visible panel, small
    /// enough that opening a 500+ turn session is not a full import.
    static let historyPageSize = 200
    private let selectedKey = "dshWidget.selectedSession"
    /// Test runs must not disturb the real app's remembered session.
    private let isTestRun = ProcessInfo.processInfo.environment["DSHWIDGET_TEST"] == "1"
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
        reconcileTask?.cancel()
    }

    func start() {
        guard connectTask == nil else { return }
        beginConnection()
    }

    /// Quit and relaunch the DSH app, then reconnect. The old process needs ~10s
    /// to exit and a cold start another ~10-15s, so "重启中…" stays up until the
    /// bridge actually answers — otherwise the panel shows "DSH 未连接" during a
    /// perfectly normal restart and reads as a failure.
    func restartHost() {
        guard !isRestarting else { return }
        isRestarting = true
        restartError = nil
        Task { [weak self] in
            guard let self else { return }
            // Let the phones know first: they can only see a healthy bridge
            // until the process actually dies, ~10s later.
            await self.client?.notifyHostRestarting()
            do {
                try await DSHRestarter.restart()
            } catch is CancellationError {
                self.isRestarting = false
                return
            } catch {
                self.restartError = error.localizedDescription
                self.isRestarting = false
                return
            }
            self.restartConnection()
            // Phase 1: wait for the host process to actually disappear. Without
            // this the first poll still sees `connection == .connected` (the app
            // has not received the SIGTERM yet) and reports success half a second
            // in, which reads as "flashed green, went dark, came back".
            var sawDown = false
            for _ in 0..<40 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if !DSHRestarter.isRunning() {
                    sawDown = true
                    break
                }
            }
            WidgetLog.event("restart-down", "sawDown=\(sawDown)")
            // Phase 2: the launchd job retries the launch itself, so this loop
            // only waits for the bridge to come back and records what happened.
            for _ in 0..<120 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if self.connection == .connected {
                    self.isRestarting = false
                    WidgetLog.event("restart-done")
                    return
                }
                if !DSHRestarter.isRunning() {
                    WidgetLog.event("restart-watchdog", "still-down")
                }
            }
            self.isRestarting = false
            self.restartError = "DSH 没连上，点电源再试一次"
        }
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
        reconcileTask?.cancel()
        connectTask?.cancel()
        streamTask = nil
        historyTask = nil
        syncTask = nil
        syncStatusTask = nil
        refreshTask = nil
        reconcileTask = nil
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
        reconcileTask?.cancel()
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
                    WidgetLog.event("connected", "sessions=\(listed.count)")
                    if selectedSessionID == nil || !listed.contains(where: { $0.id == selectedSessionID }) {
                        selectedSessionID = listed.first?.id
                    }
                    if let id = selectedSessionID {
                        saveSelection(id)
                        isRunning = listed.first(where: { $0.id == id })?.running ?? false
                        startSession(id)
                    }
                    startRefresh()
                    startReconcile()
                    return
                } catch {
                    WidgetLog.event("connect-failed", "error=\((error as NSError).code) base=\(candidate.baseURL.absoluteString) desc=\(error.localizedDescription)")
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
                let interval = self?.refreshInterval ?? 5_000_000_000
                try? await Task.sleep(nanoseconds: interval)
                if Task.isCancelled { return }
                await self?.refreshSessions()
            }
        }
    }

    /// 5s while everything idles, 2s while a session is running. A short turn
    /// can start and finish between two 10s polls, which made the dot miss it.
    private var refreshInterval: UInt64 {
        let busy = !liveRunningIDs.isEmpty || sessions.contains(where: { $0.running })
        return busy ? 2_000_000_000 : 5_000_000_000
    }

    /// Running state for the session list: the bridge flag plus anything the
    /// stream has seen start but not finish yet.
    func isLiveRunning(_ session: SessionSummary) -> Bool {
        session.running || liveRunningIDs.contains(session.id)
    }

    /// The event stream can die without `assistant_end` (idle timeout, sleep,
    /// bridge restart). Poll cheaply while something still looks busy: after two
    /// consecutive idle answers from /v1/sessions, settle the transcript and
    /// reconcile the tail from /history.
    private func startReconcile() {
        reconcileTask?.cancel()
        reconcileTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { return }
                await self?.reconcileIfBusy()
            }
        }
    }

    private var hasStreamingBubble: Bool {
        messages.contains { $0.role == "assistant" && $0.streaming }
    }

    private func reconcileIfBusy() async {
        guard connection == .connected,
              let client,
              let id = selectedSessionID else {
            idleTicks = 0
            return
        }
        // activity.isRunning belongs here too: a lost turnEnd left the spinner
        // animating while both flags above were already false, so the poll
        // stopped watching and the widget looked busy forever.
        guard isRunning || hasStreamingBubble || activity.isRunning else {
            // The first poll already turned isRunning off but a lost end frame
            // can leave a spinner behind; give it one more tick, then settle.
            if idleTicks > 0 {
                idleTicks += 1
                // Only fill in what the stream missed. Settling here is what
                // split a reply in two: the reply pauses between frames (long
                // reasoning, a tool call), DSH reports idle meanwhile, and the
                // settled bubble then sat next to the authoritative copy.
                if idleTicks >= 2 { finishBusyState(reason: "reconcile-idle") }
            }
            return
        }
        do {
            let listed = try await client.listSessions()
            sessions = listed
            loadWorkspaces()
            guard selectedSessionID == id else { return }
            if let current = listed.first(where: { $0.id == id }) {
                isRunning = current.running
            }
            guard !isRunning else {
                idleTicks = 0
                return
            }
            idleTicks += 1
            WidgetLog.event("reconcile", "idle=\(idleTicks) streaming=\(hasStreamingBubble) activity=\(activity.isRunning)")
            if idleTicks >= 2 {
                finishBusyState(reason: "reconcile-idle")
            }
        } catch {
            // refreshSessions owns the offline transition.
        }
    }

    /// The host reports the session idle, so the spinner must stop even when no
    /// end frame arrived, then pull whatever the event window missed.
    private func finishBusyState(reason: String) {
        if activity.isRunning {
            WidgetLog.event("activity-settle", "reason=\(reason) turn=\(activity.turn ?? -1) step=\(activity.step ?? -1)")
            withAnimation(.easeOut(duration: 0.45)) { activity.finish(at: Date()) }
        }
        silentSyncHistory(reason: reason)
    }

    /// A stream frame can finish a step whose start the widget never saw, so the
    /// live bubble keeps streaming=true. That flag then blocks every tail sync
    /// as if a reply were still in flight, and the spinner never settles. Clear
    /// it on every assistant bubble once the turn is known to be over.
    private func clearStreamingFlags() {
        var changed = false
        for index in messages.indices where messages[index].role == "assistant" && messages[index].streaming {
            messages[index].streaming = false
            changed = true
        }
        streamingID = nil
        if changed { cacheCurrentIfLoaded() }
    }

    /// Collapse the leftovers of an interrupted stream once the session is known
    /// to be idle, then pull whatever the event window missed.
    private func settleTranscript(reason: String) {
        // DSH reports idle for a beat between two steps. Settling then turns the
        // streaming bubble into a normal one and lets the tail sync append the
        // authoritative reply next to it, which reads as a second bubble.
        if hasStreamingBubble, Date().timeIntervalSince(lastStreamAt) < 2.5 {
            WidgetLog.event("settle-skip", "reason=\(reason) quiet=\(Int(Date().timeIntervalSince(lastStreamAt) * 1000))ms")
            return
        }
        if let id = selectedSessionID { liveRunningIDs.remove(id) }
        let before = messages.count
        let streamingBefore = hasStreamingBubble
        messages = Transcript.settling(messages)
        streamingID = nil
        idleTicks = 0
        activity.finish(at: Date())
        cacheCurrentIfLoaded()
        let lastLength = messages.last(where: { $0.role == "assistant" })?.text.count ?? 0
        WidgetLog.event(
            "settle",
            "reason=\(reason) before=\(before) after=\(messages.count) streaming=\(streamingBefore) last=\(lastLength)"
        )
        if messages.count != before { scrollTick += 1 }
        silentSyncHistory(reason: reason)
    }

    /// Fetch only messages newer than the newest sequence on screen, without
    /// touching the sync banner: this runs automatically after a reconnect.
    private func silentSyncHistory(reason: String) {
        // A streaming bubble is authoritative for its step: merging a history
        // copy into it mid-stream either duplicates the text (history first,
        // deltas after) or closes the bubble early. Wait until the stream ends.
        if hasStreamingBubble {
            // A bubble orphaned by a lost end frame used to block this forever:
            // every tail sync skipped, so the text never settled and the widget
            // stayed "thinking". Once the stream has been quiet long enough the
            // stale part is the flag, not the text.
            let quiet = Date().timeIntervalSince(lastStreamAt)
            if quiet < 3 {
                WidgetLog.event("tail-sync-skip", "reason=\(reason) streaming=true quiet=\(Int(quiet * 1000))ms")
                return
            }
            WidgetLog.event("tail-sync", "reason=\(reason) stale-streaming quiet=\(Int(quiet * 1000))ms")
            clearStreamingFlags()
        }
        guard let client,
              let id = selectedSessionID,
              connection == .connected,
              !isTailSyncing,
              !isLoadingHistory else { return }
        let after = lastMessageSeq
        isTailSyncing = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isTailSyncing = false }
            do {
                let page = try await client.history(sessionId: id, all: after == nil, after: after)
                guard !Task.isCancelled, self.selectedSessionID == id else { return }
                let result = Transcript.addingSynced(to: self.messages, history: page.messages)
                if result.added > 0 {
                    self.messages = result.messages
                    self.cacheCurrentIfLoaded()
                    self.scrollTick += 1
                }
                WidgetLog.event(
                    "tail-sync",
                    "reason=\(reason) fetched=\(page.messages.count) added=\(result.added)"
                )
            } catch {
                WidgetLog.event("tail-sync-failed", "reason=\(reason) error=\((error as NSError).code)")
            }
        }
    }

    private func saveSelection(_ id: String) {
        guard !isTestRun else { return }
        UserDefaults.standard.set(id, forKey: selectedKey)
    }

    /// Opens a pairing window through the live bridge connection. The ticket
    /// carries the QR payload; the overlay renders it and shows the fallback code.
    func startPairing() async throws -> PairingTicket {
        // First click can land before connectLoop finishes; a short wait beats
        // showing "invalid response" for something that is merely not ready.
        var client = self.client
        for _ in 0..<15 where client == nil {
            try? await Task.sleep(nanoseconds: 200_000_000)
            client = self.client
        }
        guard let client else {
            WidgetLog.event("pair-start", "client=nil after wait")
            throw BridgeError.invalidResponse
        }
        do {
            let ticket = try await client.startPairing()
            WidgetLog.event("pair-start", "ok=1 addrs=\(ticket.addrs.count)")
            return ticket
        } catch {
            WidgetLog.event("pair-start", "failed desc=\(error.localizedDescription)")
            throw error
        }
    }

    func refreshSessions() async {
        guard let client else { return }
        do {
            let listed = try await client.listSessions()
            sessions = listed
            loadWorkspaces()
            connection = .connected
            // Drop ids that no longer exist; live ids whose turn just ended are
            // cleared by assistantEnd or by settleTranscript.
            liveRunningIDs = liveRunningIDs.filter { id in listed.contains { $0.id == id } }
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
        cacheCurrentIfLoaded()
        selectedSessionID = id
        saveSelection(id)
        messages = []
        activity = ThinkingActivity()
        errorText = nil
        syncStatus = nil
        hasEarlier = false
        isLoadingEarlier = false
        earliestSeq = nil
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
            hasEarlier = cached.hasEarlier
            earliestSeq = cached.earliestSeq
            applyHistory(cached.messages)
            isLoadingHistory = false
            return
        }
        isLoadingHistory = true
        historyTask = Task { [weak self] in
            do {
                // One recent page, not the whole transcript. Importing 500+
                // bubbles up front is what made opening an old session crawl.
                let page = try await client.history(sessionId: id, limit: Self.historyPageSize)
                guard !Task.isCancelled, let self, self.selectedSessionID == id else { return }
                self.hasEarlier = page.hasMore && page.oldestSeq != nil
                self.earliestSeq = page.oldestSeq
                self.applyHistory(page.messages)
                self.isLoadingHistory = false
                if page.hasMore {
                    self.setSyncStatus("已载入最近 \(page.messages.count) 条")
                }
                WidgetLog.event(
                    "history",
                    "in=\(page.messages.count) hasMore=\(page.hasMore) oldest=\(page.oldestSeq ?? -1)"
                )
            } catch {
                guard !Task.isCancelled, let self, self.selectedSessionID == id else { return }
                self.isLoadingHistory = false
                if self.messages.isEmpty {
                    self.errorText = "历史加载失败：" + error.localizedDescription
                }
            }
        }
    }

    /// Fetch the page just above the current window. Paging keeps a 500+ turn
    /// session cheap to open: the transcript only grows while the reader keeps
    /// asking for what came before.
    func loadEarlier() {
        guard let client,
              let id = selectedSessionID,
              hasEarlier,
              !isLoadingEarlier,
              !isLoadingHistory,
              let before = earliestSeq else { return }
        isLoadingEarlier = true
        Task { [weak self] in
            do {
                let page = try await client.history(sessionId: id, limit: Self.historyPageSize, before: before)
                guard let self, self.selectedSessionID == id else { return }
                if let oldest = page.oldestSeq {
                    self.earliestSeq = oldest
                    self.hasEarlier = page.hasMore
                } else {
                    self.hasEarlier = false
                }
                let previous = self.messages.count
                let merged = Transcript.prepending(page.messages, to: self.messages)
                if merged.count != previous {
                    // Inserting above the viewport keeps the reader where they
                    // were, so no scroll nudge here.
                    self.messages = merged
                    self.cacheCurrentIfLoaded()
                }
                self.isLoadingEarlier = false
                WidgetLog.event(
                    "load-earlier",
                    "in=\(page.messages.count) added=\(self.messages.count - previous) total=\(self.messages.count) hasMore=\(page.hasMore)"
                )
            } catch {
                guard let self, self.selectedSessionID == id else { return }
                self.isLoadingEarlier = false
                self.errorText = "更早的消息加载失败：" + error.localizedDescription
            }
        }
    }

    private func applyHistory(_ history: [ChatMessage]) {
        guard !history.isEmpty else { return }
        let known = Set(history.map(\.id))
        let knownSteps = Set(history.compactMap { message -> String? in
            guard message.role == "assistant", let turn = message.turn, let step = message.step else { return nil }
            return "\(turn)|\(step)"
        })
        // Keep an in-flight optimistic user bubble or streaming reply that the
        // history endpoint does not know about yet. If history already carries
        // the final reply for the same turn/step, drop the streaming copy so
        // the transcript does not show it twice.
        let live = messages.filter { message in
            guard (message.pending || message.streaming), !known.contains(message.id) else { return false }
            if message.role == "assistant", let turn = message.turn, let step = message.step {
                return !knownSteps.contains("\(turn)|\(step)")
            }
            return true
        }
        messages = Transcript.deduped(history + live)
        scrollTick += 1
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
                    WidgetLog.event("stream-retry", "failures=\(self?.streamFailures ?? -1)")
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
        case .snapshot(let snapshot, let hasMore):
            streamFailures = 0
            connection = .connected
            errorText = nil
            // A reconnect snapshot is authoritative for the steps it carries.
            // Merging it (instead of only seeding an empty transcript) is what
            // restores a reply that finished while the stream was down.
            let merged = Transcript.mergingSnapshot(into: messages, snapshot: snapshot)
            if merged != messages {
                messages = merged
                cacheCurrentIfLoaded()
                scrollTick += 1
            }
            streamingID = nil
            WidgetLog.event(
                "snapshot",
                "in=\(snapshot.count) out=\(messages.count) hasMore=\(hasMore) running=\(isRunning)"
            )
            if !isRunning {
                // Nothing is in flight, so a lingering streaming bubble means the
                // end frame was lost. Settle and reconcile from /history.
                settleTranscript(reason: "snapshot")
            }
            if autoSyncAfterReconnect {
                autoSyncAfterReconnect = false
                if !isLoadingHistory {
                    syncHistory()
                }
            }
        case .message(let message):
            merge(message)
        case .assistantStart(let turn, let step):
            if let id = selectedSessionID { liveRunningIDs.insert(id) }
            let id = UUID().uuidString
            streamingID = id
            messages.append(ChatMessage(id: id, role: "assistant", text: "", turn: turn, step: step, streaming: true))
            WidgetLog.event("stream-start", "turn=\(turn ?? -1) step=\(step ?? -1) id=\(id.prefix(8))")
            activity.begin(turn: turn, step: step, at: Date())
            cacheCurrentIfLoaded()
            scrollTick += 1
        case .assistantDelta(let text, let turn, let step):
            activity.textStarted(step: step, at: Date())
            appendStreamText(text, turn: turn, step: step)
        case .reasoningDelta(let text, _, let step):
            activity.appendReasoning(text, step: step, at: Date())
            scrollTick += 1
        case .reasoningBlock(let text, _, let step):
            activity.setReasoning(text, step: step, at: Date())
            scrollTick += 1
        case .toolCall(let name, let detail, _, let step):
            activity.toolCall(name: name, detail: detail, at: Date())
            if let step { activity.step = step }
            scrollTick += 1
        case .toolResult(let ok, let text, _, _):
            activity.toolResult(ok: ok, text: text, at: Date())
            scrollTick += 1
        case .assistantBlock(let text, let turn, let step):
            let found = streamIndex(turn: turn, step: step)
            WidgetLog.event("stream-block", "turn=\(turn ?? -1) step=\(step ?? -1) found=\(found != nil) chars=\(text.count) existing=\(found.map { messages[$0].text.count } ?? -1)")
            if let index = found, messages[index].text.isEmpty {
                messages[index].text = text
                scrollTick += 1
            }
        case .assistantEnd:
            WidgetLog.event("stream-end", "count=\(messages.count) streaming=\(streamingID?.prefix(8) ?? "nil")")
            if let id = selectedSessionID { liveRunningIDs.remove(id) }
            clearStreamingFlags()
            messages.removeAll { $0.role == "assistant" && $0.text.isEmpty }
            messages = Transcript.deduped(messages)
            cacheCurrentIfLoaded()
        case .turnEnd:
            withAnimation(.easeOut(duration: 0.45)) { activity.finish(at: Date()) }
            clearStreamingFlags()
            idleTicks = 0
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
            let resolved = index ?? Transcript.similarAssistantIndex(message, in: messages)
            WidgetLog.event("merge-assistant", "turn=\(message.turn ?? -1) step=\(message.step ?? -1) found=\(index != nil) similar=\(resolved != nil) seq=\(message.seq ?? -1) chars=\(message.text.count)")
            if let index = resolved {
                if message.text.count >= messages[index].text.count {
                    messages[index].text = message.text
                }
                messages[index].streaming = false
                if !message.id.isEmpty { messages[index].id = message.id }
                if message.seq != nil { messages[index].seq = message.seq }
                if message.turn != nil { messages[index].turn = message.turn }
                if message.step != nil { messages[index].step = message.step }
                messages = Transcript.deduped(messages)
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
            messages[pendingIndex].text = message.text
            messages[pendingIndex].attachments = message.attachments
            // The echoed message now carries attachment ids; drop the local
            // previews so the shared attachment loader owns the pixels.
            messages[pendingIndex].localImages = []
            scrollTick += 1
            return
        }
        if messages.contains(where: { $0.id == message.id && $0.role == message.role && $0.text == message.text }) {
            return
        }
        messages.append(message)
        messages = Transcript.deduped(messages)
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
        lastStreamAt = Date()
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
                if full {
                    self.hasEarlier = page.hasMore && page.oldestSeq != nil
                    self.earliestSeq = page.oldestSeq
                }
                self.cacheCurrentIfLoaded()
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
        let result = Transcript.addingSynced(to: messages, history: history)
        guard result.added > 0 else { return 0 }
        messages = result.messages
        cacheCurrentIfLoaded()
        scrollTick += 1
        return result.added
    }

    /// Remember the window on screen for this session, paging state included.
    /// An empty transcript is not cached: it usually means the fetch has not
    /// landed yet, and caching it would show a blank panel on the next switch.
    private func cacheCurrentIfLoaded() {
        guard let id = selectedSessionID, !messages.isEmpty else { return }
        fullHistoryCache[id] = CachedTranscript(messages: messages, hasEarlier: hasEarlier, earliestSeq: earliestSeq)
        fullHistoryOrder.removeAll { $0 == id }
        fullHistoryOrder.append(id)
        while fullHistoryOrder.count > 3 {
            let evicted = fullHistoryOrder.removeFirst()
            fullHistoryCache.removeValue(forKey: evicted)
        }
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

    /// Encode pasted images and queue them as composer attachments.
    func addPastedImages(_ items: [(image: NSImage, name: String?)]) {
        guard !items.isEmpty else { return }
        let room = max(0, Self.maxComposerImages - composerImages.count)
        guard room > 0 else {
            errorText = "一条消息最多 \(Self.maxComposerImages) 张图片"
            return
        }
        var added: [ComposerImage] = []
        for (offset, item) in items.prefix(room).enumerated() {
            let fallback = "粘贴图片-\(composerImages.count + offset + 1)"
            guard let encoded = ComposerImageEncoder.make(from: item.image, name: item.name ?? fallback) else {
                continue
            }
            added.append(encoded)
        }
        guard !added.isEmpty else {
            errorText = "这张图片读不出来"
            return
        }
        errorText = nil
        composerImages.append(contentsOf: added)
    }

    func removeComposerImage(_ id: UUID) {
        composerImages.removeAll { $0.id == id }
    }

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = composerImages
        // An image alone is a valid turn.
        guard !text.isEmpty || !images.isEmpty, let id = selectedSessionID, let client else { return }
        let pendingID = UUID().uuidString
        input = ""
        composerImages = []
        errorText = nil
        let previews = images.compactMap { $0.thumbnail }
        messages.append(ChatMessage(
            id: pendingID,
            role: "user",
            text: text.isEmpty ? "" : text,
            pending: true,
            localImages: previews
        ))
        cacheCurrentIfLoaded()
        scrollTick += 1
        isRunning = true
        let payload = images.map {
            PromptImage(data: $0.data.base64EncodedString(), mediaType: $0.mediaType, name: $0.name)
        }
        Task {
            do {
                try await client.prompt(sessionId: id, text: text, images: payload)
                await refreshSessions()
            } catch {
                isRunning = false
                // The bridge rejected the prompt or the request never reached
                // DSH; remove the optimistic bubble and restore the draft.
                messages.removeAll { $0.id == pendingID }
                if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    input = text
                }
                if composerImages.isEmpty {
                    composerImages = images
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
                saveSelection(id)
                messages = []
                isLoadingHistory = true
                startSession(id)
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}