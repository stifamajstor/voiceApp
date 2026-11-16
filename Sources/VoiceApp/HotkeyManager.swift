import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let notePushToTalk = Self("notePushToTalk")
    static let noteToggle = Self("noteToggle")

    /// Hold to record, release to transcribe.
    ///
    /// Defaults are pre-populated only if the user has never set/cleared them (KeyboardShortcuts
    /// checks UserDefaults). ⌥Space and ⌥⇧Space are unassigned by macOS itself; if they collide with
    /// a launcher (Raycast/Alfred/ChatGPT use ⌥Space) the user can rebind them in Settings.
    static let pushToTalk = Self("pushToTalk", default: Shortcut(.space, modifiers: [.option]))

    /// Press once to start, press again to stop and transcribe.
    static let toggleToTalk = Self("toggleToTalk", default: Shortcut(.space, modifiers: [.option, .shift]))
}

/// Tracks whether a key is physically held so auto-repeat keyDowns can be discarded.
///
/// Carbon hot keys never repeat, but KeyboardShortcuts falls back to raw key events while a menu
/// is open, and those do repeat. A keyUp lost while the shortcut was being rebound would leave the
/// key "held" forever, so a keyDown that arrives long after the previous one is treated as a fresh
/// press (auto-repeat events follow each other within ~100 ms; the initial delay is at most ~0.9 s).
struct KeyPressFilter {
    private var isHeld = false
    private var lastEvent: TimeInterval = 0
    private let staleAfter: TimeInterval = 1.5

    /// Returns true if this keyDown is a genuine new press.
    mutating func registerDown(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        defer { lastEvent = now }
        if isHeld, now - lastEvent < staleAfter { return false }
        isHeld = true
        return true
    }

    mutating func registerUp() {
        isHeld = false
    }
}

/// Wires the two global shortcuts to plain callbacks. KeyboardShortcuts invokes its handlers on
/// the main thread (Carbon event handler), so everything here is main-actor isolated.
@MainActor
final class HotkeyManager {
    private var pushToTalkFilter = KeyPressFilter()
    private var toggleFilter = KeyPressFilter()
    private var notePushFilter = KeyPressFilter()
    private var noteToggleFilter = KeyPressFilter()
    private var registered = false

    /// Idempotent. Callbacks receive de-duplicated events (no key-repeat).
    func register(
        onPushToTalkDown: @escaping () -> Void,
        onPushToTalkUp: @escaping () -> Void,
        onToggle: @escaping () -> Void,
        onNoteDown: @escaping () -> Void,
        onNoteUp: @escaping () -> Void,
        onNoteToggle: @escaping () -> Void
    ) {
        guard !registered else { return }
        registered = true

        KeyboardShortcuts.onKeyDown(for: .notePushToTalk) { [weak self] in
            guard let self, self.notePushFilter.registerDown() else { return }
            onNoteDown()
        }
        KeyboardShortcuts.onKeyUp(for: .notePushToTalk) { [weak self] in
            self?.notePushFilter.registerUp()
            onNoteUp()
        }
        KeyboardShortcuts.onKeyDown(for: .noteToggle) { [weak self] in
            guard let self, self.noteToggleFilter.registerDown() else { return }
            onNoteToggle()
        }
        KeyboardShortcuts.onKeyUp(for: .noteToggle) { [weak self] in
            self?.noteToggleFilter.registerUp()
        }

        KeyboardShortcuts.onKeyDown(for: .pushToTalk) { [weak self] in
            guard let self, self.pushToTalkFilter.registerDown() else { return }
            onPushToTalkDown()
        }
        KeyboardShortcuts.onKeyUp(for: .pushToTalk) { [weak self] in
            self?.pushToTalkFilter.registerUp()
            onPushToTalkUp()
        }

        KeyboardShortcuts.onKeyDown(for: .toggleToTalk) { [weak self] in
            guard let self, self.toggleFilter.registerDown() else { return }
            onToggle()
        }
        KeyboardShortcuts.onKeyUp(for: .toggleToTalk) { [weak self] in
            self?.toggleFilter.registerUp()
        }
    }
}
