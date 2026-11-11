import AppKit
import Carbon.HIToolbox

/// A system-wide shortcut, via the Carbon hot key API (needs no accessibility permission).
/// Several can be live at once (launcher, clipboard); each unregisters itself when released.
final class HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false
    private static var nextID: UInt32 = 1
    private var ref: EventHotKeyRef?
    private let id: UInt32

    static let keyCodes: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
        "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
        "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z, "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
        "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "space": kVK_Space, "return": kVK_Return, "tab": kVK_Tab, "escape": kVK_Escape,
        ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash, ";": kVK_ANSI_Semicolon,
        "'": kVK_ANSI_Quote, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket, "-": kVK_ANSI_Minus,
        "=": kVK_ANSI_Equal, "`": kVK_ANSI_Grave, "\\": kVK_ANSI_Backslash,
        "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6,
        "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
    ]

    /// Parses e.g. "ctrl+option+space".
    static func parse(_ spec: String) -> (key: UInt32, mods: UInt32)? {
        var mods = 0
        var key: Int?
        for part in spec.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "cmd", "command": mods |= cmdKey
            case "opt", "option", "alt": mods |= optionKey
            case "ctrl", "control": mods |= controlKey
            case "shift": mods |= shiftKey
            default: key = keyCodes[part]
            }
        }
        guard let key, mods != 0 else { return nil }
        return (UInt32(key), UInt32(mods))
    }

    /// The config spelling for a key press, e.g. "cmd+shift+v" (for the shortcut recorder).
    static func spec(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> String? {
        guard let name = keyCodes.first(where: { $0.value == Int(keyCode) })?.key else { return nil }
        var parts: [String] = []
        if flags.contains(.control) { parts.append("ctrl") }
        if flags.contains(.option) { parts.append("option") }
        if flags.contains(.shift) { parts.append("shift") }
        if flags.contains(.command) { parts.append("cmd") }
        guard !parts.isEmpty else { return nil }
        return (parts + [name]).joined(separator: "+")
    }

    /// "cmd+shift+v" → "⇧⌘V".
    static func display(_ spec: String) -> String {
        let parts = spec.lowercased().split(separator: "+").map(String.init)
        var out = ""
        if parts.contains(where: { $0 == "ctrl" || $0 == "control" }) { out += "⌃" }
        if parts.contains(where: { ["opt", "option", "alt"].contains($0) }) { out += "⌥" }
        if parts.contains("shift") { out += "⇧" }
        if parts.contains(where: { $0 == "cmd" || $0 == "command" }) { out += "⌘" }
        let key = parts.last { !["ctrl", "control", "opt", "option", "alt", "shift", "cmd", "command"].contains($0) } ?? ""
        let names = ["space": "Space", "return": "↩", "tab": "⇥", "escape": "⎋"]
        return out + (names[key] ?? key.uppercased())
    }

    init?(spec: String, handler: @escaping () -> Void) {
        HotKey.nextID += 1
        id = HotKey.nextID
        guard let (key, mods) = HotKey.parse(spec) else { return nil }
        if !HotKey.installed {
            // One handler for every hotkey; it looks up which one fired.
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
                HotKey.handlers[hk.id]?()
                return noErr
            }, 1, &type, nil, nil)
            HotKey.installed = true
        }
        let hotKeyID = EventHotKeyID(signature: OSType(0x424C_4E4B), id: id)
        guard RegisterEventHotKey(key, mods, hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr else { return nil }
        HotKey.handlers[id] = handler
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        HotKey.handlers[id] = nil
    }
}
