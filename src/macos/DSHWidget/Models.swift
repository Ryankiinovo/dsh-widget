import Foundation

struct DiscoveryInfo: Decodable {
    let port: Int
    let token: String
    let pid: Int?
}

struct SessionSummary: Identifiable, Decodable, Equatable {
    let id: String
    let title: String
    let cwd: String?
    let updatedAt: Double
    let running: Bool
    let blank: Bool
    let agentAvailable: Bool

    enum CodingKeys: String, CodingKey {
        case id, title, cwd, updatedAt, running, blank, agentAvailable
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(id.prefix(8)) : trimmed
    }

    var updatedLabel: String {
        guard updatedAt > 0 else { return "" }
        let date = Date(timeIntervalSince1970: updatedAt / 1000.0)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct ChatMessage: Identifiable, Decodable, Equatable {
    var id: String
    var role: String
    var text: String
    var seq: Int?
    var time: Double?
    var turn: Int?
    var step: Int?
    var streaming: Bool = false
    var pending: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, role, text, seq, time, turn, step
    }

    init(id: String, role: String, text: String, seq: Int? = nil, time: Double? = nil,
         turn: Int? = nil, step: Int? = nil, streaming: Bool = false, pending: Bool = false) {
        self.id = id
        self.role = role
        self.text = text
        self.seq = seq
        self.time = time
        self.turn = turn
        self.step = step
        self.streaming = streaming
        self.pending = pending
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        role = try container.decodeIfPresent(String.self, forKey: .role) ?? "assistant"
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        seq = try container.decodeIfPresent(Int.self, forKey: .seq)
        time = try container.decodeIfPresent(Double.self, forKey: .time)
        turn = try container.decodeIfPresent(Int.self, forKey: .turn)
        step = try container.decodeIfPresent(Int.self, forKey: .step)
        streaming = false
        pending = false
    }
}

struct WorkspaceSummary: Identifiable, Equatable {
    let id: String
    let title: String
    let path: String

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return URL(fileURLWithPath: path).lastPathComponent
    }
}

struct WorkspaceRegistry: Decodable {
    struct Global: Decodable {
        let defaultWorkspaceId: String?
        /// DSH's ordered Workspace registry. A Workspace missing from this list
        /// is not shown in the DSH sidebar (for example after removal).
        let workspaceIds: [String]?
        /// Registry-global archive set, shared by every Workspace.
        let archivedSessionIds: [String]?
    }

    struct Tables: Decodable {
        let workspaces: [String: Record]
    }

    struct Record: Decodable {
        let path: String
        let title: String?
        let updatedAt: String?
    }

    let global: Global?
    let tables: Tables
}

struct SessionsResponse: Decodable {
    let sessions: [SessionSummary]
}

struct HistoryResponse: Decodable {
    let messages: [ChatMessage]
    let hasMore: Bool
    /// Present on the new /history responses. A nil oldestSeq means the
    /// running bridge is too old to support all=1, so callers must not cache
    /// the response as a complete transcript.
    let oldestSeq: Int?
    let newestSeq: Int?
}

struct SnapshotPayload: Decodable {
    let messages: [ChatMessage]
    let hasMore: Bool
}

struct StreamStartPayload: Decodable {
    let turn: Int?
    let step: Int?
}

struct StreamTextPayload: Decodable {
    let text: String
    let turn: Int?
    let step: Int?
}

struct ErrorInfo: Decodable {
    let code: String
    let message: String
}

struct ErrorPayload: Decodable {
    let error: ErrorInfo
}

enum WidgetEvent {
    case snapshot([ChatMessage], Bool)
    case message(ChatMessage)
    case assistantStart(turn: Int?, step: Int?)
    case assistantDelta(text: String, turn: Int?, step: Int?)
    case assistantBlock(text: String, turn: Int?, step: Int?)
    case assistantEnd
    case serverError(String)
}

enum Discovery {
    /// Tests point `DSHWIDGET_DISCOVERY` at a throwaway discovery file so they
    /// never talk to the real bridge.
    static var path: URL {
        if let override = ProcessInfo.processInfo.environment["DSHWIDGET_DISCOVERY"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh/widget-bridge.json")
    }

    static func load() -> DiscoveryInfo? {
        guard let data = try? Data(contentsOf: path) else { return nil }
        guard let info = try? JSONDecoder().decode(DiscoveryInfo.self, from: data),
              info.port > 0, !info.token.isEmpty else { return nil }
        return info
    }
}