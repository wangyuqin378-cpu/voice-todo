import AppKit

/// A physical trigger key with optional modifiers. No transcript or key history.
struct DictationShortcut: Codable, Equatable {
    let keyCode: UInt16
    let modifiers: UInt
    let keyLabel: String
    static let fn = DictationShortcut(keyCode: 63, modifiers: 0, keyLabel: "Fn")
    static let modifierMask: UInt = NSEvent.ModifierFlags.command.rawValue | NSEvent.ModifierFlags.option.rawValue |
        NSEvent.ModifierFlags.control.rawValue | NSEvent.ModifierFlags.shift.rawValue | NSEvent.ModifierFlags.function.rawValue
    static let modifierKeys: [UInt16: (flag: UInt, device: UInt, label: String)] = [
        63: (NSEvent.ModifierFlags.function.rawValue, 0, "Fn"),
        55: (NSEvent.ModifierFlags.command.rawValue, 0x8, "左侧 ⌘"), 54: (NSEvent.ModifierFlags.command.rawValue, 0x10, "右侧 ⌘"),
        58: (NSEvent.ModifierFlags.option.rawValue, 0x20, "左侧 ⌥"), 61: (NSEvent.ModifierFlags.option.rawValue, 0x40, "右侧 ⌥"),
        59: (NSEvent.ModifierFlags.control.rawValue, 0x1, "左侧 ⌃"), 62: (NSEvent.ModifierFlags.control.rawValue, 0x2000, "右侧 ⌃"),
        56: (NSEvent.ModifierFlags.shift.rawValue, 0x2, "左侧 ⇧"), 60: (NSEvent.ModifierFlags.shift.rawValue, 0x4, "右侧 ⇧")
    ]
    var isValid: Bool {
        keyCode < 128 && keyCode != 53 && keyCode != 57 && !keyLabel.isEmpty && keyLabel.count <= 24 &&
        !keyLabel.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) &&
        modifiers & ~Self.modifierMask == 0 && modifiers & (Self.modifierKeys[keyCode]?.flag ?? 0) == 0
    }
    var requiredFlags: UInt { modifiers | (Self.modifierKeys[keyCode]?.flag ?? 0) }
    var label: String {
        let order: [(NSEvent.ModifierFlags, String)] = [(.function, "Fn"), (.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        return (order.compactMap { modifiers & $0.0.rawValue != 0 ? $0.1 : nil } + [Self.modifierKeys[keyCode]?.label ?? keyLabel]).joined(separator: " + ")
    }
    static func recorded(code: UInt16, flags: UInt, characters: String?) -> Self? {
        let special: [UInt16: String] = [36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 117: "Forward Delete",
            123: "←", 124: "→", 125: "↓", 126: "↑", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16",
            64: "F17", 79: "F18", 80: "F19", 90: "F20", 76: "Enter"]
        let label = modifierKeys[code]?.label ?? special[code] ?? characters?.uppercased() ?? "Key \(code)"
        let value = Self(keyCode: code, modifiers: (flags & modifierMask) & ~(modifierKeys[code]?.flag ?? 0), keyLabel: label)
        return value.isValid ? value : nil
    }
}

/// Used by custom bindings; the default Fn handler retains its existing event semantics.
struct DictationShortcutGesture {
    enum Effect { case none, press, release, cancel }
    private var triggerDown = false
    private var active = false
    private var blocked = false
    private var keys: Set<UInt16> = []
    private var physicalFn = false

    mutating func handle(_ type: CGEventType, code: UInt16, flags: UInt, shortcut: DictationShortcut, isRepeat: Bool = false) -> Effect {
        // A held key after cancellation, wake, or binding changes cannot acquire
        // a new recording. Wait for a fresh physical key-down event.
        if type == .keyDown, code == shortcut.keyCode, isRepeat { return .none }
        if type == .flagsChanged, code == 63 { physicalFn = flags & NSEvent.ModifierFlags.function.rawValue != 0 }
        if type == .keyDown { keys.insert(code) }
        if type == .keyUp { keys.remove(code) }
        let previousDown = triggerDown
        if code == shortcut.keyCode {
            if let modifier = DictationShortcut.modifierKeys[code], type == .flagsChanged {
                // Prefer side-specific device flags when present. NSEvent test/local
                // sources may only supply the aggregate flag for this changed key.
                let familyDevices = DictationShortcut.modifierKeys.values.filter { $0.flag == modifier.flag }.reduce(UInt(0)) { $0 | $1.device }
                triggerDown = flags & modifier.flag != 0 && (flags & familyDevices == 0 || flags & modifier.device != 0 || code == 63)
            } else if type == .keyDown { triggerDown = true }
            else if type == .keyUp { triggerDown = false }
        }
        var actualFlags = flags & DictationShortcut.modifierMask
        // Function keys and arrows carry .function without a physical Fn press.
        if !physicalFn && shortcut.keyCode != 63 { actualFlags &= ~NSEvent.ModifierFlags.function.rawValue }
        let triggerModifier = DictationShortcut.modifierKeys[shortcut.keyCode]
        let otherSide = DictationShortcut.modifierKeys.values.filter { $0.flag == triggerModifier?.flag && $0.device != triggerModifier?.device }.reduce(UInt(0)) { $0 | $1.device }
        let extra = actualFlags & ~shortcut.requiredFlags != 0 || flags & otherSide != 0 || !keys.subtracting([shortcut.keyCode]).isEmpty
        if type == .keyDown, code == 53 {
            active = false; blocked = triggerDown
            return .cancel
        }
        if (triggerDown || active) && extra {
            let cancel = !blocked
            blocked = triggerDown; active = false
            return cancel ? .cancel : .none
        }
        if active && (!triggerDown || actualFlags != shortcut.requiredFlags) {
            active = false; blocked = triggerDown
            return .release
        }
        if !triggerDown {
            if previousDown { blocked = false }
            return .none
        }
        if !active && !blocked && actualFlags == shortcut.requiredFlags {
            active = true
            return .press
        }
        return .none
    }
}
