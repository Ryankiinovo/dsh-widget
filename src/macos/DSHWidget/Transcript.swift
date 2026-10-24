import Foundation

/// Pure transcript algebra shared by the widget model and the unit tests.
/// Everything here is a function of the message arrays only, so it can be
/// exercised without a bridge, a window or a running DSH.
enum Transcript {
    /// How many trailing messages the text-similarity fallback scans. A full
    /// scan made folding one history page into a 500+ bubble transcript
    /// quadratic: every page compared each reply against every reply already
    /// on screen. Matching now goes through a one-pass index and only the
    /// replies that carry neither an id nor a seq ever reach the text pass.
    static let similarScanLimit = 80

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
        var matcher = Matcher(existing)
        for message in snapshot {
            if let index = matcher.match(message) {
                merge(message, at: index, in: &matcher.items)
                matcher.reindex(index)
            } else {
                matcher.append(message)
            }
        }
        return deduped(matcher.items)
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
        var matcher = Matcher(existing)
        var added = 0
        for message in history {
            if matcher.isKnown(message) { continue }
            if let index = matcher.match(message) {
                if merge(message, at: index, in: &matcher.items) { added += 1 }
                matcher.reindex(index)
                continue
            }
            matcher.append(message)
            added += 1
        }
        return (deduped(matcher.items), added)
    }

    /// Put an older page in front of the transcript on screen. The on-screen
    /// copy wins for anything already there: it may carry a newer reply for the
    /// same turn/step than the page that was just fetched.
    static func prepending(_ older: [ChatMessage], to existing: [ChatMessage]) -> [ChatMessage] {
        guard !existing.isEmpty else { return deduped(older) }
        guard !older.isEmpty else { return existing }
        let knownIDs = Set(existing.map(\.id))
        let knownSeq = Set(existing.compactMap(\.seq))
        let kept = older.filter { message in
            if !message.id.isEmpty && knownIDs.contains(message.id) { return false }
            if let seq = message.seq, knownSeq.contains(seq) { return false }
            return true
        }
        guard !kept.isEmpty else { return existing }
        return deduped(kept + existing)
    }

    /// Text-similarity fallback for one reply. Exposed for the unit tests and
    /// for callers that need to ask about a single bubble.
    static func similarAssistantIndex(_ message: ChatMessage, in list: [ChatMessage]) -> Int? {
        similarIndex(message, in: list)
    }

    /// One reply can reach the widget twice with no shared turn/step or id:
    /// /history and the live stream label the same step differently, and a
    /// reconnect can replay it. Fall back to text similarity so a single answer
    /// never splits into two bubbles with a duplicated paragraph.
    private static func similarIndex(_ message: ChatMessage, in list: [ChatMessage]) -> Int? {
        guard message.role == "assistant" else { return nil }
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 40 else { return nil }
        let floor = max(0, list.count - similarScanLimit)
        var index = list.count - 1
        while index >= floor {
            defer { index -= 1 }
            let candidate = list[index]
            guard candidate.role == "assistant" else { continue }
            let other = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard other.count >= 40 else { continue }
            if other == text { return index }
            let shorter = other.count <= text.count ? other : text
            let longer = other.count <= text.count ? text : other
            guard longer.contains(shorter) else { continue }
            if Double(shorter.count) / Double(longer.count) > 0.8 { return index }
            // A stream that attached late only carries the tail of the reply:
            // the partial bubble is a suffix of the authoritative text. Merge
            // those as well, otherwise the tail stays behind as a second
            // bubble after the full reply arrives from /history.
            if shorter.count >= 40 && longer.hasSuffix(shorter) { return index }
        }
        return nil
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

    /// One-pass index over a transcript. Built once per fold instead of
    /// scanning the whole array for every incoming message.
    private struct Matcher {
        var items: [ChatMessage]
        private var byID: [String: Int] = [:]
        private var bySeq: [String: Int] = [:]
        private var byStep: [String: Int] = [:]
        private var byPendingUser: [String: Int] = [:]
        private var byText: [String: Int] = [:]

        init(_ items: [ChatMessage]) {
            self.items = items
            for (index, message) in items.enumerated() { register(index, message) }
        }

        private static func idKey(_ message: ChatMessage) -> String? {
            message.id.isEmpty ? nil : message.role + "|" + message.id
        }

        private static func seqKey(_ message: ChatMessage) -> String? {
            message.seq.map { message.role + "|" + String($0) }
        }

        private static func stepKey(_ message: ChatMessage) -> String? {
            guard message.role == "assistant", let turn = message.turn, let step = message.step else { return nil }
            return String(turn) + "|" + String(step)
        }

        private static func textKey(_ message: ChatMessage) -> String? {
            guard message.seq == nil, !message.text.isEmpty else { return nil }
            return message.role + "|" + message.text
        }

        private mutating func register(_ index: Int, _ message: ChatMessage) {
            if let key = Self.idKey(message), byID[key] == nil { byID[key] = index }
            if let key = Self.seqKey(message), bySeq[key] == nil { bySeq[key] = index }
            if let key = Self.stepKey(message), byStep[key] == nil { byStep[key] = index }
            if let key = Self.textKey(message), byText[key] == nil { byText[key] = index }
            if message.role == "user", message.pending { byPendingUser[message.text] = index }
        }

        mutating func append(_ message: ChatMessage) {
            items.append(message)
            register(items.count - 1, message)
        }

        /// A merged bubble can gain an id/seq/turn/step; index the new keys too
        /// so a later page still folds into the same bubble.
        mutating func reindex(_ index: Int) {
            guard items.indices.contains(index) else { return }
            register(index, items[index])
        }

        func isKnown(_ message: ChatMessage) -> Bool {
            if let key = Self.idKey(message), byID[key] != nil { return true }
            if let key = Self.seqKey(message), bySeq[key] != nil { return true }
            if let key = Self.textKey(message), byText[key] != nil { return true }
            return false
        }

        func match(_ message: ChatMessage) -> Int? {
            if let key = Self.idKey(message), let index = byID[key] { return index }
            if let key = Self.seqKey(message), let index = bySeq[key] { return index }
            if let key = Self.stepKey(message), let index = byStep[key] { return index }
            if message.role == "user", let index = byPendingUser[message.text] { return index }
            if message.role == "assistant" {
                return Transcript.similarIndex(message, in: items)
            }
            return nil
        }
    }
}
