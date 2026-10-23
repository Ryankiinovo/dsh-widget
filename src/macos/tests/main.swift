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
check(ComposerKey.action(keyCode: 36, flags: [], isComposing: true) == .passThrough,
      "composer: marked text is never intercepted")
check(ComposerKey.action(keyCode: 49, flags: [], isComposing: false) == .passThrough,
      "composer: other keys pass through")

if failures == 0 {
    print("transcript tests passed")
    exit(0)
} else {
    print("transcript tests failed: " + String(failures))
    exit(1)
}
