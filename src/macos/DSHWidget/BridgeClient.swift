import Foundation

enum BridgeError: LocalizedError {
    case badStatus(Int, String)
    case invalidResponse
    case invalidData(String)
    case rejected

    var errorDescription: String? {
        switch self {
        case .badStatus(let code, let message):
            return "DSH 返回 " + String(code) + "：" + message
        case .invalidResponse:
            return "DSH 返回了无效响应"
        case .invalidData(let message):
            return "无法解析 DSH 响应：" + message
        case .rejected:
            return "DSH 没有接受这条消息"
        }
    }
}

/// One pasted image, already encoded as canonical base64 for DSH's attachment
/// admission. The widget never writes attachment objects itself.
struct PromptImage {
    let data: String
    let mediaType: String
    let name: String
}

final class BridgeClient {
    let baseURL: URL
    let token: String
    private let session: URLSession

    init(info: DiscoveryInfo) {
        self.baseURL = URL(string: "http://127.0.0.1:" + String(info.port))!
        self.token = info.token
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
    }

    private func request(url: URL, method: String = "GET", json: [String: Any]? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: json)
        }
        return request
    }

    private func request(path: String, method: String = "GET", json: [String: Any]? = nil) -> URLRequest {
        request(url: baseURL.appendingPathComponent(path), method: method, json: json)
    }

    private func sessionURL(_ sessionId: String, _ tail: String) -> URL {
        baseURL
            .appendingPathComponent("v1/sessions")
            .appendingPathComponent(sessionId)
            .appendingPathComponent(tail)
    }

    private func perform<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BridgeError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP " + String(http.statusCode)
            throw BridgeError.badStatus(http.statusCode, message)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw BridgeError.invalidData(error.localizedDescription)
        }
    }

    /// Opens a 6-digit pairing window. The ticket also carries the QR payload,
    /// so a phone gets scheme, base URL and code from a single scan.
    /// Best effort: tell the bridge to drop every live stream so paired phones
    /// switch to "reconnecting" the moment the Mac side starts its restart,
    /// instead of staying green through the ~10s graceful shutdown.
    struct HostNotice: Decodable { let ok: Bool }
    func notifyHostRestarting() async {
        _ = try? await perform(request(path: "/v1/host/restarting", method: "POST", json: [:]), as: HostNotice.self)
    }

    func startPairing() async throws -> PairingTicket {
        try await perform(
            request(path: "v1/pair/start", method: "POST", json: ["label": "DSH 小组件"]),
            as: PairingTicket.self
        )
    }

    func listSessions() async throws -> [SessionSummary] {
        let response = try await perform(request(path: "v1/sessions"), as: SessionsResponse.self)
        return response.sessions
    }

    /// before asks for the page above the oldest message on screen; the host
    /// pages backwards by sequence, so a windowed transcript can grow on demand.
    func history(
        sessionId: String,
        limit: Int = 500,
        all: Bool = false,
        after: Int? = nil,
        before: Int? = nil
    ) async throws -> HistoryResponse {
        var components = URLComponents(url: sessionURL(sessionId, "history"), resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "limit", value: String(limit))]
        if let after {
            items.append(URLQueryItem(name: "after", value: String(after)))
        }
        if let before {
            items.append(URLQueryItem(name: "before", value: String(before)))
        }
        if all && after == nil && before == nil {
            items.append(URLQueryItem(name: "all", value: "1"))
        }
        components.queryItems = items
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        // A full import may walk dozens of backwards pages. Keep the request
        // deadline longer than the default so it does not abort mid-import.
        request.timeoutInterval = 120
        return try await perform(request, as: HistoryResponse.self)
    }

    func prompt(sessionId: String, text: String, images: [PromptImage] = []) async throws {
        struct Ack: Decodable { let accepted: Bool }
        var json: [String: Any] = ["text": text]
        if !images.isEmpty {
            json["images"] = images.map {
                ["data": $0.data, "mediaType": $0.mediaType, "name": $0.name]
            }
        }
        let ack = try await perform(
            request(url: sessionURL(sessionId, "prompt"), method: "POST", json: json),
            as: Ack.self
        )
        guard ack.accepted else { throw BridgeError.rejected }
    }

    func cancel(sessionId: String) async throws {
        struct Ack: Decodable { let cancelled: Bool }
        _ = try await perform(
            request(url: sessionURL(sessionId, "cancel"), method: "POST", json: [:]),
            as: Ack.self
        )
    }

    func createSession(cwd: String?) async throws -> String {
        struct Created: Decodable { let sessionId: String }
        var body: [String: Any] = [:]
        if let cwd, !cwd.isEmpty { body["cwd"] = cwd }
        let created = try await perform(
            request(path: "v1/sessions", method: "POST", json: body),
            as: Created.self
        )
        return created.sessionId
    }

    func stream(sessionId: String, limit: Int = 500) -> AsyncThrowingStream<WidgetEvent, Error> {
        AsyncThrowingStream { continuation in
            var components = URLComponents(
                url: sessionURL(sessionId, "events"),
                resolvingAgainstBaseURL: false
            )!
            components.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
            var request = URLRequest(url: components.url!)
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 3600
            let stream = SSEStream()
            stream.start(request: request, sessionId: sessionId, continuation: continuation)
            continuation.onTermination = { _ in
                stream.stop()
            }
        }
    }

    static func decode(event: String, data: String) -> WidgetEvent? {
        let decoder = JSONDecoder()
        guard let bytes = data.data(using: .utf8) else { return nil }
        switch event {
        case "snapshot":
            guard let payload = try? decoder.decode(SnapshotPayload.self, from: bytes) else { return nil }
            return .snapshot(payload.messages, payload.hasMore)
        case "message":
            guard let message = try? decoder.decode(ChatMessage.self, from: bytes) else { return nil }
            return .message(message)
        case "assistant_start":
            let payload = try? decoder.decode(StreamStartPayload.self, from: bytes)
            return .assistantStart(turn: payload?.turn, step: payload?.step)
        case "assistant_delta":
            guard let payload = try? decoder.decode(StreamTextPayload.self, from: bytes) else { return nil }
            return .assistantDelta(text: payload.text, turn: payload.turn, step: payload.step)
        case "assistant_block":
            guard let payload = try? decoder.decode(StreamTextPayload.self, from: bytes) else { return nil }
            return .assistantBlock(text: payload.text, turn: payload.turn, step: payload.step)
        case "reasoning_delta":
            guard let payload = try? decoder.decode(StreamTextPayload.self, from: bytes) else { return nil }
            return .reasoningDelta(text: payload.text, turn: payload.turn, step: payload.step)
        case "reasoning_block":
            guard let payload = try? decoder.decode(StreamTextPayload.self, from: bytes) else { return nil }
            return .reasoningBlock(text: payload.text, turn: payload.turn, step: payload.step)
        case "tool_call":
            guard let payload = try? decoder.decode(ToolCallPayload.self, from: bytes) else { return nil }
            return .toolCall(name: payload.name, detail: payload.detail ?? "", turn: payload.turn, step: payload.step)
        case "tool_result":
            let payload = try? decoder.decode(StreamToolResultPayload.self, from: bytes)
            return .toolResult(
                ok: payload?.ok ?? true,
                text: payload?.text ?? "",
                turn: payload?.turn,
                step: payload?.step
            )
        case "assistant_end":
            return .assistantEnd
        case "turn_end":
            let payload = try? decoder.decode(TurnEndPayload.self, from: bytes)
            return .turnEnd(turn: payload?.turn, reason: payload?.reason)
        case "error":
            let payload = try? decoder.decode(ErrorPayload.self, from: bytes)
            return .serverError(payload?.error.message ?? "DSH 流错误")
        default:
            return nil
        }
    }
}

private final class SSEStream: NSObject, URLSessionDataDelegate {
    private var continuation: AsyncThrowingStream<WidgetEvent, Error>.Continuation?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var buffer = Data()
    private var eventName = "message"
    private var dataLines: [String] = []
    private var finished = false
    private let stateLock = NSLock()
    private var lastActivity = Date()
    private var watchdog: DispatchSourceTimer?
    private var sessionId = "?"

    func start(
        request: URLRequest,
        sessionId: String,
        continuation: AsyncThrowingStream<WidgetEvent, Error>.Continuation
    ) {
        self.continuation = continuation
        self.sessionId = sessionId
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3600
        // The bridge heartbeats every 15s, so an hour-long resource timeout only
        // guarantees a hard disconnect every hour. Keep the resource limit long
        // and let the stall watchdog below decide when a stream is dead.
        config.timeoutIntervalForResource = 86400
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.dataTask(with: request)
        self.task = task
        WidgetLog.event("stream-open", "session=\(sessionId)")
        startWatchdog()
        task.resume()
    }

    func stop() {
        guard !finished else { return }
        finished = true
        teardown()
        continuation = nil
    }

    private func finish(_ error: Error? = nil) {
        guard !finished else { return }
        finished = true
        if let error {
            let code = (error as NSError).code
            WidgetLog.event("stream-end", "session=\(sessionId) error=\(code)")
            continuation?.finish(throwing: error)
        } else {
            WidgetLog.event("stream-end", "session=\(sessionId) reason=closed")
            continuation?.finish()
        }
        continuation = nil
        teardown()
    }

    private func teardown() {
        watchdog?.cancel()
        watchdog = nil
        task?.cancel()
        session?.invalidateAndCancel()
        task = nil
        session = nil
    }

    private func noteActivity() {
        stateLock.lock()
        lastActivity = Date()
        stateLock.unlock()
    }

    private func idleSeconds() -> TimeInterval {
        stateLock.lock()
        defer { stateLock.unlock() }
        return Date().timeIntervalSince(lastActivity)
    }

    /// URLSession only reports a dead connection when TCP gives up, which can
    /// take many minutes after sleep or a bridge restart. Treat 60s without a
    /// single byte (four missed heartbeats) as a dead stream so the model can
    /// reconnect and reconcile instead of showing a spinner forever.
    private var stallTimeout: TimeInterval {
        if let raw = ProcessInfo.processInfo.environment["DSHWIDGET_STALL_SECONDS"],
           let value = TimeInterval(raw), value > 0 {
            return value
        }
        return 60
    }

    private func startWatchdog() {
        noteActivity()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let idle = self.idleSeconds()
            guard idle > self.stallTimeout else { return }
            WidgetLog.event("stream-stall", "session=\(self.sessionId) idle=\(Int(idle))s")
            self.finish(nil)
        }
        timer.resume()
        watchdog = timer
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(BridgeError.invalidResponse)
            return
        }
        guard http.statusCode == 200 else {
            completionHandler(.cancel)
            let body = String(data: buffer, encoding: .utf8) ?? ""
            finish(BridgeError.badStatus(http.statusCode, body.isEmpty ? "SSE 请求失败" : body))
            return
        }
        noteActivity()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        noteActivity()
        buffer.append(data)
        processBuffer()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, (error as NSError).code != NSURLErrorCancelled {
            finish(error)
        } else {
            finish(nil)
        }
    }

    private func processBuffer() {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            let line = String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            handleLine(line)
        }
    }

    private func handleLine(_ line: String) {
        if line.isEmpty {
            dispatch()
            return
        }
        if line.hasPrefix(":") { return }
        if line.hasPrefix("event:") {
            eventName = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            return
        }
        if line.hasPrefix("data:") {
            dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
        }
    }

    private func dispatch() {
        guard !dataLines.isEmpty else {
            eventName = "message"
            return
        }
        let payload = dataLines.joined(separator: "\n")
        let name = eventName
        eventName = "message"
        dataLines = []
        if let event = BridgeClient.decode(event: name, data: payload) {
            continuation?.yield(event)
        }
    }
}