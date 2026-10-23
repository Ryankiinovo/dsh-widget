import AppKit
import Foundation

// Unit tests for the pure transcript logic behind the reconnect fix.
// They only need Models.swift + Transcript.swift, no bridge and no window.
//
//   ./src/scripts/test-reconnect.sh --unit

var failures = 0

func check(_ condition: Bool, _ label: String) {
    if condition {
        print("ok   " + label)
    } else {
        failures += 1
        print("FAIL " + label)
    }
}

func assistant(_ id: String, _ text: String, seq: Int? = nil, turn: Int? = nil,
               step: Int? = nil, streaming: Bool = false) -> ChatMessage {
    ChatMessage(id: id, role: "assistant", text: text, seq: seq, turn: turn, step: step,
                streaming: streaming)
}

func user(_ id: String, _ text: String, seq: Int? = nil, pending: Bool = false) -> ChatMessage {
    ChatMessage(id: id, role: "user", text: text, seq: seq, pending: pending)
}

// 1. dedupe keeps exactly one bubble per turn/step and prefers the final copy.
do {
    let live = assistant("live", "hel", turn: 1, step: 1, streaming: true)
    let final = assistant("final", "hello", seq: 9, turn: 1, step: 1)
    let result = Transcript.deduped([live, final])
    check(result.count == 1, "deduped: one bubble per turn/step")
    check(result.first?.text == "hello" && result.first?.streaming == false,
          "deduped: the final copy wins")
}

// 2. THE BUG: a reply that finishes during a reconnect gap must reach the screen.
do {
    let existing = [
        user("u1", "hi", seq: 1),
        assistant("partial", "", turn: 1, step: 1, streaming: true)
    ]
    let snapshot = [
        user("u1", "hi", seq: 1),
        assistant("a1", "the full reply", seq: 2, turn: 1, step: 1)
    ]
    let merged = Transcript.mergingSnapshot(into: existing, snapshot: snapshot)
    check(merged.count == 2, "snapshot merge: no duplicate bubbles")
    let reply = merged.first { $0.role == "assistant" }
    check(reply?.text == "the full reply", "snapshot merge: finished reply replaces empty bubble")
    check(reply?.streaming == false, "snapshot merge: spinner flag cleared")
    check(merged.contains { $0.role == "user" && $0.text == "hi" }, "snapshot merge: user turn kept")
}

// 3. An empty transcript simply adopts the snapshot.
do {
    let snapshot = [user("u1", "hi", seq: 1), assistant("a1", "yo", seq: 2, turn: 1, step: 1)]
    let merged = Transcript.mergingSnapshot(into: [], snapshot: snapshot)
    check(merged.count == 2, "snapshot merge: cold start adopts snapshot")
}

// 4. The optimistic user bubble is confirmed instead of duplicated.
do {
    let existing = [user("local", "ping", pending: true)]
    let snapshot = [user("srv", "ping", seq: 4)]
    let merged = Transcript.mergingSnapshot(into: existing, snapshot: snapshot)
    check(merged.count == 1, "snapshot merge: pending user not duplicated")
    check(merged.first?.pending == false, "snapshot merge: pending flag cleared")
    check(merged.first?.seq == 4, "snapshot merge: sequence adopted")
}

// 5. Settling removes the orphaned spinner and its empty bubble.
do {
    let list = [
        user("u1", "hi", seq: 1),
        assistant("a1", "done", seq: 2, turn: 1, step: 1, streaming: true),
        assistant("ghost", "", turn: 2, step: 1, streaming: true)
    ]
    let settled = Transcript.settling(list)
    check(settled.count == 2, "settling: empty assistant bubble dropped")
    check(settled.last?.streaming == false, "settling: streaming flag cleared")
    check(settled.last?.text == "done", "settling: finished text kept")
}

// 6. Tail sync appends only what is missing and can also refresh a partial bubble.
do {
    let existing = [
        user("u1", "hi", seq: 1),
        assistant("partial", "", turn: 1, step: 1, streaming: true)
    ]
    let history = [
        user("u1", "hi", seq: 1),
        assistant("a1", "late reply", seq: 2, turn: 1, step: 1),
        user("u2", "next", seq: 3)
    ]
    let result = Transcript.addingSynced(to: existing, history: history)
    check(result.messages.count == 3, "tail sync: no duplicates")
    check(result.added == 2, "tail sync: counts the refreshed reply and the new turn")
    check(result.messages.contains { $0.id == "a1" && $0.text == "late reply" },
          "tail sync: missing reply restored")
}

// 7. Tail sync is a no-op when everything is already on screen.
do {
    let existing = [user("u1", "hi", seq: 1), assistant("a1", "yo", seq: 2, turn: 1, step: 1)]
    let result = Transcript.addingSynced(to: existing, history: existing)
    check(result.added == 0 && result.messages.count == 2, "tail sync: same transcript is a no-op")
}

// MARK: - Composer keyboard rules

check(ComposerKey.action(keyCode: 36, flags: [], isComposing: false) == .send,
      "composer: Return sends")
check(ComposerKey.action(keyCode: 76, flags: [], isComposing: false) == .send,
      "composer: keypad Enter sends")
check(ComposerKey.action(keyCode: 36, flags: [.shift], isComposing: false) == .passThrough,
      "composer: Shift+Return breaks the line")
check(ComposerKey.action(keyCode: 36, flags: [.option], isComposing: false) == .passThrough,
      "composer: Option+Return keeps native editing")
check(ComposerKey.action(keyCode: 36, flags: [.control], isComposing: false) == .passThrough,
      "composer: Control+Return keeps native editing")
check(ComposerKey.action(keyCode: 36, flags: [.command], isComposing: false) == .send,
      "composer: Command+Return still sends")
// Auto-follow: only keep the viewport at the bottom while the reader is there.
check(ScrollFollow.isAtBottom(floatValue: 1, overflows: true),
      "scroll: scroller at the bottom is pinned")
check(ScrollFollow.isAtBottom(floatValue: 0.999, overflows: true),
      "scroll: within scroller slack is pinned")
check(!ScrollFollow.isAtBottom(floatValue: 0.5, overflows: true),
      "scroll: mid list is not pinned")
check(ScrollFollow.isAtBottom(floatValue: 0, overflows: false),
      "scroll: short content counts as bottom")
check(!ScrollFollow.shouldFollow(userScrolledAway: true),
      "scroll: no auto-follow after scrolling up")
check(ScrollFollow.shouldFollow(userScrolledAway: false),
      "scroll: auto-follow at the bottom")
check(ScrollFollow.shouldShowJump(userScrolledAway: true, atBottom: false),
      "scroll: jump button shown when scrolled up")
check(!ScrollFollow.shouldShowJump(userScrolledAway: true, atBottom: true),
      "scroll: jump button hidden back at the bottom")
// Message photos: one row of thumbnails, nine slots at most.
check(MessageImageStripLayout.plan(count: 1) == (1, 0), "strip: one photo, no overflow")
check(MessageImageStripLayout.plan(count: 9) == (9, 0), "strip: nine photos fit the row")
check(MessageImageStripLayout.plan(count: 10) == (9, 1), "strip: ten photos show overflow +1")
check(MessageImageStripLayout.plan(count: 12) == (9, 3), "strip: twelve photos show overflow +3")
check(MessageImageStripLayout.plan(count: 0) == (0, 0), "strip: no photos, no row")
check(MessageImageStripLayout.stripWidth(count: 3) == 176, "strip: three thumbs measure 176pt")
// Drag and drop: only image files become attachments, everything else is left alone.
let droppedPhoto = URL(fileURLWithPath: "/tmp/shot.PNG")
let droppedJpeg = URL(fileURLWithPath: "/tmp/photo.jpeg")
let droppedDoc = URL(fileURLWithPath: "/tmp/report.pdf")
let droppedFolder = URL(fileURLWithPath: "/tmp/photos", isDirectory: true)
check(ComposerDrop.isImageFile(droppedPhoto), "drop: upper-case PNG counts as an image")
check(ComposerDrop.isImageFile(droppedJpeg), "drop: jpeg counts as an image")
check(!ComposerDrop.isImageFile(droppedDoc), "drop: pdf is left to AppKit")
check(!ComposerDrop.isImageFile(droppedFolder), "drop: folders are not images")
check(ComposerDrop.acceptedFileURLs([droppedPhoto, droppedDoc, droppedFolder, droppedJpeg])
        == [droppedPhoto, droppedJpeg],
      "drop: accepted files keep order and skip non-images")

// Thinking status line: tail trimming, tick counting, opacity ramp, lamp wave,
// phase clock reset and the elapsed label.
check(ThinkingActivity.tailLines(of: "a\nb\nc\nd\ne") == ["c", "d", "e"], "thinking: tail keeps the newest three lines")
check(ThinkingActivity.tailLines(of: "  \n\n只有一行\n  ") == ["只有一行"], "thinking: tail drops blanks")
check(ThinkingActivity.tailLines(of: "") == [], "thinking: empty reasoning draws no tail")
check(ThinkingActivity.tickCount(elapsed: 0) == 0, "thinking: zero elapsed draws no ticks")
check(ThinkingActivity.tickCount(elapsed: 9.4) == 94, "thinking: ticks count tenths of a second")
check(abs(ThinkingActivity.tickProgress(elapsed: 0.55, capacity: 120) - 5.5) < 0.001, "thinking: progress keeps the fractional tick")
check(ThinkingActivity.roundLines(of: "1\n2\n3\n4\n5\n6") == ["3", "4", "5", "6"], "thinking: a round keeps its newest four lines")
let longRound = (1...10).map { "line\($0)" }.joined(separator: "\n")
check(ThinkingActivity.roundLines(of: longRound, limit: ThinkingActivity.tailLinesLiveRound).count == 10, "thinking: the live round is never clipped")
check(ThinkingActivity.roundLines(of: longRound).count == 4, "thinking: a closed round folds to four lines")
check(ThinkingActivity.tickCount(elapsed: 12, capacity: 120) == 120, "thinking: a full strip stays full")
check(ThinkingActivity.tickProgress(elapsed: 500, capacity: 120) == 5000, "thinking: progress keeps flowing past the full strip")
check(abs(ThinkingActivity.tickOpacity(index: 0, count: 10) - 0.14) < 0.001, "thinking: oldest tick is dimmest")
check(abs(ThinkingActivity.tickOpacity(index: 9, count: 10) - 0.34) < 0.001, "thinking: newest tick is brightest")
check(abs(ThinkingActivity.tickOpacity(index: 0, count: 1) - 0.34) < 0.001, "thinking: single tick is drawn at full ramp")
let rangeEmpty = ThinkingActivity.visibleRange(progress: 0, capacity: 96)
check(rangeEmpty.first == 0 && rangeEmpty.last == 0, "thinking: empty strip has an empty range")
let rangePartial = ThinkingActivity.visibleRange(progress: 60, capacity: 96)
check(rangePartial.first == 0 && rangePartial.last == 60, "thinking: partial strip draws from the left edge")
let rangeFull = ThinkingActivity.visibleRange(progress: 300, capacity: 96)
check(rangeFull.first == 204 && rangeFull.last == 300 && rangeFull.last - rangeFull.first == 96, "thinking: a full strip keeps a 96-tick window (regression: reversed range crashed)")
let rangeHuge = ThinkingActivity.visibleRange(progress: 1e6, capacity: 96)
check(rangeHuge.last - rangeHuge.first == 96, "thinking: very long turns keep a fixed window")
check(ThinkingActivity.cycleProgress(50, capacity: 100) == 50, "thinking: a half strip keeps its progress")
check(ThinkingActivity.cycleProgress(100, capacity: 100) == 0, "thinking: a full strip restarts from zero")
check(ThinkingActivity.cycleProgress(305, capacity: 100) == 5, "thinking: extra progress wraps into the next row")
let rangeZero = ThinkingActivity.visibleRange(progress: 50, capacity: 0)
check(rangeZero.first == 0 && rangeZero.last == 0, "thinking: zero capacity stays empty")

let lampStart = Date(timeIntervalSinceReferenceDate: 0)
check(abs(ThinkingActivity.lampOpacity(at: lampStart) - 0.35) < 0.001, "thinking: lamp starts dim")
let halfPeriod = ThinkingActivity.lampPeriod / 2
check(ThinkingActivity.lampOpacity(at: lampStart.addingTimeInterval(halfPeriod)) > 0.99, "thinking: lamp peaks mid cycle")
check(abs(ThinkingActivity.tickPulse(at: lampStart) - 0.55) < 0.001, "thinking: tick pulse starts dim")
check(ThinkingActivity.tickPulse(at: lampStart.addingTimeInterval(0.25)) > 0.99, "thinking: tick pulse peaks mid cycle")
check(ThinkingActivity.elapsedLabel(12) == "12s", "thinking: elapsed under a minute")
check(ThinkingActivity.elapsedLabel(65) == "1m 05s", "thinking: elapsed over a minute")
check(ThinkingActivity.stepLabel(nil) == "", "thinking: no step label before a step")
check(ThinkingActivity.stepLabel(3) == "第 3 步", "thinking: step label")
check(ThinkingActivity.tickCapacity(forWidth: 0) == 0, "thinking: no width, no ticks")
check(ThinkingActivity.tickCapacity(forWidth: 16) == 4, "thinking: ticks fit the free width")

var act = ThinkingActivity()
let t0 = Date(timeIntervalSinceReferenceDate: 1000)
act.begin(step: 2, at: t0)
check(act.phase == .thinking && act.step == 2, "thinking: begin starts a thinking phase")
check(act.elapsedSeconds(at: t0.addingTimeInterval(7)) == 7, "thinking: clock counts from phase start")
act.appendReasoning("先确认数据来源", step: nil, at: t0.addingTimeInterval(2))
check(act.reasoning == "先确认数据来源", "thinking: reasoning feeds the tail")
act.toolCall(name: "run_code", at: t0.addingTimeInterval(5))
check(act.phase == .tool && act.toolName == "run_code", "thinking: tool call switches to blue phase")
check(act.elapsedSeconds(at: t0.addingTimeInterval(8)) == 3, "thinking: phase switch resets the clock")
check(act.steps.count == 2 && abs(act.steps[0].duration - 5) < 0.001,
      "thinking: switching closes the reasoning step")
check(act.steps[0].detail == "先确认数据来源", "thinking: closed reasoning step keeps its newest line")
check(act.toolTraceEntries.last?.detail == "", "thinking: a call without a summary keeps an empty detail")
check(act.toolTraceEntries.last?.isRunning == true, "thinking: the live call is marked running")
act.toolCall(name: "run_code", detail: "查工具事件的字段传递", at: t0.addingTimeInterval(6))
check(act.toolTraceEntries.last?.detail == "查工具事件的字段传递", "thinking: calls carry the bridge summary")
check(act.activeToolStepID == act.toolTraceEntries.last?.id, "thinking: the running call is the active row")
for index in 0..<4 {
    act.toolCall(name: "grep", detail: "第 " + String(index) + " 次搜索", at: t0.addingTimeInterval(7 + Double(index)))
}
check(act.toolTraceEntries.count == 3, "thinking: the trace keeps the last three calls")
check(act.toolTraceEntries.last?.detail == "第 3 次搜索", "thinking: the newest call comes last")
act.toolResult(ok: true, text: " exit 0 ", at: t0.addingTimeInterval(9))
check(act.phase == .thinking, "thinking: tool result returns to thinking")
check(act.toolTraceEntries.last?.ok == true, "thinking: a call and its result share one row")
check(act.toolTraceEntries.last?.result == "exit 0", "thinking: the row carries the result line")
check(act.toolTraceEntries.last?.isRunning == false, "thinking: a finished call is not running")
check(act.steps.last?.detail == "exit 0", "thinking: result detail is trimmed")
act.textStarted(step: nil, at: t0.addingTimeInterval(10))
check(act.phase == .generating, "thinking: text deltas switch to generating")
check(act.elapsedSeconds(at: t0.addingTimeInterval(12)) == 2, "thinking: text phase resets the clock")
act.finish(at: t0.addingTimeInterval(12))
check(act.phase == .idle && act.settled, "thinking: finish hides the status row")
check(ThinkingActivity().isRunning == false, "thinking: idle means not running")


// A reasoning burst after a tool result opens its own step and its own clock.
var act2 = ThinkingActivity()
act2.begin(step: 1, at: t0)
act2.appendReasoning("第一段", step: nil, at: t0.addingTimeInterval(1))
act2.toolCall(name: "run_code", at: t0.addingTimeInterval(2))
act2.toolResult(ok: true, text: "ok", at: t0.addingTimeInterval(3))
act2.appendReasoning("第二段", step: nil, at: t0.addingTimeInterval(4))
check(act2.steps.count == 4, "thinking: reasoning after a tool result opens a new step")
check(act2.steps.last?.kind == .reasoning, "thinking: newest step is the open reasoning step")
act2.appendReasoning("继续", step: nil, at: t0.addingTimeInterval(7))
check(act2.elapsedSeconds(at: t0.addingTimeInterval(8)) == 4, "thinking: later deltas keep the same clock")
check(act2.rounds.count == 1 && act2.rounds[0].hasPrefix("第一段"), "thinking: a closed burst is archived for the tail")
check(act2.reasoning.hasPrefix("第二段"), "thinking: the live burst stays separate from the archive")

// Only the newest three bursts are kept, no matter how many steps run.
var act3 = ThinkingActivity()
act3.begin(step: 1, at: t0)
for index in 1...5 {
    act3.appendReasoning("段\(index)", step: nil, at: t0)
    act3.toolCall(name: "run_code", at: t0.addingTimeInterval(Double(index)))
    act3.toolResult(ok: true, text: "ok", at: t0.addingTimeInterval(Double(index)))
}
check(act3.rounds.count == ThinkingActivity.tailRounds, "thinking: stored rounds are capped")

// A committed reasoning block replaces (never doubles) whatever streamed in.
var act4 = ThinkingActivity()
act4.begin(step: 4, at: t0)
act4.appendReasoning("片段", step: 4, at: t0)
act4.setReasoning("完整一段\n第二行", step: 4, at: t0.addingTimeInterval(1))
check(act4.reasoning == "完整一段\n第二行", "thinking: committed reasoning replaces the streamed buffer")
check(act4.phase == .thinking, "thinking: a committed block keeps the current phase")
act4.setReasoning("   ", step: 4, at: t0)
check(act4.reasoning == "完整一段\n第二行", "thinking: blank committed reasoning is ignored")

// 同一个 turn 内换步，归档的思考要留下；换 turn 才清空。
var act5 = ThinkingActivity()
act5.begin(turn: 7, step: 1, at: t0)
act5.appendReasoning("第一步的思考", step: 1, at: t0.addingTimeInterval(1))
act5.finish(at: t0.addingTimeInterval(2))
act5.begin(turn: 7, step: 2, at: t0.addingTimeInterval(3))
check(act5.rounds.count == 1 && act5.rounds[0].hasPrefix("第一步"), "thinking: a new step in the same turn keeps the archived thought")
act5.appendReasoning("第二步的思考", step: 2, at: t0.addingTimeInterval(4))
act5.finish(at: t0.addingTimeInterval(5))
act5.begin(turn: 8, step: 1, at: t0.addingTimeInterval(6))
check(act5.rounds.isEmpty, "thinking: a new turn starts with an empty archive")

// 一条回复从 history 与流式各来一次时，不能拆成两个气泡。
let longReply = String(repeating: "同一个回答的正文内容，用于相似度判断。", count: 4)
let streamed = ChatMessage(id: "s1", role: "assistant", text: longReply + "多出来的半句", turn: 92, step: 6, streaming: false)
let replayed = ChatMessage(id: "s2", role: "assistant", text: longReply, turn: nil, step: nil, streaming: false)
check(Transcript.similarAssistantIndex(replayed, in: [streamed]) == 0, "transcript: a replayed reply matches the bubble already shown")
let otherReply = ChatMessage(id: "s3", role: "assistant", text: "完全不同的另一段回答，长度也差不多，但内容没有重叠，不应该被合并。", turn: nil, step: nil, streaming: false)
check(Transcript.similarAssistantIndex(otherReply, in: [streamed]) == nil, "transcript: unrelated replies stay separate")
let synced = Transcript.addingSynced(to: [streamed], history: [replayed])
check(synced.messages.count == 1, "transcript: tail-sync does not duplicate a similar reply")
let shortOne = ChatMessage(id: "s4", role: "assistant", text: "短句。", turn: nil, step: nil)
check(Transcript.similarAssistantIndex(shortOne, in: [
    ChatMessage(id: "s5", role: "assistant", text: "短句。", turn: 1, step: 1)
]) == nil, "transcript: very short replies are never collapsed on text alone")

// 晚接入的流式气泡只带回复尾部：尾部是完整正文的后缀，必须并回同一条。
let authoritative = assistant("t1", String(repeating: "这一段是回复正文的一部分。", count: 20), turn: 102, step: 8)
let tailOnly = assistant("t2", String(authoritative.text.suffix(90)))
check(Transcript.similarAssistantIndex(tailOnly, in: [authoritative]) == 0, "transcript: a suffix-only partial merges into the full reply")
let tailSynced = Transcript.addingSynced(to: [tailOnly], history: [authoritative])
check(tailSynced.messages.count == 1, "transcript: tail-sync folds a late tail into the full reply")
let leadingOnly = assistant("t3", String(authoritative.text.prefix(90)))
check(Transcript.similarAssistantIndex(leadingOnly, in: [authoritative]) == nil, "transcript: a leading fragment alone is not treated as the whole reply")

if failures == 0 {
    print("transcript tests passed")
    exit(0)
} else {
    print("transcript tests failed: " + String(failures))
    exit(1)
}