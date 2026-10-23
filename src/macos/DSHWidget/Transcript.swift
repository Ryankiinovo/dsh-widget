import Foundation

/// Pure transcript algebra shared by the widget model and the unit tests.
/// Everything here is a function of the message arrays only, so it can be
/// exercised without a bridge, a window or a running DSH.
enum Transcript {
    /// DSH can deliver the same assistant step twice: once from /history and
    /// once from the live stream, especially when a reconnect or a slow
    /// history request overlaps streaming. Keep one bubble per turn/step.
    /// Assistant messages without turn/step are left alone because they may be
    /// separate attempts.
    static func deduped(_ list: [ChatMessage]) -> [ChatMessage] {
        var result: [ChatMessage] = []
        var positions: [String: Int] = [:]
        for message in list {
            guard message.role == "assistant",
                  let turn = message.turn,
                  let step = message.step else {
                result.append(message)
                continue
            }
            let key = "\(turn)|\(step)"
            if let index = positions[key] {
                let existing = result[index]
                let shouldReplace = (existing.seq == nil && message.seq != nil)
                    || (existing.streaming && !message.streaming)
                if shouldReplace { result[index] = message }
                continue
            }
            positions[key] = result.count
            result.append(message)
        }
        return result
    }

    /// Fold a reconnect snapshot into the transcript already on screen.
    /// The snapshot is authoritative for the steps it carries, so it fills in a
    /// reply that finished while the stream was down instead of being dropped.
    static func mergingSnapshot(into existing: [ChatMessage], snapshot: [ChatMessage]) -> [ChatMessage] {
        guard !snapshot.isEmpty else { return existing }
        guard !existing.isEmpty else { return deduped(snapshot) }
        var result = existing
        for message in snapshot {
            if let index = matchIndex(for: message, in: result) {
                merge(message, at: index, in: &result)
            } else {
                result.append(message)
            }
        }
        return deduped(result)
    }

    /// Drop the leftovers of an interrupted stream: empty assistant bubbles and
    /// stale "still streaming" flags. Callers only use this once the session is
    /// known to be idle.
    static func settling(_ list: [ChatMessage]) -> [ChatMessage] {
        let cleaned = list.filter { message in
            guard message.role == "assistant" else { return true }
            if message.pending { return true }
            return !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let settled = cleaned.map { message -> ChatMessage in
            guard message.streaming else { return message }
            var copy = message
            copy.streaming = false
            return copy
        }
        return deduped(settled)
    }

    /// Append what /history knows and the transcript does not. Returns the new
    /// transcript plus how many bubbles were added or refreshed.
    static func addingSynced(to existing: [ChatMessage], history: [ChatMessage]) -> (messages: [ChatMessage], added: Int) {
        guard !history.isEmpty else { return (existing, 0) }
        var result = existing
        let knownIDs = Set(result.map(\.id))
        let knownSeq = Set(result.compactMap(\.seq))
        let knownText = Set(result.map { "\($0.role)|\($0.text)" })
        var added = 0
        for message in history {
            if !message.id.isEmpty && knownIDs.contains(message.id) { continue }
            if let seq = message.seq, knownSeq.contains(seq) { continue }
            if message.seq == nil && knownText.contains("\(message.role)|\(message.text)") { continue }
            if let index = matchIndex(for: message, in: result) {
                if merge(message, at: index, in: &result) { added += 1 }
                continue
            }
            result.append(message)
            added += 1
        }
        return (deduped(result), added)
    }

    private static func matchIndex(for message: ChatMessage, in list: [ChatMessage]) -> Int? {
        if !message.id.isEmpty,
           let index = list.firstIndex(where: { $0.role == message.role && $0.id == message.id }) {
            return index
        }
        if let seq = message.seq,
           let index = list.firstIndex(where: { $0.role == message.role && $0.seq == seq }) {
            return index
        }
        // A history reply carries turn/step while the streaming bubble it should
        // fold into may not (delta frames have neither), so fall through to text
        // similarity instead of giving up when the step lookup misses.
        if message.role == "assistant", message.turn != nil || message.step != nil {
            if let index = list.firstIndex(where: {
                $0.role == "assistant" && $0.turn == message.turn && $0.step == message.step
            }) { return index }
        }
        if message.role == "user" {
            return list.lastIndex(where: {
                $0.role == "user" && $0.pending && $0.text == message.text
            })
        }
        if message.role == "assistant" {
            return similarAssistantIndex(message, in: list)
        }
        return nil
    }

    /// One reply can reach the widget twice with no shared turn/step or id:
    /// /history and the live stream label the same step differently, and a
    /// reconnect can replay it. Fall back to text similarity so a single answer
    /// never splits into two bubbles with a duplicated paragraph.
    static func similarAssistantIndex(_ message: ChatMessage, in list: [ChatMessage]) -> Int? {
        guard message.role == "assistant" else { return nil }
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 40 else { return nil }
        return list.lastIndex { candidate in
            guard candidate.role == "assistant" else { return false }
            let other = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard other.count >= 40 else { return false }
            if other == text { return true }
            let shorter = other.count <= text.count ? other : text
            let longer = other.count <= text.count ? text : other
            guard longer.contains(shorter) else { return false }
            if Double(shorter.count) / Double(longer.count) > 0.8 { return true }
            // A stream that attached late only carries the tail of the reply:
            // the partial bubble is a suffix of the authoritative text. Merge
            // those as well, otherwise the tail stays behind as a second
            // bubble after the full reply arrives from /history.
            return shorter.count >= 40 && longer.hasSuffix(shorter)
        }
    }

    /// Merge one authoritative message into an existing bubble. Returns whether
    /// anything visible changed.
    @discardableResult
    private static func merge(_ message: ChatMessage, at index: Int, in list: inout [ChatMessage]) -> Bool {
        var changed = false
        let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && list[index].text != message.text {
            list[index].text = message.text
            changed = true
        }
        if list[index].streaming { list[index].streaming = false; changed = true }
        if list[index].pending { list[index].pending = false; changed = true }
        if !message.id.isEmpty && list[index].id != message.id { list[index].id = message.id }
        if let seq = message.seq, list[index].seq != seq { list[index].seq = seq }
        if let turn = message.turn, list[index].turn != turn { list[index].turn = turn }
        if let step = message.step, list[index].step != step { list[index].step = step }
        return changed
    }
}
