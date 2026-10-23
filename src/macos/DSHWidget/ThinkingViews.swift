import SwiftUI

extension ThinkingPhase {
    /// Green for thinking/generating, blue while a tool runs, amber for waiting
    /// or errors. There is deliberately no red: this is ambient feedback, not an
    /// alarm.
    var color: Color {
        switch self {
        case .tool:
            return Color(red: 0x6F / 255.0, green: 0xB6 / 255.0, blue: 0xFF / 255.0)
        case .waiting, .error:
            return Color(red: 0xF0 / 255.0, green: 0xC3 / 255.0, blue: 0x6D / 255.0)
        default:
            return Color(red: 0x5F / 255.0, green: 0xD6 / 255.0, blue: 0x8F / 255.0)
        }
    }
}

extension ThinkingStep {
    var glyphColor: Color {
        switch kind {
        case .reasoning: return ThinkingPhase.thinking.color
        case .tool: return ThinkingPhase.tool.color
        case .result(let ok): return ok ? ThinkingPhase.thinking.color : ThinkingPhase.waiting.color
        }
    }
}

/// The live status line, the reasoning tail under it and the optional expanded
/// timeline. Replaces the bare "思考中…" spinner: DSH can think for minutes, so
/// the widget always shows what is happening, how long, and the newest thought.
struct ThinkingStatusView: View {
    let activity: ThinkingActivity
    @StateObject private var expansion = ExpandState()
    @StateObject private var lamp = LampState()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 0.5)
            statusLine
            if expansion.open {
                timeline
            }
            // Once the answer starts streaming the reasoning is stale, and
            // showing it right under the bubble reads like a second reply
            // (user: "这里又分气泡了"), so the tail only lives in the thinking step.
            if activity.phase == .thinking {
                ThinkingTailView(rounds: activity.rounds, reasoning: activity.reasoning)
            }
            // While a tool runs there is no reasoning to show, but the row on
            // its own says nothing about what the call is doing: list the last
            // three tool/result steps underneath, like the code block headers in
            // the main DSH window.
            if activity.phase == .tool {
                ToolTraceView(entries: activity.toolTraceEntries)
            }
        }
        .onAppear { lamp.start() }
        .onChange(of: activity.phase) { _, _ in lamp.start() }
    }

    private var statusLine: some View {
        Button {
            expansion.open.toggle()
        } label: {
            TimelineView(.periodic(from: .now, by: 0.05)) { context in
                let now = context.date
                let seconds = activity.elapsedSeconds(at: now)
                let pulse = ThinkingActivity.tickPulse(at: now)
                HStack(spacing: 8) {
                    lampDot
                        .frame(width: 9, height: 9)
                    Text(actionLabel)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color(red: 0xE2 / 255.0, green: 0xEE / 255.0, blue: 0xFA / 255.0))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: 120, alignment: .leading)
                    Text("已用 " + ThinkingActivity.elapsedLabel(seconds))
                        .font(.system(size: 12.5))
                        .monospacedDigit()
                        .foregroundStyle(Color(red: 0x9F / 255.0, green: 0xC0 / 255.0, blue: 0xDA / 255.0))
                        .frame(width: 78, alignment: .trailing)
                    TickStripView(elapsed: activity.elapsedInterval(at: now), pulse: pulse)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(ThinkingActivity.stepLabel(activity.step))
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(Color(red: 0x8F / 255.0, green: 0xB0 / 255.0, blue: 0xCC / 255.0))
                        .frame(width: 60, alignment: .trailing)
                }
                .frame(height: 20)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(expansion.open ? "收起最近步骤" : "查看最近 3 步")
    }

    private var actionLabel: String {
        activity.phase == .tool && !activity.toolName.isEmpty
            ? "运行 " + activity.toolName
            : activity.phase.label
    }

    /// 9 pt dot breathing on a 0.9 s cycle. SwiftUI animates the opacity, so the
    /// row itself is not re-evaluated between second ticks.
    private var lampDot: some View {
        Circle()
            .fill(activity.phase.color)
            .opacity(lamp.on ? 1.0 : ThinkingActivity.lampMinOpacity)
            .shadow(color: activity.phase.color.opacity(0.45), radius: 3)
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(activity.steps.suffix(3))) { step in
                HStack(alignment: .top, spacing: 7) {
                    Circle()
                        .fill(step.glyphColor)
                        .frame(width: 5, height: 5)
                        .padding(.top, 5)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(step.title)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.secondary)
                            if step.duration > 0 {
                                Text(step.durationLabel)
                                    .font(.system(size: 10.5))
                                    .monospacedDigit()
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        if !step.detail.isEmpty {
                            Text(step.detail)
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            Text("最近 " + String(min(3, activity.steps.count)) + " 步 · 点一下收起")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

/// Tool-call rows under the status line: one block per call, the running one
/// highlighted. Same rule as the reasoning tail — keep the last three steps —
/// but a step here is a whole tool run, so its argument summary wraps instead
/// of being cut to one line.
struct ToolTraceView: View {
    let entries: [ToolTraceEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(dotColor(entry))
                            .frame(width: 5, height: 5)
                        Text(ToolTraceView.shortName(entry.name))
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Color(red: 0xCD / 255.0, green: 0xE3 / 255.0, blue: 0xF5 / 255.0))
                            .lineLimit(1)
                        if entry.isRunning {
                            Text("运行中")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(Color(red: 0x6F / 255.0, green: 0xB6 / 255.0, blue: 0xFF / 255.0))
                        }
                        Spacer(minLength: 6)
                        if entry.duration > 0 {
                            Text(entry.durationLabel)
                                .font(.system(size: 10.5))
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)
                        }
                    }
                    if let detail = ToolTraceView.flat(entry.detail) {
                        // The call that is running may wrap for as long as it
                        // needs; finished calls fold back to four lines.
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(Color(red: 0x8F / 255.0, green: 0xB0 / 255.0, blue: 0xCC / 255.0))
                            .lineLimit(entry.isRunning ? nil : 4)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 11)
                    }
                    if let result = ToolTraceView.firstLine(entry.result) {
                        Text(result)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .padding(.leading, 11)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dotColor(_ entry: ToolTraceEntry) -> Color {
        if entry.isRunning {
            return Color(red: 0x6F / 255.0, green: 0xB6 / 255.0, blue: 0xFF / 255.0)
        }
        if entry.ok == false {
            return Color(red: 0xF0 / 255.0, green: 0xC3 / 255.0, blue: 0x6D / 255.0)
        }
        return Color(red: 0x5F / 255.0, green: 0xD6 / 255.0, blue: 0x8F / 255.0)
    }

    /// Argument summaries arrive as one collapsed line; tabs would still widen
    /// the row, so flatten them and keep the rest for wrapping.
    static func flat(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.replacingOccurrences(of: "\t", with: " ")
    }

    static func firstLine(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? trimmed
    }

    /// The main DSH window labels a call by what it does (代码 / 搜索), not by
    /// the tool id; keep that habit so the row reads like a sentence.
    static func shortName(_ name: String) -> String {
        switch name {
        case "run_code": return "代码"
        case "bash", "shell": return "命令"
        case "grep", "rg": return "搜索"
        case "read": return "读取"
        case "write": return "写入"
        case "edit": return "编辑"
        case "ls": return "列目录"
        default: return name
        }
    }
}

/// Reasoning tail: the newest three lines, older lines dimmer, newest line
/// finished with a 2 pt cursor. Empty reasoning draws nothing at all.
struct ThinkingTailView: View {
    /// Closed reasoning bursts, newest last.
    let rounds: [String]
    /// The burst that is still streaming.
    let reasoning: String

    var body: some View {
        let archived = rounds
            .map { ThinkingActivity.roundLines(of: $0) }
            .filter { !$0.isEmpty }
        // The live round keeps every line: the tail is allowed to grow downward
        // until the step ends, then folds to tailLinesPerRound as it archives.
        let current = ThinkingActivity.roundLines(
            of: reasoning,
            limit: ThinkingActivity.tailLinesLiveRound
        )
        if !archived.isEmpty || !current.isEmpty {
            TimelineView(.periodic(from: .now, by: 0.15)) { context in
                let pulse = ThinkingActivity.lampOpacity(at: context.date)
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(Array(archived.enumerated()), id: \.offset) { _, lines in
                        roundView(lines, dim: true, lamp: 1)
                    }
                    if !current.isEmpty {
                        roundView(current, dim: false, lamp: pulse)
                    }
                }
            }
            .padding(.leading, 2)
            .padding(.trailing, 12)
        }
    }

    /// One kept thought. Closed steps get a steady green dot, the live one
    /// breathes, so "already thought about this" and "thinking right now" are
    /// readable without counting lines.
    private func roundView(_ lines: [String], dim: Bool, lamp: Double) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(ThinkingPhase.thinking.color)
                .frame(width: 7, height: 7)
                .opacity(lamp)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    if !dim && index == lines.count - 1 {
                        HStack(alignment: .bottom, spacing: 2) {
                            tailText(line)
                            Rectangle()
                                .fill(tailColor)
                                .frame(width: 2, height: 12)
                        }
                    } else {
                        tailText(line)
                            .opacity(dim ? 0.62 : 1)
                    }
                }
            }
        }
    }

    private var tailColor: Color {
        Color(red: 0xB9 / 255.0, green: 0xD3 / 255.0, blue: 0xE8 / 255.0)
    }

    private func tailText(_ line: String) -> some View {
        Text(line)
            .font(.system(size: 12.5))
            .lineSpacing(6.5)
            .foregroundStyle(tailColor)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

/// One 1.5×6 pt tick per second, 2.5 pt apart, older ticks dimmer. The strip is
/// capped to whatever fits, so it reads as elapsed time without ever promising a
/// finish line.
struct TickStripView: View {
    /// Fractional seconds since the current phase began. Drawn on a canvas so
    /// the newest tick can grow smoothly (60 fps-ish) instead of stepping once
    /// per whole second.
    let elapsed: TimeInterval
    /// 0.55...1.0 triangle wave applied to the newest tick only.
    var pulse: Double = 1

    var body: some View {
        GeometryReader { proxy in
            let capacity = max(1, ThinkingActivity.tickCapacity(forWidth: proxy.size.width))
            let progress = ThinkingActivity.tickProgress(elapsed: elapsed, capacity: capacity)
            // Run to the right edge, then start a fresh row from the left: the
            // strip reads as "another N seconds went by", not as a bar that
            // scrolls forever and never ends.
            let cycle = ThinkingActivity.cycleProgress(progress, capacity: capacity)
            Canvas { context, size in
                let pitch = ThinkingActivity.tickWidth + ThinkingActivity.tickGap
                let top = (size.height - ThinkingActivity.tickHeight) / 2
                let firstVisible = 0
                let lastVisible = min(capacity, Int(cycle))
                let visibleCount = max(1, lastVisible - firstVisible)
                for index in firstVisible..<lastVisible {
                    var level = ThinkingActivity.tickOpacity(index: index - firstVisible, count: visibleCount)
                    if index == lastVisible - 1 {
                        level = min(1, level * pulse)
                    }
                    let x = Double(index) * pitch
                    let rect = CGRect(
                        x: CGFloat(x),
                        y: top,
                        width: ThinkingActivity.tickWidth,
                        height: ThinkingActivity.tickHeight
                    )
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: 0.75),
                        with: .color(tickColor.opacity(level))
                    )
                }
                // partial tick, so the strip grows like a liquid, not a counter
                let fraction = cycle - Double(lastVisible)
                if fraction > 0.02 {
                    let x = Double(lastVisible) * pitch
                    let width = max(0.7, ThinkingActivity.tickWidth * CGFloat(fraction))
                    let rect = CGRect(
                        x: CGFloat(x),
                        y: top,
                        width: width,
                        height: ThinkingActivity.tickHeight
                    )
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: 0.75),
                        with: .color(tickColor.opacity(ThinkingActivity.tickOpacityMax * pulse))
                    )
                }
            }
        }
        .frame(height: 10)
        .clipped()
    }

    private var tickColor: Color {
        Color(red: 0xA9 / 255.0, green: 0xCB / 255.0, blue: 0xE3 / 255.0)
    }
}

/// ObservableObject stand-ins for @State, which the CommandLineTools SwiftUI SDK
/// cannot expand (SwiftUIMacros is unavailable there).
final class ExpandState: ObservableObject {
    @Published var open = false
}

final class LampState: ObservableObject {
    @Published var on = false

    func start() {
        on = false
        DispatchQueue.main.async {
            withAnimation(
                .easeInOut(duration: ThinkingActivity.lampPeriod / 2)
                    .repeatForever(autoreverses: true)
            ) {
                self.on = true
            }
        }
    }
}
