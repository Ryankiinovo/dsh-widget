import AppKit

/// What a Return key press should do in the composer.
///
/// Kept as a pure rule so the keyboard contract can be unit-tested without a
/// window: Return sends, every modified Return (Shift for a line break, plus
/// Option/Control for their native editing behaviour) is left to AppKit, and
/// Return inside IME composition is never stolen from the input method.
enum ComposerKey {
    enum Action: Equatable {
        case send
        case passThrough
    }

    static func action(
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags,
        isComposing: Bool
    ) -> Action {
        guard keyCode == 36 || keyCode == 76, !isComposing else { return .passThrough }
        let modifiers = flags.intersection(.deviceIndependentFlagsMask)
        if !modifiers.isDisjoint(with: [.shift, .option, .control]) {
            return .passThrough
        }
        return .send
    }
}
