import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Inserts text into the frontmost app by borrowing the clipboard: save it, put the text on it,
/// post ⌘V, then put the old contents back. All calls must happen on the main actor
/// (NSPasteboard / TIS / CGEvent posting).
@MainActor
enum TextInserter {
    enum InsertError: LocalizedError {
        case accessibilityNotGranted
        case pasteEventFailed

        var errorDescription: String? {
            switch self {
            case .accessibilityNotGranted:
                return "Copied to clipboard — grant Accessibility to auto-paste"
            case .pasteEventFailed:
                return "Copied to clipboard — couldn't send ⌘V"
            }
        }
    }

    /// How long the pasted text must stay on the clipboard so the target app can read it.
    private static let restoreDelay: Duration = .milliseconds(500)
    /// Pasteboard type that well-behaved clipboard managers use to skip an entry.
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    private struct SavedItem {
        let entries: [(type: NSPasteboard.PasteboardType, data: Data)]
    }

    private struct PendingRestore {
        let items: [SavedItem]
        let changeCount: Int
        let task: Task<Void, Never>
    }

    private static var pending: PendingRestore?

    /// UserDefaults key: leave the transcript on the clipboard after pasting instead of restoring
    /// the previous contents.
    static let keepOnClipboardKey = "keepTranscriptOnClipboard"

    /// Puts `text` on the clipboard as a regular (non-transient) entry.
    static func copy(_ text: String) {
        flushPendingRestore()
        write(text, to: NSPasteboard.general, transient: false)
    }

    /// Pastes `text` into the focused app. If Accessibility isn't granted the text is left on the
    /// clipboard and `InsertError.accessibilityNotGranted` is thrown. With `keepOnClipboard` the
    /// transcript stays on the clipboard afterwards instead of the previous contents coming back.
    static func insert(_ text: String, keepOnClipboard: Bool = false) async throws {
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general

        // A previous insertion may still be waiting to restore the user's clipboard. Do that now so
        // we don't snapshot our own transcript as if it were the user's data.
        flushPendingRestore()

        guard Permissions.accessibilityGranted else {
            write(text, to: pasteboard, transient: false)
            throw InsertError.accessibilityNotGranted
        }

        // If the user is still holding the hotkey's modifiers, ⌘V would arrive as e.g. ⌥⌘V.
        await waitForModifierRelease()

        let saved = keepOnClipboard ? [] : capture(pasteboard)
        let ourChangeCount = write(text, to: pasteboard, transient: !keepOnClipboard)

        guard postPaste() else {
            write(text, to: pasteboard, transient: false) // keep it available for a manual ⌘V
            throw InsertError.pasteEventFailed
        }
        if keepOnClipboard { return }

        let task = Task { @MainActor in
            try? await Task.sleep(for: restoreDelay)
            guard !Task.isCancelled else { return }
            flushPendingRestore()
        }
        pending = PendingRestore(items: saved, changeCount: ourChangeCount, task: task)
    }

    // MARK: Pasteboard

    /// Copies every representation of every item; the originals become invalid after `clearContents`.
    private static func capture(_ pasteboard: NSPasteboard) -> [SavedItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            SavedItem(entries: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
    }

    @discardableResult
    private static func write(_ text: String, to pasteboard: NSPasteboard, transient: Bool) -> Int {
        pasteboard.clearContents()
        if transient {
            pasteboard.declareTypes([.string, transientType], owner: nil)
            pasteboard.setData(Data(), forType: transientType)
        }
        pasteboard.setString(text, forType: .string)
        return pasteboard.changeCount
    }

    private static func flushPendingRestore() {
        guard let pending else { return }
        self.pending = nil
        pending.task.cancel()

        let pasteboard = NSPasteboard.general
        // Someone (the user, another app) changed the clipboard since we wrote ours: leave it alone.
        guard pasteboard.changeCount == pending.changeCount else { return }

        pasteboard.clearContents()
        let items = pending.items.compactMap { saved -> NSPasteboardItem? in
            guard !saved.entries.isEmpty else { return nil }
            let item = NSPasteboardItem()
            for entry in saved.entries { item.setData(entry.data, forType: entry.type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }

    // MARK: Keystroke

    private static let blockingModifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]

    private static func waitForModifierRelease(timeout: Duration = .seconds(1)) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if flags.isDisjoint(with: blockingModifiers) { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func postPaste() -> Bool {
        guard
            let source = CGEventSource(stateID: .combinedSessionState),
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: pasteKeyCode(), keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: pasteKeyCode(), keyDown: false)
        else { return false }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    /// Virtual key code for 'v' (9 on ANSI/QWERTY). Looked up through the current ASCII-capable
    /// layout with ⌘ held, so Dvorak/Colemak users get ⌘V rather than ⌘K/⌘D. Falls back to 9.
    private static func pasteKeyCode() -> CGKeyCode {
        let fallback = CGKeyCode(kVK_ANSI_V)
        guard
            let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
            let rawLayoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return fallback }

        let layoutData = Unmanaged<CFData>.fromOpaque(rawLayoutData).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(layoutData) else { return fallback }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)

        for code in 0..<128 {
            var deadKeyState: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                layout,
                UInt16(code),
                UInt16(kUCKeyActionDown),
                UInt32((cmdKey >> 8) & 0xFF),
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                chars.count,
                &length,
                &chars
            )
            if status == noErr, length == 1, chars[0] == UniChar(UInt8(ascii: "v")) {
                return CGKeyCode(code)
            }
        }
        return fallback
    }
}
