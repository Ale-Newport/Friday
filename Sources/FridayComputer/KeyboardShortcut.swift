// Portions adapted from Atticus (https://github.com/SaarthurR/atticus-mac), MIT License, Copyright (c) 2026 SaarthurR.
// Hands logic adapts ideas from Plip (https://github.com/hussainn7/plip-oss), MIT License, Copyright (c) 2026 Hussain.
// See NOTICE-ATTICUS.md.
import CoreGraphics
import Foundation
import FridayCore

/// A parsed keyboard shortcut such as `cmd+shift+s`, `ctrl+alt+space`, `comando+mayús+s` or `⌘⇧S`.
///
/// The key-code table and the parsing approach are adapted from Atticus `Hands.keys()`; Friday adds Spanish and
/// symbol aliases, whitespace/dash separators and the destructive-shortcut classifier.
public struct KeyboardShortcut: Sendable, Hashable, CustomStringConvertible {
    /// Declaration order is the canonical order in ``description``: `cmd+ctrl+alt+shift+fn+key`.
    public enum Modifier: String, Sendable, Hashable, CaseIterable, Comparable {
        case command = "cmd"
        case control = "ctrl"
        case option = "alt"
        case shift = "shift"
        case function = "fn"

        public static func < (lhs: Modifier, rhs: Modifier) -> Bool {
            let order = Modifier.allCases
            return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
        }

        var flag: CGEventFlags {
            switch self {
            case .command: return .maskCommand
            case .shift: return .maskShift
            case .control: return .maskControl
            case .option: return .maskAlternate
            case .function: return .maskSecondaryFn
            }
        }
    }

    public struct ParseError: Error, Sendable, Hashable, CustomStringConvertible {
        public enum Kind: Sendable, Hashable { case emptyKey, unknownKey(String), unknownModifier(String) }
        public let kind: Kind
        public var description: String {
            switch kind {
            case .emptyKey: return "No key given."
            case .unknownKey(let key): return "Unknown key: \(key)"
            case .unknownModifier(let modifier): return "Unknown modifier: \(modifier)"
            }
        }
    }

    /// Canonical key name (`s`, `return`, `f5`, `left`…).
    public let key: String
    public let keyCode: CGKeyCode
    public let modifiers: Set<Modifier>

    public init(key: String, keyCode: CGKeyCode, modifiers: Set<Modifier>) {
        self.key = key
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public var flags: CGEventFlags {
        modifiers.reduce(CGEventFlags()) { $0.union($1.flag) }
    }

    /// Canonical form, e.g. `cmd+shift+s`.
    public var description: String { (modifiers.sorted().map(\.rawValue) + [key]).joined(separator: "+") }

    // MARK: Parsing

    static let modifierAliases: [String: Modifier] = [
        "cmd": .command, "command": .command, "comando": .command, "⌘": .command, "meta": .command, "super": .command,
        "shift": .shift, "mayus": .shift, "mayusculas": .shift, "⇧": .shift,
        "ctrl": .control, "control": .control, "ctl": .control, "⌃": .control,
        "alt": .option, "option": .option, "opt": .option, "opcion": .option, "⌥": .option,
        "fn": .function, "function": .function, "funcion": .function,
    ]

    static let keyAliases: [String: String] = [
        "enter": "return", "intro": "return", "retorno": "return", "↩": "return", "⏎": "return",
        "esc": "escape", "⎋": "escape",
        "tabulador": "tab", "⇥": "tab",
        "spacebar": "space", "espacio": "space", "␣": "space",
        "backspace": "delete", "retroceso": "delete", "⌫": "delete", "borrar": "delete",
        "fwddelete": "forwarddelete", "forward-delete": "forwarddelete", "del": "forwarddelete", "supr": "forwarddelete",
        "suprimir": "forwarddelete", "⌦": "forwarddelete",
        "pgdn": "pagedown", "pagedn": "pagedown", "avpag": "pagedown", "pagedown": "pagedown",
        "pgup": "pageup", "repag": "pageup",
        "inicio": "home", "fin": "end",
        "izquierda": "left", "←": "left", "leftarrow": "left", "arrowleft": "left", "flechaizquierda": "left",
        "derecha": "right", "→": "right", "rightarrow": "right", "arrowright": "right", "flechaderecha": "right",
        "abajo": "down", "↓": "down", "downarrow": "down", "arrowdown": "down", "flechaabajo": "down",
        "arriba": "up", "↑": "up", "uparrow": "up", "arrowup": "up", "flechaarriba": "up",
        "plus": "=", "mas": "=", "zoomin": "=", "equals": "=", "igual": "=",
        "minus": "-", "menos": "-", "zoomout": "-", "dash": "-",
        "capslock": "capslock", "blocmayus": "capslock",
    ]

    static let keyCodes: [String: CGKeyCode] = [
        "return": 36, "escape": 53, "tab": 48, "space": 49, "delete": 51, "forwarddelete": 117, "pagedown": 121, "pageup": 116,
        "home": 115, "end": 119, "left": 123, "right": 124, "down": 125, "up": 126, "capslock": 57, "help": 114, "keypadenter": 76,
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47, "`": 50,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103,
        "f12": 111, "f13": 105, "f14": 107, "f15": 113, "f16": 106, "f17": 64, "f18": 79, "f19": 80, "f20": 90,
    ]

    /// Parses `cmd+shift+s`, `cmd shift s`, `cmd-s`, `⌘⇧s`, `comando+mayús+s`, `enter`, `esc`, `f5`, `cmd++` (zoom in)…
    public static func parse(_ text: String) throws -> KeyboardShortcut {
        let folded = Safety.normalized(text).trimmingCharacters(in: .whitespaces)
        var tokens: [String]
        if keyAliases[folded] != nil || keyCodes[folded] != nil {
            // A complete key name first ("forward-delete", "-", "page down"), before any separator splitting.
            tokens = [folded]
        } else if folded.contains("+") {
            var compact = folded.replacingOccurrences(of: " ", with: "")
            if compact.hasSuffix("++") { compact = String(compact.dropLast()) + "=" }
            tokens = compact.split(separator: "+", omittingEmptySubsequences: true).map(String.init)
            if compact == "+" { tokens = ["="] }
        } else if folded.contains(" ") {
            tokens = folded.split(separator: " ").map(String.init)
            // "flecha izquierda", "page down": a multi-word key name rather than modifiers + key.
            let joined = tokens.joined()
            if keyAliases[joined] != nil || keyCodes[joined] != nil { tokens = [joined] }
        } else if folded.count > 1, folded.contains("-"), !folded.hasSuffix("-") {
            tokens = folded.split(separator: "-", omittingEmptySubsequences: true).map(String.init)
            // "page-down", "flecha-izquierda": a multi-word key name written with dashes.
            let joined = tokens.joined()
            if keyAliases[joined] != nil || keyCodes[joined] != nil { tokens = [joined] }
        } else {
            tokens = [folded]
        }
        // Glued symbols: "⌘⇧s" → ["⌘", "⇧", "s"].
        tokens = tokens.flatMap { token -> [String] in
            guard token.count > 1, token.contains(where: { "⌘⇧⌃⌥".contains($0) }) else { return [token] }
            var pieces: [String] = []
            var rest = ""
            for character in token {
                if "⌘⇧⌃⌥".contains(character) { pieces.append(String(character)) } else { rest.append(character) }
            }
            if !rest.isEmpty { pieces.append(rest) }
            return pieces
        }
        guard let last = tokens.popLast(), !last.isEmpty else { throw ParseError(kind: .emptyKey) }
        var modifiers: Set<Modifier> = []
        for token in tokens {
            guard let modifier = modifierAliases[token] else { throw ParseError(kind: .unknownModifier(token)) }
            modifiers.insert(modifier)
        }
        let key = keyAliases[last] ?? last
        guard let code = keyCodes[key] else { throw ParseError(kind: .unknownKey(last)) }
        return KeyboardShortcut(key: key, keyCode: code, modifiers: modifiers)
    }

    /// Shortcuts that quit, close, delete, send or force-quit: the integration asks before pressing them.
    public var isRisky: Bool {
        guard modifiers.contains(.command) else { return false }
        if key == "q", modifiers.contains(.control) { return false }  // ctrl+cmd+q locks the screen
        if ["q", "w", "delete", "forwarddelete", "return", "keypadenter"].contains(key) { return true }
        if modifiers.contains(.option), key == "escape" { return true }
        if modifiers.contains(.shift), key == "escape" { return true }
        if modifiers.contains(.shift), key == "d" { return true }  // Send in Mail
        return false
    }
}
