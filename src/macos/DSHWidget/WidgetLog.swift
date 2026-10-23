import Foundation

/// Append-only, size-capped event log for diagnosing reconnect behaviour.
/// Only event names, counters and timestamps are written — never message text.
enum WidgetLog {
    private static let queue = DispatchQueue(label: "com.ryankiin.dshwidget.event-log")
    private static let maxBytes = 256 * 1024
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static var path: URL {
        if let override = ProcessInfo.processInfo.environment["DSHWIDGET_EVENT_LOG"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh/widget-events.log")
    }

    static func event(_ name: String, _ detail: String = "") {
        if ProcessInfo.processInfo.environment["DSHWIDGET_EVENT_LOG"] == "off" { return }
        let stamp = formatter.string(from: Date())
        let line = stamp + " " + name + (detail.isEmpty ? "" : " " + detail) + "\n"
        queue.async {
            let url = path
            let manager = FileManager.default
            try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let data = line.data(using: .utf8) else { return }
            if let attributes = try? manager.attributesOfItem(atPath: url.path),
               let size = attributes[.size] as? Int,
               size > maxBytes {
                try? manager.removeItem(at: url)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
