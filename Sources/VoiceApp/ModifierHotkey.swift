import AppKit

/// A single modifier key used on its own as a trigger (e.g. right ⌥). KeyboardShortcuts can't
/// record these because Carbon hot keys always need a non-modifier key.
enum ModifierKey: String, CaseIterable, Identifiable {
    case none
    case rightOption
    case leftOption
    case rightCommand
    case rightControl
    case rightShift
    case function

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .rightOption: return "Right ⌥ Option"
        case .leftOption: return "Left ⌥ Option"
        case .rightCommand: return "Right ⌘ Command"
        case .rightControl: return "Right ⌃ Control"
        case .rightShift: return "Right ⇧ Shift"
        case .function: return "fn / 🌐 Globe"
        }
    }

    /// Virtual key code reported in `flagsChanged` events.
    fileprivate var keyCode: UInt16? {
        switch self {
        case .none: return nil
        case .rightOption: return 61
        case .leftOption: return 58
        case .rightCommand: return 54
        case .rightControl: return 62
        case .rightShift: return 60
        case .function: return 63
        }
    }

    /// Device-dependent flag bit (IOKit `NX_DEVICE*KEYMASK`), so left and right keys are told apart.
    fileprivate var flagMask: UInt {
        switch self {
        case .none: return 0
        case .rightOption: return 0x40
        case .leftOption: return 0x20
        case .rightCommand: return 0x10
        case .rightControl: return 0x2000
        case .rightShift: return 0x04
        case .function: return NSEvent.ModifierFlags.function.rawValue
        }
    }

    enum Action: String {
        case pushToTalk, toggleToTalk

        var defaultsKey: String { "\(rawValue)ModifierKey" }
    }

    static func current(for action: Action) -> ModifierKey {
        UserDefaults.standard.string(forKey: action.defaultsKey).flatMap(ModifierKey.init) ?? .none
    }

    /// Right ⌥ for push-to-talk out of the box; the user can change it in Settings.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [Action.pushToTalk.defaultsKey: ModifierKey.rightOption.rawValue])
    }
}

/// Watches modifier-only triggers via NSEvent monitors. Global monitors only receive events once
/// the app is trusted for Accessibility, so they are reinstalled when that permission flips.
///
/// Modifiers double as normal typing keys (⌥ for special characters on many layouts), so a press
/// that is combined with any other key is treated as typing, not dictation:
/// - push-to-talk arms only after a short hold and is cancelled if another key joins in;
/// - toggle fires on release, and only for a clean tap.
@MainActor
final class ModifierHotkeyMonitor {
    var onPushToTalkDown: (() -> Void)?
    var onPushToTalkUp: (() -> Void)?
    var onPushToTalkCancel: (() -> Void)?
    var onToggle: (() -> Void)?

    /// Delay before push-to-talk starts recording, so ⌥-letter typing never starts the mic.
    private static let armDelay: Duration = .milliseconds(200)

    private struct Press {
        var interrupted = false
        var fired = false
    }

    private var pushPress: Press?
    private var togglePress: Press?
    private var armTask: Task<Void, Never>?
    private var monitors: [Any] = []
    private var trustPoll: Timer?
    private var installedWithTrust = false

    func start() {
        guard monitors.isEmpty else { return }
        installMonitors()
        // Poll until Accessibility is granted, then reinstall so the global monitors go live.
        trustPoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.installedWithTrust, Permissions.accessibilityGranted else { return }
                self.removeMonitors()
                self.installMonitors()
            }
        }
    }

    private func installMonitors() {
        installedWithTrust = Permissions.accessibilityGranted
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) {
            monitors.append(global)
        }
        // Global monitors don't see our own app's events (e.g. while Settings is focused).
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }) {
            monitors.append(local)
        }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private func handle(_ event: NSEvent) {
        let pushKey = ModifierKey.current(for: .pushToTalk)
        let toggleKey = ModifierKey.current(for: .toggleToTalk)

        guard event.type == .flagsChanged else {
            interruptAll() // any key typed while a trigger modifier is held
            return
        }

        let isDown = event.modifierFlags.rawValue & pushKey.flagMask != 0
        if pushKey != .none, event.keyCode == pushKey.keyCode {
            isDown ? pushDown() : pushUp()
            return
        }
        let toggleIsDown = event.modifierFlags.rawValue & toggleKey.flagMask != 0
        if toggleKey != .none, event.keyCode == toggleKey.keyCode {
            if toggleIsDown {
                if togglePress == nil { togglePress = Press() }
            } else if let press = togglePress {
                togglePress = nil
                if !press.interrupted { onToggle?() }
            }
            return
        }
        // Some other modifier changed while a trigger is held (e.g. ⌥⇧ for a character).
        interruptAll()
    }

    private func pushDown() {
        guard pushPress == nil else { return }
        pushPress = Press()
        armTask?.cancel()
        armTask = Task { [weak self] in
            try? await Task.sleep(for: Self.armDelay)
            guard !Task.isCancelled, let self, var press = self.pushPress, !press.interrupted else { return }
            press.fired = true
            self.pushPress = press
            self.onPushToTalkDown?()
        }
    }

    private func pushUp() {
        armTask?.cancel()
        guard let press = pushPress else { return }
        pushPress = nil
        if press.fired, !press.interrupted { onPushToTalkUp?() }
    }

    private func interruptAll() {
        togglePress?.interrupted = true
        guard var press = pushPress, !press.interrupted else { return }
        armTask?.cancel()
        press.interrupted = true
        pushPress = press
        if press.fired { onPushToTalkCancel?() }
    }
}
