import AppKit
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

struct MessageAttachment: Decodable, Equatable, Identifiable {
    let attachmentId: String
    let mediaType: String?
    let bytes: Int?
    let width: Int?
    let height: Int?
    let name: String?

    var id: String { attachmentId }
}

struct ChatMessage: Identifiable, Decodable, Equatable {
    var id: String
    var role: String
    var text: String
    var attachments: [MessageAttachment] = []
    var seq: Int?
    var time: Double?
    var turn: Int?
    var step: Int?
    var streaming: Bool = false
    var pending: Bool = false
    /// Local previews for a message this app just sent; the echoed copy from
    /// DSH arrives with attachment ids instead.
    var localImages: [NSImage] = []

    enum CodingKeys: String, CodingKey {
        case id, role, text, attachments, seq, time, turn, step
    }

    init(id: String, role: String, text: String, attachments: [MessageAttachment] = [],
         seq: Int? = nil, time: Double? = nil,
         turn: Int? = nil, step: Int? = nil, streaming: Bool = false, pending: Bool = false,
         localImages: [NSImage] = []) {
        self.id = id
        self.role = role
        self.text = text
        self.attachments = attachments
        self.seq = seq
        self.time = time
        self.turn = turn
        self.step = step
        self.streaming = streaming
        self.pending = pending
        self.localImages = localImages
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        role = try container.decodeIfPresent(String.self, forKey: .role) ?? "assistant"
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        attachments = try container.decodeIfPresent([MessageAttachment].self, forKey: .attachments) ?? []
        seq = try container.decodeIfPresent(Int.self, forKey: .seq)
        time = try container.decodeIfPresent(Double.self, forKey: .time)
        turn = try container.decodeIfPresent(Int.self, forKey: .turn)
        step = try container.decodeIfPresent(Int.self, forKey: .step)
        streaming = false
        pending = false
        localImages = []
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

struct TurnEndPayload: Decodable {
    let turn: Int?
    let reason: String?
}

struct ToolCallPayload: Decodable {
    let name: String
    let callId: String?
    /// One-line summary of the arguments, built by the bridge: what the call
    /// is doing (a description for run_code, the command for bash, …).
    let detail: String?
    let turn: Int?
    let step: Int?
}

struct StreamToolResultPayload: Decodable {
    let ok: Bool?
    let text: String?
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
    case reasoningDelta(text: String, turn: Int?, step: Int?)
    case reasoningBlock(text: String, turn: Int?, step: Int?)
    case toolCall(name: String, detail: String, turn: Int?, step: Int?)
    case toolResult(ok: Bool, text: String, turn: Int?, step: Int?)
    case assistantEnd
    case turnEnd(turn: Int?, reason: String?)
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
/// One pairing window: what a phone scans (uri), what a person can type
/// instead (code), and every base URL this host answers on right now.
struct PairingTicket: Decodable, Equatable {
    let code: String
    let expiresAt: String
    let ttlMs: Int?
    let addrs: [String]
    let uri: String

    /// A phone leaves the LAN mid-story, so a ticket can carry more than one
    /// base URL; a blank list would mean the bridge is unreachable.
    var usableAddrs: [String] { addrs.filter { !$0.isEmpty } }

    var expiry: Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: expiresAt) ?? ISO8601DateFormatter().date(from: expiresAt)
    }
}
