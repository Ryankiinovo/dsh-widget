import Foundation

/// Which activity the running turn is doing right now. The lamp colour and the
/// action label both come from here, and every phase switch restarts the clock.
enum ThinkingPhase: String, Equatable {
    case idle
    case thinking
    case tool
    case generating
    case waiting
    case error

    var label: String {
        switch self {
        case .idle: return ""
        case .thinking: return "思考中"
        case .tool: return "运行工具"
        case .generating: return "生成回答"
        case .waiting: return "等待你的回复"
        case .error: return "出错了"
        }
    }

}

/// One entry of the expanded "last three steps" timeline.
struct ThinkingStep: Identifiable, Equatable {
    enum Kind: Equatable {
        case reasoning
        case tool(String)
        case result(Bool)
    }

    var id = UUID()
    var kind: Kind
    var detail: String
    var startedAt: Date
    var duration: TimeInterval = 0

    var title: String {
        switch kind {
        case .reasoning: return "思考"
        case .tool(let name): return "运行 \(name)"
        case .result(let ok): return ok ? "完成" : "失败"
        }
    }

    /// "6s" / "1.2s", kept short so the title line never wraps.
    var durationLabel: String {
        if duration < 10 { return String(format: "%.1fs", duration) }
        return "\(Int(duration.rounded()))s"
    }
}

/// One tool call on the trace under the status row: the call, its one-line
/// argument summary, and the result it produced once it came back.
struct ToolTraceEntry: Identifiable, Equatable {
    var id: UUID
    var name: String
    var detail: String
    /// First line of the result text; nil while the call is still running.
    var result: String?
    /// Whether the call finished successfully; nil until a result arrives.
    var ok: Bool?
    var duration: TimeInterval = 0
    var isRunning: Bool = false

    var durationLabel: String {
        if duration < 10 { return String(format: "%.1fs", duration) }
        return "\(Int(duration.rounded()))s"
    }

    /// Result bodies are full tool output; one line is all the row needs.
    static func firstLine(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? trimmed
    }
}

/// Everything the status line, tail and timeline need for the live turn.
///
/// The struct is intentionally plain data plus pure helpers: the widget window
/// sits on the desktop all day, so the view is driven by a 1 s TimelineView and
/// never by per-delta animations.
struct ThinkingActivity: Equatable {
    var phase: ThinkingPhase = .idle
    var toolName: String = ""
    var step: Int?
    /// When the current phase began; resets on every phase switch.
    var phaseStartedAt: Date = .distantPast
    /// When the turn began; kept for the record, not displayed yet.
    var turnStartedAt: Date = .distantPast
    /// Raw reasoning text of the current burst; the view keeps its tail.
    var reasoning: String = ""
    /// Reasoning bursts already closed earlier in this turn (newest last). The
    /// tail shows the last few of them so a long step does not push the earlier
    /// thinking out of sight.
    var rounds: [String] = []
    var steps: [ThinkingStep] = []
    /// Turn id of the activity being shown; lets a new step in the same turn
    /// keep the archived thoughts instead of wiping them.
    var turn: Int?
    var settled: Bool = true

    static let lampPeriod: TimeInterval = 0.9
    static let lampMinOpacity: Double = 0.35
    static let tickWidth: CGFloat = 1.5
    static let tickHeight: CGFloat = 6
    static let tickGap: CGFloat = 2.5
    static let tickCap = 120
    /// Four ticks a second: the strip should visibly crawl while the model
    /// works, and a long turn is expected to wipe and restart several times.
    static let tickSeconds: TimeInterval = 0.1
    static let tickPulsePeriod: TimeInterval = 0.5
    static let tickOpacityMin: Double = 0.14
    static let tickOpacityMax: Double = 0.34
    /// Kept for the one-line summary on closed timeline steps.
    static let tailLines = 3
    /// How many closed reasoning bursts are archived. Two archived steps plus
    /// the live one is what "keep the last 3 steps" means on screen.
    static let tailRounds = 2
    /// Maximum lines shown per closed round: once the next step starts, the
    /// previous thought folds back to this height.
    static let tailLinesPerRound = 4
    /// The live round is not clipped at all — the tail grows downward while the
    /// model is thinking, so a long passage stays readable instead of showing
    /// only its last four lines.
    static let tailLinesLiveRound = 400

    var isRunning: Bool { phase != .idle }

    mutating func begin(turn: Int? = nil, step: Int?, at now: Date) {
        let sameTurn = turn != nil && turn == self.turn
        if let turn { self.turn = turn }
        if settled {
            // A settled activity usually means the turn ended, but the 3 s
            // reconciler also settles mid-turn when DSH briefly reports idle.
            // Keep the archived thoughts when the turn is unchanged so the tail
            // does not collapse back to one round on every step switch.
            if sameTurn {
                pushRoundIfNeeded()
            } else {
                rounds = []
                steps = []
                reasoning = ""
            }
            settled = false
            turnStartedAt = now
            phaseStartedAt = now
        } else {
            pushRoundIfNeeded()
        }
        if let step { self.step = step }
        phase = .thinking
        toolName = ""
        phaseStartedAt = now
        steps.append(ThinkingStep(kind: .reasoning, detail: "", startedAt: now))
    }

    /// Reasoning deltas keep the amber/green lamp on "thinking" and only feed the
    /// tail; arriving after a phase switch they also restart the clock.
    mutating func appendReasoning(_ delta: String, step: Int?, at now: Date) {
        guard !delta.isEmpty else { return }
        // A new reasoning burst after a tool result opens its own step; a burst
        // that is already open keeps the running one (and its clock).
        if settled || phase != .thinking || !hasOpenReasoningStep {
            begin(step: step, at: now)
        } else if let step {
            self.step = step
        }
        reasoning += delta
        // Only the tail is ever shown, so cap the buffer to keep memory flat on
        // long reasoning streams.
        if reasoning.count > 4000 {
            reasoning = String(reasoning.suffix(2000))
        }
    }

    /// Committed assistant messages carry the whole step's reasoning even when
    /// DSH pushes no reasoning frames to this subscriber. Replace the buffer
    /// instead of appending so a late block never doubles partial deltas.
    mutating func setReasoning(_ text: String, step: Int?, at now: Date) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if settled {
            begin(step: step, at: now)
        } else if let step {
            self.step = step
        }
        if !hasOpenReasoningStep {
            steps.append(ThinkingStep(kind: .reasoning, detail: "", startedAt: now))
        }
        reasoning = text.count > 4000 ? String(text.suffix(4000)) : text
    }

    mutating func textStarted(step: Int?, at now: Date) {
        if settled {
            begin(step: step, at: now)
        }
        if let step { self.step = step }
        if phase != .generating {
            phase = .generating
            toolName = ""
            phaseStartedAt = now
        }
    }

    mutating func toolCall(name: String, detail: String = "", at now: Date) {
        if settled {
            begin(step: step, at: now)
        }
        closeRunningStep(at: now)
        steps.append(ThinkingStep(kind: .tool(name), detail: detail, startedAt: now))
        phase = .tool
        toolName = name
        phaseStartedAt = now
    }

    mutating func toolResult(ok: Bool, text: String, at now: Date) {
        closeRunningStep(at: now)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        steps.append(ThinkingStep(kind: .result(ok), detail: trimmed, startedAt: now))
        // Three calls = six steps, plus the reasoning steps in between.
        if steps.count > 12 { steps.removeFirst(steps.count - 12) }
        phase = .thinking
        toolName = ""
        phaseStartedAt = now
    }

    mutating func finish(at now: Date) {
        closeRunningStep(at: now)
        phase = .idle
        toolName = ""
        settled = true
    }

    mutating func fail(at now: Date) {
        closeRunningStep(at: now)
        phase = .error
        phaseStartedAt = now
        settled = false
    }

    /// Last three tool calls, each with its own argument summary and result.
    /// The tail keeps the last three *steps*; the trace keeps the last three
    /// *calls*, which is the same idea at the granularity of a tool run: a call
    /// and its result are one row, never two.
    var toolTraceEntries: [ToolTraceEntry] {
        var entries: [ToolTraceEntry] = []
        for step in steps {
            switch step.kind {
            case .reasoning:
                continue
            case .tool(let name):
                entries.append(ToolTraceEntry(
                    id: step.id,
                    name: name,
                    detail: step.detail,
                    result: nil,
                    ok: nil,
                    duration: step.duration,
                    isRunning: step.duration == 0
                ))
            case .result(let ok):
                guard let last = entries.popLast() else { continue }
                entries.append(ToolTraceEntry(
                    id: last.id,
                    name: last.name,
                    detail: last.detail,
                    result: ToolTraceEntry.firstLine(step.detail),
                    ok: ok,
                    duration: last.duration,
                    isRunning: false
                ))
            }
        }
        return Array(entries.suffix(3))
    }

    /// The tool step that is running right now, if any.
    var activeToolStepID: UUID? {
        guard phase == .tool else { return nil }
        return steps.last { step in
            if case .tool = step.kind { return true }
            return false
        }?.id
    }

    /// Archives the burst that just ended into `rounds` (newest last, capped).
    private mutating func pushRoundIfNeeded() {
        let trimmed = reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
        reasoning = ""
        guard !trimmed.isEmpty else { return }
        rounds.append(trimmed)
        if rounds.count > ThinkingActivity.tailRounds {
            rounds.removeFirst(rounds.count - ThinkingActivity.tailRounds)
        }
    }

    private var hasOpenReasoningStep: Bool {
        guard let last = steps.last, last.duration == 0 else { return false }
        if case .reasoning = last.kind { return true }
        return false
    }

    private mutating func closeRunningStep(at now: Date) {
        guard let last = steps.last, last.duration == 0 else { return }
        steps[steps.count - 1].duration = max(0, now.timeIntervalSince(last.startedAt))
        // A reasoning step shows its newest line as the one-line summary.
        if case .reasoning = last.kind, last.detail.isEmpty {
            steps[steps.count - 1].detail = ThinkingActivity.tailLines(of: reasoning).last ?? ""
        }
    }

    func elapsedSeconds(at now: Date) -> Int {
        max(0, Int(elapsedInterval(at: now)))
    }

    /// Fractional elapsed time. The tick strip animates on this, so the bar
    /// keeps growing between whole seconds instead of jumping once per second.
    func elapsedInterval(at now: Date) -> TimeInterval {
        guard phaseStartedAt != .distantPast else { return 0 }
        return max(0, now.timeIntervalSince(phaseStartedAt))
    }

    // MARK: - Pure presentation helpers (unit tested)

    /// Splits reasoning into the trailing lines the tail shows: newest last,
    /// blanks dropped, long lines clipped by the view rather than here.
    static func tailLines(of text: String, limit: Int = ThinkingActivity.tailLines) -> [String] {
        let lines = text
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count > limit else { return lines }
        return Array(lines.suffix(limit))
    }

    /// Splits one archived round into the lines the tail shows for it.
    static func roundLines(of text: String, limit: Int = ThinkingActivity.tailLinesPerRound) -> [String] {
        tailLines(of: text, limit: limit)
    }

    /// One tick per tickSeconds of the current phase, capped so a forgotten
    /// window cannot grow an unbounded row.
    static func tickCount(elapsed: TimeInterval, capacity: Int = tickCap) -> Int {
        min(capacity, Int(floor(tickProgress(elapsed: elapsed, capacity: capacity))))
    }

    /// Continuous strip position measured in ticks, including the fractional
    /// tail the canvas draws while the newest tick is still growing. It keeps
    /// growing past the capacity: the canvas then scrolls the window left, so a
    /// long wait flows instead of freezing at "full" or snapping back to zero.
    static func tickProgress(elapsed: TimeInterval, capacity: Int) -> Double {
        guard capacity > 0, elapsed > 0 else { return 0 }
        return elapsed / tickSeconds
    }

    /// A small triangle wave (0.5 s) that makes the newest tick visibly pulse:
    /// the strip never sits still while the turn runs.
    static func tickPulse(at now: Date) -> Double {
        let phase = now.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: tickPulsePeriod) / tickPulsePeriod
        let triangle = phase <= 0.5 ? phase * 2 : (1 - phase) * 2
        return 0.55 + 0.45 * triangle
    }

    /// Older ticks are dimmer, newest are brightest: a glass strip, not a bar.
    /// Visible slice of the strip. The window slides once the strip is full, so
    /// `first` can be far past `capacity`; `last` is clamped to the window width
    /// so the range can never invert (a reversed Range traps Swift).
    static func visibleRange(progress: Double, capacity: Int) -> (first: Int, last: Int) {
        guard capacity > 0 else { return (0, 0) }
        let clamped = max(0, progress)
        let windowStart = max(0, clamped - Double(capacity))
        let first = Int(windowStart.rounded(.down))
        let last = max(first, min(Int(clamped), first + capacity))
        return (first, last)
    }

    /// Wrap the running progress into one strip: the bar fills to the right
    /// edge, then starts a fresh row from the left (result is in [0, capacity)).
    static func cycleProgress(_ progress: Double, capacity: Int) -> Double {
        guard capacity > 0, progress > 0 else { return 0 }
        return progress.truncatingRemainder(dividingBy: Double(capacity))
    }

    static func tickOpacity(index: Int, count: Int) -> Double {
        guard count > 1 else { return tickOpacityMax }
        let progress = Double(index) / Double(count - 1)
        return tickOpacityMin + (tickOpacityMax - tickOpacityMin) * progress
    }

    /// 0.9 s triangle wave between the dim and full lamp opacity.
    static func lampOpacity(at now: Date) -> Double {
        let phase = now.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: lampPeriod) / lampPeriod
        let triangle = phase <= 0.5 ? phase * 2 : (1 - phase) * 2
        return lampMinOpacity + (1 - lampMinOpacity) * triangle
    }

    /// How many ticks fit across the free width between the elapsed label and the
    /// step label, so the strip always anchors at the same place.
    static func tickCapacity(forWidth width: CGFloat) -> Int {
        guard width > 0 else { return 0 }
        let pitch = tickWidth + tickGap
        return max(0, min(tickCap, Int(floor((width + tickGap) / pitch))))
    }

    /// "12s" under a minute, "1m 05s" above it.
    static func elapsedLabel(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m " + String(format: "%02d", seconds % 60) + "s"
    }

    static func stepLabel(_ step: Int?) -> String {
        guard let step else { return "" }
        return "第 \(step) 步"
    }
}
