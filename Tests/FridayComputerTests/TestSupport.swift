import Foundation
import FridayCore
import Testing

@testable import FridayComputer

func executionContext(language: Language = .en, confirmed: Bool = false) -> ExecutionContext {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
    return ExecutionContext(
        language: language, now: Date(timeIntervalSince1970: 1_792_238_880), calendar: calendar, settings: JarvisSettings(),
        source: .test, isConfirmed: confirmed)
}

extension ToolOutcome {
    var output: ToolOutput? { if case .done(let output) = self { return output } else { return nil } }
    var clarification: Clarification? { if case .clarify(let value) = self { return value } else { return nil } }
    var confirmation: ConfirmationRequest? { if case .confirm(let value) = self { return value } else { return nil } }
}

/// A hand-built capture of a TextEdit save sheet, used by the pure tests.
enum FakeTrees {
    static func saveSheet() -> UITree {
        let app = AppInfo(pid: 42, bundleID: "com.apple.TextEdit", name: "TextEdit", localizedName: "TextEdit")
        let elements: [UIElementSnapshot] = [
            UIElementSnapshot(
                id: "e1", role: "AXWindow", label: "Untitled", frame: ScreenRect(x: 0, y: 25, width: 800, height: 600),
                children: ["e2", "e3", "e4", "e5", "e6", "e7", "e8"], path: []),
            UIElementSnapshot(
                id: "e2", role: "AXButton", label: "Save", frame: ScreenRect(x: 700, y: 560, width: 80, height: 30), actions: ["AXPress"], path: [0]),
            UIElementSnapshot(
                id: "e3", role: "AXButton", label: "Cancel", frame: ScreenRect(x: 600, y: 560, width: 80, height: 30), actions: ["AXPress"], path: [1]),
            UIElementSnapshot(
                id: "e4", role: "AXTextField", label: "Name", value: "report.txt", frame: ScreenRect(x: 100, y: 100, width: 400, height: 24),
                actions: ["AXConfirm"], focused: true, path: [2]),
            UIElementSnapshot(
                id: "e5", role: "AXStaticText", label: "Choose a name for the document", frame: ScreenRect(x: 100, y: 60, width: 400, height: 20), path: [3]),
            UIElementSnapshot(
                id: "e6", role: "AXSecureTextField", label: "Password", value: nil, frame: ScreenRect(x: 100, y: 140, width: 400, height: 24), secure: true, path: [4]),
            UIElementSnapshot(
                id: "e7", role: "AXButton", label: "Eliminar", frame: ScreenRect(x: 100, y: 560, width: 80, height: 30), actions: ["AXPress"], enabled: false, path: [5]),
            UIElementSnapshot(
                id: "e8", role: "AXScrollArea", label: "", frame: ScreenRect(x: 0, y: 180, width: 800, height: 360), actions: ["AXScrollDownByPage"], path: [6],
                scrollPosition: 0.3),
        ]
        return UITree(
            app: app, window: WindowRef(id: 77, title: "Untitled", frame: ScreenRect(x: 0, y: 25, width: 800, height: 600)), scope: .frontmostWindow,
            rootIDs: ["e1"], elements: Dictionary(uniqueKeysWithValues: elements.map { ($0.id, $0) }), order: elements.map(\.id), focusedID: "e4",
            texts: ["Choose a name for the document", "Name"], truncated: false, visited: 12)
    }
}
