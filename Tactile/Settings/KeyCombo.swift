//
//  KeyCombo.swift
//  Tactile
//

import AppKit
import Carbon.HIToolbox

/// A user-recorded key combination with its own waveform: any set of
/// modifiers plus one real key. Recorded in the Keyboard pane, matched on
/// every keypress while keyboard haptics are on.
struct KeyCombo: Codable, Identifiable, Equatable {
    var id = UUID()
    var keyCode: UInt16
    /// Raw NSEvent.ModifierFlags, masked to ⌘⇧⌥⌃ at record time.
    var modifiers: UInt
    /// Human-readable form ("⌘⇧S"), built once when recorded.
    var display: String
    var waveform: HapticWaveform

    static func == (lhs: KeyCombo, rhs: KeyCombo) -> Bool { lhs.id == rhs.id }

    func matches(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        self.keyCode == keyCode && self.modifiers == modifiers.rawValue
    }

    /// "⌃⌥⇧⌘" + key name, in the standard macOS symbol order.
    static func displayString(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> String {
        var parts = ""
        if modifiers.contains(.control) { parts += "⌃" }
        if modifiers.contains(.option) { parts += "⌥" }
        if modifiers.contains(.shift) { parts += "⇧" }
        if modifiers.contains(.command) { parts += "⌘" }
        return parts + keyName(keyCode)
    }

    /// Names for keys that don't translate to a printable character.
    private static let specialNames: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 76: "⌤",
        115: "↖", 116: "⇞", 117: "⌦", 119: "↘", 121: "⇟",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    static func keyName(_ keyCode: UInt16) -> String {
        if let special = specialNames[keyCode] { return special }
        // Translate through the current keyboard layout so the name matches
        // what's printed on the user's keys.
        guard let sourceRef = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPtr = TISGetInputSourceProperty(sourceRef, kTISPropertyUnicodeKeyLayoutData)
        else { return "Key \(keyCode)" }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPtr).takeUnretainedValue() as Data

        let name: String? = layoutData.withUnsafeBytes { buffer in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            var deadKeys: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let error = UCKeyTranslate(
                layout, keyCode, UInt16(kUCKeyActionDisplay), 0,
                UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysBit),
                &deadKeys, chars.count, &length, &chars
            )
            guard error == noErr, length > 0 else { return nil }
            let text = String(utf16CodeUnits: chars, count: length)
            return text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : text.uppercased()
        }
        return name ?? "Key \(keyCode)"
    }
}
