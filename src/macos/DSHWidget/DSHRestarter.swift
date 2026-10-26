import Foundation
import AppKit
import Darwin

/// Restarts the DSH desktop host from inside the widget.
///
/// Measured on this machine: `kill -TERM` on the *main* Electron process makes it
/// exit after ~10s, and a cold start takes another ~10-15s before the bridge
/// answers again. The pid `/v1/health` reports is the Host **subprocess** — it is
/// a child of the main one, so killing it leaves the window up and the bridge
/// gone, which looks like a successful restart while nothing restarted.
enum DSHRestarter {
    static let appPath = "/Applications/DeepSeek Harness.app"
    private static let executable = appPath + "/Contents/MacOS/DeepSeek Harness"

    enum Failure: LocalizedError {
        case stillRunning(Int32)
        case launchFailed

        var errorDescription: String? {
            switch self {
            case .stillRunning: return "关不掉 DeepSeek Harness"
            case .launchFailed: return "没能重新打开 DeepSeek Harness"
            }
        }
    }

    static func isRunning() -> Bool { mainProcessPID() != nil }

    /// The Electron main process: parent is launchd (ppid 1) and its command line
    /// stops at the executable path. Helper processes carry arguments and the
    /// Host subprocess carries `--expose-internals`, so an exact match on the
    /// command column excludes both.
    static func mainProcessPID() -> Int32? {
        guard let output = run("/bin/ps", ["-Ao", "pid,ppid,command"]) else { return nil }
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, fields[1] == "1" else { continue }
            guard fields[2].trimmingCharacters(in: .whitespaces) == executable else { continue }
            return Int32(fields[0])
        }
        return nil
    }

    static func restart() async throws {
        WidgetLog.event("restart-start")
        // The whole sequence runs inside a launchd job. Measured 2026-10-26
        // 23:10:03: right after the app is SIGTERM'd, `open` from this process
        // returns 0 and is silently dropped (no LaunchServices record at all),
        // while the same `open` from a launchd job brings it back in ~1s.
        let label = "com.ryankiin.dshwidget.restart"
        let logPath = "/tmp/dsh-widget-restart.log"
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-widget-restart-\(UUID().uuidString).sh")
        let body = """
        #!/bin/bash
        exec >> "\(logPath)" 2>&1
        echo "$(date '+%H:%M:%S') restart start"
        EXE="\(executable)"
        main() { /bin/ps -Ao pid,command | /usr/bin/grep -F "$EXE" | /usr/bin/grep -v -- "--expose-internals" | /usr/bin/grep -v grep | /usr/bin/awk '{print $1}' | head -1; }
        P=$(main)
        echo "$(date '+%H:%M:%S') main=${P:-none}"
        if [ -n "$P" ]; then /bin/kill -TERM "$P"; fi
        for i in $(seq 1 60); do sleep 0.5; if [ -z "$(main)" ]; then break; fi; done
        echo "$(date '+%H:%M:%S') exited"
        sleep 2
        for r in 1 2 3; do
          /usr/bin/open -n -a "\(appPath)"
          echo "$(date '+%H:%M:%S') open exit=$? round=$r"
          for i in $(seq 1 40); do
            sleep 0.5
            N=$(main)
            if [ -n "$N" ]; then
              echo "$(date '+%H:%M:%S') recovered pid=$N round=$r"
              /bin/launchctl remove \(label)
              /bin/rm -f "$0"
              exit 0
            fi
          done
        done
        echo "$(date '+%H:%M:%S') FAILED after 3 rounds"
        /bin/launchctl remove \(label)
        /bin/rm -f "$0"
        """
        do {
            try body.write(to: script, atomically: true, encoding: .utf8)
        } catch {
            WidgetLog.event("restart-failed", "script")
            throw Failure.launchFailed
        }
        _ = run("/bin/launchctl", ["remove", label])
        guard run("/bin/launchctl", ["submit", "-l", label, "--", "/bin/bash", script.path]) != nil else {
            WidgetLog.event("restart-failed", "submit")
            throw Failure.launchFailed
        }
        WidgetLog.event("restart-submitted", "script=\(script.lastPathComponent)")
    }

    private static func run(_ tool: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
