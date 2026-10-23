import CoreGraphics

/// Layout math for the message image strip.
///
/// Photos in a message render as a single row of small square thumbnails above
/// the text bubble (the same shape the composer uses), never as a stacked
/// gallery. Past nine photos the row stays at nine slots and the last slot turns
/// into a "+N" badge, so one message can hold any number of photos without
/// pushing the conversation viewport apart.
enum MessageImageStripLayout {
    static let maxVisible = 9
    static let thumbnail: CGFloat = 56
    static let spacing: CGFloat = 4
    static let cornerRadius: CGFloat = 7

    /// How many thumbnails the row draws and how many photos the last slot hides.
    static func plan(count: Int) -> (shown: Int, overflow: Int) {
        if count <= 0 { return (0, 0) }
        if count <= maxVisible { return (count, 0) }
        return (maxVisible, count - maxVisible)
    }

    /// Total width of the row for `count` photos, used by the unit tests.
    static func stripWidth(count: Int) -> CGFloat {
        let shown = CGFloat(plan(count: count).shown)
        guard shown > 0 else { return 0 }
        return shown * thumbnail + (shown - 1) * spacing
    }
}
