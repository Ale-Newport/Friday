// Adapted from Apple-Integrations/App/Support/GlobalHotKey.swift (same author).
import AppKit
import Carbon.HIToolbox
import Foundation
import FridayCore

struct HotKeyCombo: Codable, Equatable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32

    /// ⌃⌥Space
    static let `default` = HotKeyCombo(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey))

    var display: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + Self.keyName(keyCode)
    }

    static func keyName(_ code: UInt32) -> String {
        switch Int(code) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Escape: return "⎋"
        case kVK_Tab: return "⇥"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default:
            let source = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
            guard let data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "key \(code)" }
            let layout = unsafeBitCast(data, to: CFData.self)
            var deadKeys: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = CFDataGetBytePtr(layout).withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { pointer in
                UCKeyTranslate(pointer, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysBit), &deadKeys, 4, &length, &chars)
            }
            return status == noErr && length > 0 ? String(utf16CodeUnits: chars, count: length).uppercased() : "key \(code)"
        }
    }

    static func from(event: NSEvent) -> HotKeyCombo? {
        var modifiers: UInt32 = 0
        if event.modifierFlags.contains(.control) { modifiers |= UInt32(controlKey) }
        if event.modifierFlags.contains(.option) { modifiers |= UInt32(optionKey) }
        if event.modifierFlags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if event.modifierFlags.contains(.command) { modifiers |= UInt32(cmdKey) }
        guard modifiers != 0 else { return nil }
        return HotKeyCombo(keyCode: UInt32(event.keyCode), modifiers: modifiers)
    }
}

/// One system-wide keyboard shortcut via `RegisterEventHotKey`: works without Accessibility or Input Monitoring
/// permission because macOS delivers only the registered combination.
@MainActor
final class GlobalHotKey {
    static let shared = GlobalHotKey()

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var onPress: (() -> Void)?
    private(set) var registeredCombo: HotKeyCombo?
    private(set) var lastError: String?

    private static let signature: OSType = {
        var value: OSType = 0
        for scalar in "FRDY".unicodeScalars { value = (value << 8) | OSType(scalar.value) }
        return value
    }()

    private init() {}

    @discardableResult
    func register(_ combo: HotKeyCombo, onPress: @escaping () -> Void) -> Bool {
        unregister()
        self.onPress = onPress
        lastError = nil
        if handlerRef == nil {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                MainActor.assumeIsolated { GlobalHotKey.shared.fire() }
                return noErr
            }, 1, &eventType, nil, &handlerRef)
            guard status == noErr else {
                lastError = "InstallEventHandler failed (\(status))"
                return false
            }
        }
        let identifier = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, identifier, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr else {
            hotKeyRef = nil
            lastError = status == OSStatus(eventHotKeyExistsErr) ? "That shortcut is already used by another app." : "RegisterEventHotKey failed (\(status))"
            JarvisLog.app.error("Could not register global shortcut: \(self.lastError ?? "", privacy: .public)")
            return false
        }
        registeredCombo = combo
        return true
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        registeredCombo = nil
    }

    private func fire() { onPress?() }
}
