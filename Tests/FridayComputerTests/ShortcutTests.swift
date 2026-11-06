import CoreGraphics
import Foundation
import Testing

@testable import FridayComputer

@Suite struct ShortcutTests {
    @Test func parsesEnglishShortcut() throws {
        let shortcut = try KeyboardShortcut.parse("cmd+shift+s")
        #expect(shortcut.key == "s")
        #expect(shortcut.keyCode == 1)
        #expect(shortcut.modifiers == [.command, .shift])
        #expect(shortcut.description == "cmd+shift+s")
        #expect(shortcut.flags.contains(.maskCommand) && shortcut.flags.contains(.maskShift))
        #expect(!shortcut.flags.contains(.maskControl))
    }

    @Test func parsesSpanishAliases() throws {
        #expect(try KeyboardShortcut.parse("comando+mayús+s") == KeyboardShortcut.parse("cmd+shift+s"))
        #expect(try KeyboardShortcut.parse("control+opción+espacio").description == "ctrl+alt+space")
        #expect(try KeyboardShortcut.parse("intro").keyCode == 36)
        #expect(try KeyboardShortcut.parse("flecha izquierda").key == "left")
        #expect(try KeyboardShortcut.parse("comando+retroceso").key == "delete")
        #expect(try KeyboardShortcut.parse("supr").key == "forwarddelete")
    }

    @Test(arguments: [
        ("ctrl+alt+space", "ctrl+alt+space", CGKeyCode(49)), ("enter", "return", 36), ("esc", "escape", 53), ("tab", "tab", 48), ("left", "left", 123),
        ("up", "up", 126), ("f5", "f5", 96), ("F12", "f12", 111), ("cmd s", "cmd+s", 1), ("cmd-s", "cmd+s", 1), ("⌘⇧S", "cmd+shift+s", 1),
        ("⌘ + ⌥ + esc", "cmd+alt+escape", 53), ("cmd++", "cmd+=", 24), ("cmd+-", "cmd+-", 27), ("page down", "pagedown", 121), ("Cmd + Shift + 3", "cmd+shift+3", 20),
        ("fn+f11", "fn+f11", 103), ("space", "space", 49), ("forward-delete", "forwarddelete", 117), ("cmd+forward-delete", "cmd+forwarddelete", 117),
        ("-", "-", 27), ("page-down", "pagedown", 121), ("flecha-izquierda", "left", 123),
    ])
    func parsesVariants(input: String, canonical: String, code: CGKeyCode) throws {
        let shortcut = try KeyboardShortcut.parse(input)
        #expect(shortcut.description == canonical)
        #expect(shortcut.keyCode == code)
    }

    @Test(arguments: ["", "cmd+", "foo+s", "cmd+nosuchkey", "+"])
    func rejectsUnknownInput(input: String) {
        if input == "+" {
            // A lone plus is the "=" key.
            #expect((try? KeyboardShortcut.parse(input))?.key == "=")
        } else {
            #expect(throws: KeyboardShortcut.ParseError.self) { try KeyboardShortcut.parse(input) }
        }
    }

    @Test(arguments: ["cmd+q", "cmd+w", "cmd+delete", "cmd+shift+delete", "cmd+alt+esc", "cmd+return", "comando+q"])
    func flagsDestructiveShortcuts(input: String) throws {
        #expect(try KeyboardShortcut.parse(input).isRisky)
    }

    @Test(arguments: ["cmd+s", "cmd+c", "cmd+v", "enter", "esc", "ctrl+alt+space", "delete", "cmd+shift+s", "ctrl+cmd+q"])
    func allowsOrdinaryShortcuts(input: String) throws {
        #expect(try !KeyboardShortcut.parse(input).isRisky)
    }
}
