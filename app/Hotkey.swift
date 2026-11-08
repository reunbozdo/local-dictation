// What starts and stops dictation: a modifier key on its own (seen through NSEvent monitors)
// or a key combination (a Carbon hotkey, which also keeps the keystroke away from the focused app).
import Carbon
import Cocoa

/// How the key drives a recording.
enum ActivationMode: String, CaseIterable, Identifiable {
    case holdOrTap = "hold_or_tap", hold, toggle

    var id: String { rawValue }
    var title: String {
        switch self {
        case .holdOrTap: "Hold, or tap to start and stop"
        case .hold: "Hold to talk"
        case .toggle: "Press to start, press again to stop"
        }
    }
    func hint(_ key: String) -> String {
        switch self {
        case .holdOrTap: "Hold \(key) and speak, or tap it to start and stop"
        case .hold: "Hold \(key) and speak"
        case .toggle: "Press \(key) to start, again to stop"
        }
    }
}

enum Hotkey: String, CaseIterable, Identifiable {
    case rightOption = "right_option", rightCommand = "right_command", rightControl = "right_control",
         rightShift = "right_shift", fn, combo

    var id: String { rawValue }
    var keyCode: UInt16 {
        switch self {
        case .rightOption: 61
        case .rightCommand: 54
        case .rightControl: 62
        case .rightShift: 60
        case .fn: 63
        case .combo: 0xFFFF  // never matches: combos come through Carbon
        }
    }
    /// Device-dependent modifier bit: tells the right key from the left one. Fn has only one key.
    var mask: UInt {
        switch self {
        case .rightOption: 0x40
        case .rightCommand: 0x10
        case .rightControl: 0x2000
        case .rightShift: 0x4
        case .fn: NSEvent.ModifierFlags.function.rawValue
        case .combo: 0
        }
    }
    var title: String {
        switch self {
        case .rightOption: "Right Option ⌥"
        case .rightCommand: "Right Command ⌘"
        case .rightControl: "Right Control ⌃"
        case .rightShift: "Right Shift ⇧"
        case .fn: "Fn / Globe 🌐"
        case .combo: "Key combination"
        }
    }
    var short: String {
        switch self {
        case .rightOption: "right ⌥"
        case .rightCommand: "right ⌘"
        case .rightControl: "right ⌃"
        case .rightShift: "right ⇧"
        case .fn: "Fn"
        case .combo: Combo.saved.display
        }
    }
}

// MARK: - Key combination

struct Combo: Equatable {
    var keyCode: UInt32
    var mods: UInt32  // Carbon modifier bits (cmdKey, optionKey, controlKey, shiftKey)
    var display: String

    static let fallback = Combo(keyCode: UInt32(kVK_Space), mods: UInt32(controlKey | optionKey), display: "⌃⌥Space")

    static var saved: Combo {
        let d = UserDefaults.standard
        guard let s = d.string(forKey: "combo_display"), d.object(forKey: "combo_key") != nil else { return fallback }
        return Combo(keyCode: UInt32(d.integer(forKey: "combo_key")), mods: UInt32(d.integer(forKey: "combo_mods")), display: s)
    }

    func save() {
        let d = UserDefaults.standard
        d.set(Int(keyCode), forKey: "combo_key"); d.set(Int(mods), forKey: "combo_mods"); d.set(display, forKey: "combo_display")
    }

    /// From a key press in the recorder. nil if it has no ⌘/⌃/⌥: a plain letter would fire while typing.
    /// F-keys are fine on their own.
    init?(event e: NSEvent) {
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let fKeys: [Int: String] = [kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
                                    kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
                                    kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
                                    kVK_F18: "F18", kVK_F19: "F19"]
        let names: [Int: String] = [kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
                                    kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→",
                                    kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘",
                                    kVK_PageUp: "⇞", kVK_PageDown: "⇟"]
        let code = Int(e.keyCode)
        guard f.contains(.command) || f.contains(.control) || f.contains(.option) || fKeys[code] != nil else { return nil }
        var m = 0, s = ""
        if f.contains(.control) { m |= controlKey; s += "⌃" }
        if f.contains(.option) { m |= optionKey; s += "⌥" }
        if f.contains(.shift) { m |= shiftKey; s += "⇧" }
        if f.contains(.command) { m |= cmdKey; s += "⌘" }
        // The key's own label from the current layout, not the character the modifiers produce.
        let key = fKeys[code] ?? names[code] ?? (e.charactersIgnoringModifiers ?? "?").uppercased()
        self.init(keyCode: UInt32(code), mods: UInt32(m), display: s + key)
    }

    init(keyCode: UInt32, mods: UInt32, display: String) {
        self.keyCode = keyCode; self.mods = mods; self.display = display
    }
}

/// One system-wide key combination with press and release callbacks.
final class ComboHotkey {
    static let shared = ComboHotkey()
    var onPress: () -> Void = {}
    var onRelease: () -> Void = {}
    /// True while Settings records a new combination: the old one must not start dictation then.
    var paused = false
    private var ref: EventHotKeyRef?
    private(set) var current: Combo?

    private init() {
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            let me = ComboHotkey.shared
            guard let event, !me.paused else { return noErr }
            GetEventKind(event) == UInt32(kEventHotKeyPressed) ? me.onPress() : me.onRelease()
            return noErr
        }, specs.count, &specs, nil, nil)
    }

    /// Registers `combo` (nil = none). Returns false if another app already owns it.
    @discardableResult
    func set(_ combo: Combo?) -> Bool {
        if combo == current && (ref != nil || combo == nil) { return true }
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        current = combo
        guard let combo else { return true }
        let st = RegisterEventHotKey(combo.keyCode, combo.mods, EventHotKeyID(signature: 0x4C444354, id: 1),  // "LDCT"
                                     GetApplicationEventTarget(), 0, &ref)
        if st != noErr { log("hotkey \(combo.display): register failed (\(st))"); ref = nil; return false }
        log("hotkey: \(combo.display)")
        return true
    }
}
