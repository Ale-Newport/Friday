import AppKit
import CoreGraphics
import Foundation
import FridayCore
import os

/// Remembers which system prompts this process has already shown, so a second refusal reads as "denied".
final class PromptMemory: Sendable {
    private let prompted = OSAllocatedUnfairLock(initialState: Set<String>())
    func markPrompted(_ id: String) { prompted.withLock { _ = $0.insert(id) } }
    func wasPrompted(_ id: String) -> Bool { prompted.withLock { $0.contains(id) } }
}

/// Friday's "computer" integration: screen reading, clicking, typing, keys, menus, windows, screenshots.
///
/// Every mutating tool reads the result back before claiming success; presses on risky controls (Delete, Pay, Send…),
/// destructive shortcuts and closing windows ask for confirmation first.
public struct ComputerIntegration: AppIntegration {
    public let id: IntegrationID = "computer"
    public let displayName = LocalizedText(en: "Computer", es: "Ordenador")
    public let summary = LocalizedText(
        en: "Reads what is on screen, clicks, types, presses keys, uses menus and arranges windows through macOS Accessibility; screenshots and OCR through Screen Recording.",
        es: "Lee lo que hay en pantalla, hace clic, escribe, pulsa teclas, usa menús y organiza ventanas mediante Accesibilidad de macOS; capturas y OCR mediante Grabación de pantalla.")
    public let symbolName = "macwindow"

    public let accessibility: AccessibilityService
    public let windows: WindowManager
    public let screen: ScreenCaptureService
    private let prompts = PromptMemory()
    private static let log = JarvisLog.integration("computer")

    public init(accessibility: AccessibilityService = AccessibilityService(), windows: WindowManager = WindowManager(), screen: ScreenCaptureService? = nil) {
        self.accessibility = accessibility
        self.windows = windows
        self.screen = screen ?? ScreenCaptureService(accessibility: accessibility)
    }

    public var permissionRequirements: [PermissionRequirement] {
        [ComputerPermissions.accessibility, ComputerPermissions.screenRecording, ComputerPermissions.systemEventsAutomation]
    }

    // MARK: Tool names

    public static let frontmost: ToolName = "computer.frontmost"
    public static let windowsTool: ToolName = "computer.windows"
    public static let displays: ToolName = "computer.displays"
    public static let focusApp: ToolName = "computer.focus_app"
    public static let focusWindow: ToolName = "computer.focus_window"
    public static let arrangeWindow: ToolName = "computer.arrange_window"
    public static let setWindowFrame: ToolName = "computer.set_window_frame"
    public static let minimizeWindow: ToolName = "computer.minimize_window"
    public static let closeWindow: ToolName = "computer.close_window"
    public static let uiElements: ToolName = "computer.ui_elements"
    public static let click: ToolName = "computer.click"
    public static let typeText: ToolName = "computer.type_text"
    public static let pressKeys: ToolName = "computer.press_keys"
    public static let menu: ToolName = "computer.menu"
    public static let selectedText: ToolName = "computer.selected_text"
    public static let screenshot: ToolName = "computer.screenshot"
    public static let describeScreen: ToolName = "computer.describe_screen"
    public static let lockScreen: ToolName = "computer.lock_screen"
    public static let setAppearance: ToolName = "computer.set_appearance"
    public static let scroll: ToolName = "computer.scroll"

    // MARK: Descriptors

    public var tools: [ToolDescriptor] {
        let windowParameters: [ToolParameter] = [
            .string("title", "Window title (or part of it).", maxLength: 300),
            .integer("window_id", "Window id from computer.windows.", min: 1),
            .string("app", "App name or bundle id that owns the window.", maxLength: 200),
        ]
        func tool(
            _ name: ToolName, _ title: String, _ summary: String, _ parameters: [ToolParameter] = [], constraints: [ToolConstraint] = [],
            safety: ToolSafety, confirm: Bool = false, timeout: TimeInterval = 30, examples: [ToolExample] = []
        ) -> ToolDescriptor {
            ToolDescriptor(
                name: name, integration: id, title: title, summary: summary, parameters: parameters, constraints: constraints, safety: safety,
                timeout: timeout, examples: examples, requiresConfirmation: confirm)
        }
        return [
            tool(
                Self.frontmost, "Front application", "The application in front and its focused window.", safety: .readOnly,
                examples: [ToolExample("Which app is in front?", arguments: [:]), ToolExample("¿Qué aplicación está en primer plano?", language: .es, arguments: [:])]),
            tool(
                Self.windowsTool, "List windows", "Lists windows with ids, titles, frames and displays. Filter by app.",
                [.string("app", "Only windows of this app (name or bundle id).", maxLength: 200), .boolean("on_screen_only", "Skip hidden and minimised windows.", default: true)],
                safety: .readOnly,
                examples: [
                    ToolExample("List my open windows", arguments: [:]), ToolExample("Which Safari windows are open?", arguments: ["app": "Safari"]),
                    ToolExample("Lista mis ventanas abiertas", language: .es, arguments: [:]),
                    ToolExample("¿Qué ventanas de Safari hay abiertas?", language: .es, arguments: ["app": "Safari"]),
                ]),
            tool(
                Self.displays, "List displays", "Lists connected displays with their frames and visible areas.", safety: .readOnly,
                examples: [ToolExample("How many displays do I have?", arguments: [:]), ToolExample("¿Cuántas pantallas tengo?", language: .es, arguments: [:])]),
            tool(
                Self.focusApp, "Bring an app to the front", "Activates a running app by name or bundle id and verifies it is frontmost.",
                [.string("app", "App name or bundle id.", required: true, maxLength: 200)], safety: .modifying,
                examples: [
                    ToolExample("Switch to Safari", arguments: ["app": "Safari"]), ToolExample("Bring Mail to the front", arguments: ["app": "Mail"]),
                    ToolExample("Cambia a Safari", language: .es, arguments: ["app": "Safari"]), ToolExample("Pon Mail delante", language: .es, arguments: ["app": "Mail"]),
                ]),
            tool(
                Self.focusWindow, "Focus a window", "Raises and focuses one window by title or id.", windowParameters,
                constraints: [.atLeastOne(["title", "window_id", "app"])], safety: .modifying,
                examples: [
                    ToolExample("Focus the window called Budget", arguments: ["title": "Budget"]),
                    ToolExample("Go to the Inbox window of Mail", arguments: ["title": "Inbox", "app": "Mail"]),
                    ToolExample("Activa la ventana Presupuesto", language: .es, arguments: ["title": "Presupuesto"]),
                    ToolExample("Ve a la ventana Entrada de Mail", language: .es, arguments: ["title": "Entrada", "app": "Mail"]),
                ]),
            tool(
                Self.arrangeWindow, "Arrange a window",
                "Snaps a window to a preset (halves, quarters, thirds, maximize, center, full screen) on a display and verifies its frame.",
                windowParameters + [
                    .choice("preset", WindowPreset.allCases.map(\.rawValue), "Where to put the window.", required: true),
                    .integer("display", "Display index from computer.displays (default: the window's current display).", min: 0, max: 16),
                ], safety: .modifying,
                examples: [
                    ToolExample("Put Safari on the left half of the screen", arguments: ["app": "Safari", "preset": "left_half"]),
                    ToolExample("Maximize this window", arguments: ["preset": "maximize"]),
                    ToolExample("Move Notes to the right half of display 1", arguments: ["app": "Notes", "preset": "right_half", "display": 1]),
                    ToolExample("Pon Safari en la mitad izquierda de la pantalla", language: .es, arguments: ["app": "Safari", "preset": "left_half"]),
                    ToolExample("Maximiza esta ventana", language: .es, arguments: ["preset": "maximize"]),
                    ToolExample("Centra la ventana de Notas", language: .es, arguments: ["app": "Notes", "preset": "center"]),
                ]),
            tool(
                Self.setWindowFrame, "Set a window frame", "Moves and resizes a window to exact screen points (top-left origin) and verifies.",
                windowParameters + [
                    .number("x", "Left edge in screen points.", required: true), .number("y", "Top edge in screen points.", required: true),
                    .number("width", "Width in points.", required: true, min: 1), .number("height", "Height in points.", required: true, min: 1),
                ], safety: .modifying,
                examples: [
                    ToolExample("Resize the Terminal window to 1200 by 800 at the top left", arguments: ["app": "Terminal", "x": 0, "y": 25, "width": 1200, "height": 800]),
                    ToolExample("Pon la ventana de Terminal en 0,25 con 1200 por 800", language: .es, arguments: ["app": "Terminal", "x": 0, "y": 25, "width": 1200, "height": 800]),
                ]),
            tool(
                Self.minimizeWindow, "Minimize a window", "Minimises a window to the Dock and verifies.", windowParameters, safety: .modifying,
                examples: [
                    ToolExample("Minimize the Music window", arguments: ["app": "Music"]), ToolExample("Minimize this window", arguments: [:]),
                    ToolExample("Minimiza la ventana de Música", language: .es, arguments: ["app": "Music"]),
                ]),
            tool(
                Self.closeWindow, "Close a window", "Closes a window through its close button after confirmation; unsaved changes may be lost.", windowParameters,
                safety: .modifying, confirm: true,
                examples: [
                    ToolExample("Close the Preview window", arguments: ["app": "Preview"]), ToolExample("Close this window", arguments: [:]),
                    ToolExample("Cierra la ventana de Vista Previa", language: .es, arguments: ["app": "Preview"]),
                ]),
            tool(
                Self.uiElements, "Read the screen controls",
                "Reads the accessibility tree of the front window (or an app) into a compact list with element ids to click, type into or scroll. Optional query finds matching elements.",
                [
                    .choice("scope", ["frontmost", "app", "focused"], "What to read: the front window, an app's window, or only the focused element.", default: "frontmost"),
                    .string("app", "App name or bundle id (for scope app).", maxLength: 200),
                    .string("query", "Find elements by label, value or role (fuzzy, accent-insensitive).", maxLength: 200),
                    .integer("max_lines", "Maximum lines in the description.", min: 10, max: 1000, default: 120),
                    .integer("max_elements", "Element budget for the capture.", min: 20, max: 2000, default: 400),
                ], safety: .readOnly, timeout: 20,
                examples: [
                    ToolExample("What buttons are on screen?", arguments: [:]), ToolExample("Find the search field in Finder", arguments: ["scope": "app", "app": "Finder", "query": "search"]),
                    ToolExample("¿Qué botones hay en pantalla?", language: .es, arguments: [:]),
                    ToolExample("Busca el campo de búsqueda en Finder", language: .es, arguments: ["scope": "app", "app": "Finder", "query": "búsqueda"]),
                ]),
            tool(
                Self.click, "Click a control", "Presses a control by element id (from computer.ui_elements) or by label; risky controls (Delete, Pay, Send…) need confirmation.",
                [
                    .string("element_id", "Element id such as e12 from the last computer.ui_elements.", maxLength: 20),
                    .string("label", "Label of the control to click (fuzzy).", maxLength: 200),
                    .string("app", "App whose window to read when clicking by label.", maxLength: 200),
                    .choice("action", ["press", "pick", "open", "confirm", "show_menu"], "Accessibility action to perform.", default: "press"),
                ], constraints: [.atLeastOne(["element_id", "label"])], safety: .modifying, timeout: 20,
                examples: [
                    ToolExample("Click the Save button", arguments: ["label": "Save"]), ToolExample("Click e12", arguments: ["element_id": "e12"]),
                    ToolExample("Press OK in the dialog", arguments: ["label": "OK"]),
                    ToolExample("Haz clic en el botón Guardar", language: .es, arguments: ["label": "Guardar"]),
                    ToolExample("Pulsa e12", language: .es, arguments: ["element_id": "e12"]),
                ]),
            tool(
                Self.typeText, "Type text", "Types text into the focused field (or into a given element) and reads it back.",
                [
                    .string("text", "The text to type.", required: true, maxLength: 20_000),
                    .string("element_id", "Element id of a text field to fill (replaces its contents).", maxLength: 20),
                    .string("app", "App to bring to the front first.", maxLength: 200),
                ], safety: .modifying, timeout: 60,
                examples: [
                    ToolExample("Type hello world", arguments: ["text": "hello world"]), ToolExample("Fill e7 with John Smith", arguments: ["element_id": "e7", "text": "John Smith"]),
                    ToolExample("Escribe hola mundo", language: .es, arguments: ["text": "hola mundo"]),
                    ToolExample("Rellena e7 con Juan Pérez", language: .es, arguments: ["element_id": "e7", "text": "Juan Pérez"]),
                ]),
            tool(
                Self.pressKeys, "Press a shortcut", "Presses a keyboard shortcut such as cmd+shift+s, enter, esc or f5; destructive ones (cmd+q, cmd+delete…) need confirmation.",
                [
                    .string("keys", "Shortcut, e.g. cmd+shift+s, ctrl+alt+space, enter, esc, tab, left, f5, comando+mayús+s.", required: true, maxLength: 60),
                    .string("app", "App to bring to the front first.", maxLength: 200),
                    .integer("times", "How many times to press it.", min: 1, max: 50, default: 1),
                ], safety: .modifying,
                examples: [
                    ToolExample("Press cmd+s", arguments: ["keys": "cmd+s"]), ToolExample("Press enter", arguments: ["keys": "enter"]),
                    ToolExample("Press the down arrow three times", arguments: ["keys": "down", "times": 3]),
                    ToolExample("Pulsa comando mayús s", language: .es, arguments: ["keys": "cmd+shift+s"]),
                    ToolExample("Pulsa escape", language: .es, arguments: ["keys": "esc"]),
                ]),
            tool(
                Self.menu, "Use a menu command", "Runs a menu bar command by path, e.g. File > Save As…, in the front app or a given app.",
                [
                    .string("path", "Menu path separated by >, e.g. File > Export As > PDF.", maxLength: 300),
                    .strings("items", "Menu path as a list, e.g. [\"File\", \"Save As…\"].", maxItems: 8, maxLength: 100),
                    .string("app", "App whose menu to use (default: the front app).", maxLength: 200),
                ], constraints: [.atLeastOne(["path", "items"])], safety: .modifying,
                examples: [
                    ToolExample("Use File > Save As in TextEdit", arguments: ["app": "TextEdit", "path": "File > Save As…"]),
                    ToolExample("Open the View menu and choose Show Tab Bar", arguments: ["items": ["View", "Show Tab Bar"]]),
                    ToolExample("Usa Archivo > Guardar como en TextEdit", language: .es, arguments: ["app": "TextEdit", "path": "Archivo > Guardar como…"]),
                    ToolExample("Elige Visualización > Mostrar barra de pestañas", language: .es, arguments: ["items": ["Visualización", "Mostrar barra de pestañas"]]),
                ]),
            tool(
                Self.selectedText, "Read the selected text", "Returns the text selected in the front app (never from password fields).",
                [.boolean("allow_clipboard_fallback", "Borrow the clipboard (copy, read, restore) when Accessibility exposes no selection.", default: false)],
                safety: .readOnly,
                examples: [
                    ToolExample("What text do I have selected?", arguments: [:]), ToolExample("Read my selection, use the clipboard if needed", arguments: ["allow_clipboard_fallback": true]),
                    ToolExample("¿Qué texto tengo seleccionado?", language: .es, arguments: [:]),
                ]),
            tool(
                Self.screenshot, "Take a screenshot", "Captures a display or a window as a private JPEG (needs Screen Recording); optionally recognises its text.",
                [
                    .integer("display", "Display index (default 0, the main display).", min: 0, max: 16), .integer("window_id", "Capture only this window.", min: 1),
                    .boolean("include_ocr", "Also return the recognised text lines.", default: false),
                    .integer("max_width", "Maximum image width in pixels.", min: 200, max: 8000, default: 1600),
                ], safety: .readOnly, timeout: 30,
                examples: [
                    ToolExample("Take a screenshot", arguments: [:]), ToolExample("Screenshot the second display and read its text", arguments: ["display": 1, "include_ocr": true]),
                    ToolExample("Haz una captura de pantalla", language: .es, arguments: [:]),
                    ToolExample("Captura la segunda pantalla y lee su texto", language: .es, arguments: ["display": 1, "include_ocr": true]),
                ]),
            tool(
                Self.describeScreen, "Describe the screen",
                "What is on screen: front app, window, the controls (Accessibility) and, when needed, OCR of a screenshot. Also returns the screenshot path.",
                [.integer("display", "Display index for the screenshot (default 0).", min: 0, max: 16), .integer("max_lines", "Maximum lines of UI description.", min: 10, max: 1000, default: 150)],
                safety: .readOnly, timeout: 40,
                examples: [
                    ToolExample("What is on my screen?", arguments: [:]), ToolExample("Describe what I'm looking at", arguments: [:]),
                    ToolExample("¿Qué hay en mi pantalla?", language: .es, arguments: [:]), ToolExample("Describe lo que estoy viendo", language: .es, arguments: [:]),
                ]),
            tool(
                Self.lockScreen, "Lock the screen", "Locks the screen (login window) and verifies the session left the console.", safety: .modifying,
                examples: [
                    ToolExample("Lock my screen", arguments: [:]), ToolExample("Lock the computer", arguments: [:]),
                    ToolExample("Bloquea la pantalla", language: .es, arguments: [:]), ToolExample("Bloquea el ordenador", language: .es, arguments: [:]),
                ]),
            tool(
                Self.setAppearance, "Light or dark mode", "Switches macOS between light and dark appearance (System Events; needs Automation consent) and reads it back.",
                [.choice("mode", ["dark", "light", "toggle"], "The appearance to set.", required: true)], safety: .modifying,
                examples: [
                    ToolExample("Turn on dark mode", arguments: ["mode": "dark"]), ToolExample("Switch to light mode", arguments: ["mode": "light"]),
                    ToolExample("Toggle dark mode", arguments: ["mode": "toggle"]),
                    ToolExample("Activa el modo oscuro", language: .es, arguments: ["mode": "dark"]), ToolExample("Pon el modo claro", language: .es, arguments: ["mode": "light"]),
                ]),
            tool(
                Self.scroll, "Scroll", "Scrolls a scroll area (by element id) or the front window's main one, by pages, and verifies the content moved.",
                [
                    .string("element_id", "Element id of the scroll area or something inside it.", maxLength: 20),
                    .string("app", "App whose window to scroll (default: the front app).", maxLength: 200),
                    .choice("direction", ScrollDirection.allCases.map(\.rawValue), "Direction.", required: true),
                    .number("amount", "Pages to scroll (0.1–20).", min: 0.1, max: 20, default: 1),
                ], safety: .modifying, timeout: 30,
                examples: [
                    ToolExample("Scroll down", arguments: ["direction": "down"]), ToolExample("Scroll up two pages in Safari", arguments: ["app": "Safari", "direction": "up", "amount": 2]),
                    ToolExample("Desplázate hacia abajo", language: .es, arguments: ["direction": "down"]),
                    ToolExample("Sube dos páginas en Safari", language: .es, arguments: ["app": "Safari", "direction": "up", "amount": 2]),
                ]),
        ]
    }

    // MARK: Permissions

    /// The permission one tool depends on, if any.
    public func requirement(for tool: ToolDescriptor) -> PermissionRequirement? {
        switch tool.name {
        case Self.screenshot, Self.describeScreen: return ComputerPermissions.screenRecording
        case Self.setAppearance: return ComputerPermissions.systemEventsAutomation
        case Self.frontmost, Self.windowsTool, Self.displays, Self.focusApp, Self.lockScreen: return nil
        default: return ComputerPermissions.accessibility
        }
    }

    public func status() async -> IntegrationStatus {
        let entries = [
            IntegrationStatus.PermissionEntry(requirement: ComputerPermissions.accessibility, state: state(for: ComputerPermissions.accessibility)),
            IntegrationStatus.PermissionEntry(requirement: ComputerPermissions.screenRecording, state: state(for: ComputerPermissions.screenRecording)),
        ]
        let missing = entries.filter { !$0.state.isAuthorized }
        if missing.isEmpty { return IntegrationStatus(state: .ready, permissions: entries) }
        let denied = missing.contains { if case .denied = $0.state { return true } else { return false } }
        return IntegrationStatus(
            state: denied ? .denied : .needsPermission,
            detail: LocalizedText(
                en: "Grant " + missing.map(\.requirement.title.en).joined(separator: " and ") + " in System Settings › Privacy & Security.",
                es: "Concede " + missing.map(\.requirement.title.es).joined(separator: " y ") + " en Ajustes del Sistema › Privacidad y seguridad."),
            permissions: entries)
    }

    private func state(for requirement: PermissionRequirement) -> AuthorizationState {
        switch requirement.id {
        case ComputerPermissions.accessibility.id:
            if ComputerPermissions.accessibilityStatus() == .granted { return .authorized }
            return prompts.wasPrompted(requirement.id) ? .denied(requirement) : .notDetermined(requirement)
        case ComputerPermissions.screenRecording.id:
            if ComputerPermissions.screenRecordingStatus() == .granted { return .authorized }
            return prompts.wasPrompted(requirement.id) ? .denied(requirement) : .notDetermined(requirement)
        default:
            return .authorized
        }
    }

    public func authorization(for tool: ToolDescriptor) async -> AuthorizationState {
        guard let requirement = requirement(for: tool) else { return .authorized }
        if requirement.id == ComputerPermissions.systemEventsAutomation.id {
            switch await ComputerPermissions.automationStatus(bundleID: "com.apple.systemevents") {
            case .granted: return .authorized
            case .denied: return .denied(requirement)
            case .notDetermined, .targetNotRunning: return .notDetermined(requirement)
            }
        }
        return state(for: requirement)
    }

    public func requestAuthorization(for tool: ToolDescriptor) async -> AuthorizationState {
        guard let requirement = requirement(for: tool) else { return .authorized }
        switch requirement.id {
        case ComputerPermissions.accessibility.id:
            prompts.markPrompted(requirement.id)
            if ComputerPermissions.requestAccessibility() { return .authorized }
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(500))
                if ComputerPermissions.accessibilityStatus() == .granted { return .authorized }
            }
            return .denied(requirement)
        case ComputerPermissions.screenRecording.id:
            prompts.markPrompted(requirement.id)
            if ComputerPermissions.requestScreenRecording() { return .authorized }
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(500))
                if ComputerPermissions.screenRecordingStatus() == .granted { return .authorized }
            }
            return .denied(requirement)
        case ComputerPermissions.systemEventsAutomation.id:
            // Reading the appearance through osascript launches System Events and shows the consent dialog.
            _ = try? await ProcessSupport.runAppleScript(Self.appearanceScript, arguments: ["read"], timeout: 120)
            return await authorization(for: tool)
        default:
            return .authorized
        }
    }

    // MARK: Execution

    public func execute(_ call: ValidatedToolCall, context: ExecutionContext) async throws -> ToolOutcome {
        let language = context.language
        func t(_ english: String, _ spanish: String) -> String { language.pick(english, spanish) }
        switch call.descriptor.name {
        case Self.frontmost:
            let app = try await accessibility.frontmostApplication()
            let window = try? await accessibility.focusedWindow()
            var data: JSONObject = ["app": app.json]
            if let window { data["window"] = window.json }
            return .done(
                ToolOutput(
                    message: t("\(app.localizedName) is in front", "\(app.localizedName) está en primer plano") + (window.map { " · “\($0.title)”" } ?? "") + ".",
                    data: .object(data), verification: .notApplicable))

        case Self.windowsTool:
            var list = await windows.windows(onScreenOnly: call.bool("on_screen_only") ?? true)
            if let query = call.string("app") {
                let apps = try await resolveApps(query, context: context)
                if case .clarify(let clarification) = apps { return .clarify(clarification) }
                if case .one(let app) = apps { list = list.filter { $0.pid == app.pid } }
            }
            let lines = list.map { "#\($0.id) \($0.appName): “\($0.title)” \($0.frame)" + ($0.isMinimized ? t(" (minimised)", " (minimizada)") : "") }
            return .done(
                ToolOutput(
                    message: list.isEmpty ? t("No windows found.", "No se encontraron ventanas.") : t("\(list.count) windows:\n", "\(list.count) ventanas:\n") + lines.joined(separator: "\n"),
                    data: ["windows": .array(list.map(\.json))], verification: .notApplicable))

        case Self.displays:
            let list = await windows.displays()
            let lines = list.map { "\($0.index): \($0.name) \($0.frame)" + ($0.isMain ? t(" (main)", " (principal)") : "") }
            return .done(
                ToolOutput(message: t("\(list.count) displays:\n", "\(list.count) pantallas:\n") + lines.joined(separator: "\n"), data: ["displays": .array(list.map(\.json))], verification: .notApplicable))

        case Self.focusApp:
            let query = call.string("app") ?? ""
            let resolved = try await resolveApps(query, context: context)
            guard case .one(let app) = resolved else {
                if case .clarify(let clarification) = resolved { return .clarify(clarification) }
                throw JarvisError.notFound("app_not_running", en: "No running app matches “\(query)”.", es: "Ninguna app en ejecución coincide con «\(query)».")
            }
            guard await windows.activate(pid: app.pid) else {
                throw JarvisError.verificationFailed(LocalizedText(en: "\(app.localizedName) did not come to the front.", es: "\(app.localizedName) no pasó al frente."))
            }
            return .done(ToolOutput(message: t("\(app.localizedName) is now in front.", "\(app.localizedName) está ahora en primer plano."), data: app.json, verification: .verified(t("Frontmost application read back from macOS.", "Aplicación en primer plano comprobada en macOS."))))

        case Self.focusWindow:
            let resolved = try await resolveWindow(call, context: context)
            guard case .one(let window) = resolved else { return resolved.outcome }
            let focused = try await windows.focusWindow(id: window.id)
            return .done(ToolOutput(message: t("Focused “\(focused.title)” of \(focused.appName).", "Ventana «\(focused.title)» de \(focused.appName) activada."), data: focused.json, verification: .verified(t("Focused window read back.", "Ventana activa comprobada."))))

        case Self.arrangeWindow:
            guard let preset = call.string("preset").flatMap(WindowPreset.init(name:)) else {
                throw JarvisError.invalidArgument(parameter: "preset", LocalizedText(en: "Unknown preset.", es: "Disposición desconocida."))
            }
            let resolved = try await resolveWindow(call, context: context)
            guard case .one(let window) = resolved else { return resolved.outcome }
            let change = try await windows.arrange(windowID: window.id, preset: preset, display: call.int("display"))
            return .done(frameOutput(change, context: context, what: preset.rawValue.replacingOccurrences(of: "_", with: " ")))

        case Self.setWindowFrame:
            let resolved = try await resolveWindow(call, context: context)
            guard case .one(let window) = resolved else { return resolved.outcome }
            let frame = CGRect(x: call.double("x") ?? 0, y: call.double("y") ?? 0, width: call.double("width") ?? 0, height: call.double("height") ?? 0)
            let change = try await windows.setFrame(windowID: window.id, frame: frame)
            return .done(frameOutput(change, context: context, what: ScreenRect(frame).description))

        case Self.minimizeWindow:
            let resolved = try await resolveWindow(call, context: context)
            guard case .one(let window) = resolved else { return resolved.outcome }
            let minimized = try await windows.minimize(windowID: window.id)
            return .done(ToolOutput(message: t("Minimised “\(minimized.title)”.", "Ventana «\(minimized.title)» minimizada."), data: minimized.json, verification: .verified(t("AXMinimized read back as true.", "AXMinimized comprobado como verdadero."))))

        case Self.closeWindow:
            let resolved = try await resolveWindow(call, context: context)
            guard case .one(let window) = resolved else { return resolved.outcome }
            guard context.isConfirmed else {
                return .confirm(
                    ConfirmationRequest(
                        prompt: t("Close the window “\(window.title)” of \(window.appName)? Unsaved changes may be lost.", "¿Cerrar la ventana «\(window.title)» de \(window.appName)? Se pueden perder cambios sin guardar."),
                        call: call.call.adding(["window_id": .int(Int(window.id))]), destructive: true))
            }
            let gone = try await windows.closeWindow(windowID: window.id)
            return .done(
                ToolOutput(
                    message: gone ? t("Closed “\(window.title)”.", "Ventana «\(window.title)» cerrada.") : t("The close button was pressed but “\(window.title)” is still open; it may be asking whether to save.", "Se pulsó cerrar pero «\(window.title)» sigue abierta; puede estar preguntando si guardar."),
                    data: window.json,
                    verification: gone ? .verified(t("The window is gone from the window list.", "La ventana ya no aparece en la lista de ventanas.")) : .unverified(t("The window still exists.", "La ventana todavía existe."))))

        case Self.uiElements:
            let scope = try await captureScope(call, context: context)
            guard case .scope(let captureScope) = scope else { return scope.outcome }
            let tree = try await accessibility.capture(scope: captureScope, maxElements: call.int("max_elements") ?? 400)
            let maxLines = call.int("max_lines") ?? 120
            var data: JSONObject = ["description": .string(tree.describe(maxLines: maxLines)), "ui": tree.json]
            var message = tree.describe(maxLines: maxLines)
            if let query = call.string("query") {
                let matches = tree.find(query)
                data["matches"] = .array(matches.map(\.json))
                message = matches.isEmpty
                    ? t("Nothing matches “\(query)”.\n", "Nada coincide con «\(query)».\n") + message
                    : t("Matches for “\(query)”:\n", "Coincidencias para «\(query)»:\n") + matches.map(\.line).joined(separator: "\n") + "\n\n" + message
            }
            return .done(ToolOutput(message: message, data: .object(data), verification: .notApplicable))

        case Self.click:
            let (tree, element) = try await resolveElement(call, context: context)
            guard let element else { return tree.outcome }
            guard case .tree(let captured) = tree else { return tree.outcome }
            if !context.isConfirmed, Safety.riskyLabel(element.label, context: captured.contextText) {
                return .confirm(
                    ConfirmationRequest(
                        prompt: t("Click “\(element.label)” in \(captured.app.localizedName)?", "¿Hacer clic en «\(element.label)» en \(captured.app.localizedName)?"),
                        call: call.call.adding(["element_id": .string(element.id)]), destructive: Safety.matches(element.label, Safety.riskyPattern)))
            }
            let action = call.string("action") ?? "press"
            let report: ActionReport
            if action == "press" {
                report = try await accessibility.click(elementID: element.id, in: captured)
            } else {
                let name = ["pick": "AXPick", "open": "AXOpen", "confirm": "AXConfirm", "show_menu": "AXShowMenu"][action] ?? "AXPress"
                report = try await accessibility.perform(action: name, on: element.id, in: captured)
            }
            return .done(actionOutput(report, context: context, verb: t("Clicked", "Clic en")))

        case Self.typeText:
            let text = call.string("text") ?? ""
            if let elementID = call.string("element_id") {
                guard let tree = await accessibility.lastCapture(), tree.element(elementID) != nil else {
                    throw JarvisError.notFound("element_not_found", en: "No element \(elementID) in the last screen reading; run computer.ui_elements first.", es: "No hay ningún elemento \(elementID) en la última lectura; ejecuta computer.ui_elements primero.")
                }
                let report = try await accessibility.setValue(elementID: elementID, text: text, in: tree)
                return .done(actionOutput(report, context: context, verb: t("Filled", "Rellenado")))
            }
            var pid: Int32?
            if let query = call.string("app") {
                let resolved = try await resolveApps(query, context: context)
                guard case .one(let app) = resolved else { return resolved.outcome }
                pid = app.pid
            }
            let report = try await accessibility.typeText(text, pid: pid)
            let target = report.targetLabel.map { $0.isEmpty ? (report.targetRole.map(UIElementSnapshot.roleName) ?? "") : $0 } ?? ""
            return .done(
                ToolOutput(
                    message: t("Typed \(report.characters) characters", "Escritos \(report.characters) caracteres") + (target.isEmpty ? "." : t(" into “\(target)”.", " en «\(target)».")),
                    data: ["characters": .int(report.characters), "method": .string(report.method), "target": .string(target)],
                    verification: report.verified ? .verified(t("The field's value contains the text.", "El valor del campo contiene el texto.")) : .unverified(t("Keystrokes were sent; the field could not be read back.", "Se enviaron las pulsaciones; no se pudo leer el campo."))))

        case Self.pressKeys:
            let keys = call.string("keys") ?? ""
            let shortcut: KeyboardShortcut
            do {
                shortcut = try KeyboardShortcut.parse(keys)
            } catch {
                throw JarvisError.invalidArgument(parameter: "keys", LocalizedText(en: "Unrecognised shortcut “\(keys)”: \(error).", es: "Atajo no reconocido «\(keys)»: \(error)."))
            }
            if shortcut.isRisky, !context.isConfirmed {
                return .confirm(ConfirmationRequest(prompt: t("Press \(shortcut)? It may quit, close or delete something.", "¿Pulsar \(shortcut)? Puede cerrar, salir o borrar algo."), call: call.call, destructive: true))
            }
            if let query = call.string("app") {
                let resolved = try await resolveApps(query, context: context)
                guard case .one(let app) = resolved else { return resolved.outcome }
                guard await windows.activate(pid: app.pid) else {
                    throw JarvisError.failed("activate_failed", en: "Could not bring \(app.localizedName) to the front.", es: "No se pudo traer \(app.localizedName) al frente.")
                }
            }
            let before = try? await accessibility.capture(scope: .frontmostWindow, maxElements: 200)
            let times = call.int("times") ?? 1
            try await accessibility.pressKeys(keys, times: times)
            try? await Task.sleep(for: .milliseconds(200))
            let after = try? await accessibility.capture(scope: .frontmostWindow, maxElements: 200)
            var changes: [String] = []
            if let before, let after { changes = await accessibility.diff(before, after) }
            let changed = !changes.isEmpty && changes != ["nothing visibly changed"]
            return .done(
                ToolOutput(
                    message: t("Pressed \(shortcut)", "Pulsado \(shortcut)") + (times > 1 ? " ×\(times)" : "") + (changed ? ". " + changes.joined(separator: "; ") : "."),
                    data: ["keys": .string(shortcut.description), "times": .int(times), "changes": .array(changes.map(JSONValue.string))],
                    verification: changed ? .verified(t("The screen changed after the key press.", "La pantalla cambió tras la pulsación.")) : .unverified(t("The key events were posted; no visible change was read back.", "Se enviaron las teclas; no se leyó ningún cambio visible."))))

        case Self.menu:
            var items = call.strings("items")
            if items.isEmpty, let path = call.string("path") {
                items = path.components(separatedBy: CharacterSet(charactersIn: ">›→")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
            guard items.count >= 2 else {
                throw JarvisError.invalidArgument(parameter: "path", LocalizedText(en: "Give the menu and the item, e.g. File > Save As…", es: "Indica el menú y el elemento, p. ej. Archivo > Guardar como…"))
            }
            if !context.isConfirmed, let last = items.last, Safety.riskyLabel(last) {
                return .confirm(ConfirmationRequest(prompt: t("Run the menu command \(items.joined(separator: " > "))?", "¿Ejecutar el comando de menú \(items.joined(separator: " > "))?"), call: call.call, destructive: true))
            }
            var pid: Int32?
            if let query = call.string("app") {
                let resolved = try await resolveApps(query, context: context)
                guard case .one(let app) = resolved else { return resolved.outcome }
                pid = app.pid
            }
            let report = try await accessibility.menuAction(path: items, pid: pid)
            let path = report.path.joined(separator: " > ")
            return .done(
                ToolOutput(
                    message: report.pressed ? t("Ran \(path).", "Ejecutado \(path).") : t("Could not press \(path).", "No se pudo pulsar \(path)."),
                    data: ["path": .array(report.path.map(JSONValue.string)), "pressed": .bool(report.pressed), "menu_closed": .bool(report.menuClosed)],
                    verification: report.pressed && report.menuClosed ? .verified(t("The menu item was pressed and the menu closed.", "El elemento se pulsó y el menú se cerró.")) : .unverified(t("The menu did not close as expected.", "El menú no se cerró como se esperaba."))))

        case Self.selectedText:
            let allow = call.bool("allow_clipboard_fallback") ?? false
            let previous = await accessibility.allowPasteboardFallback
            await accessibility.setAllowPasteboardFallback(allow)
            defer { Task { await accessibility.setAllowPasteboardFallback(previous) } }
            let text = try await accessibility.selectedText()
            return .done(
                ToolOutput(
                    message: text.map { t("Selected text: ", "Texto seleccionado: ") + $0 } ?? t("Nothing is selected (or the app does not expose its selection).", "No hay nada seleccionado (o la app no expone la selección)."),
                    data: ["text": JSONValue(text)], verification: .notApplicable))

        case Self.screenshot:
            let image = try await screen.screenshot(display: call.int("display"), window: call.int("window_id").map(UInt32.init), maxWidth: call.int("max_width") ?? 1_600)
            let url = try await screen.saveJPEG(image)
            var data: JSONObject = [
                "path": .string(url.path), "width": .int(image.width), "height": .int(image.height), "scale": .double(image.scale), "area": image.origin.json,
                "display": JSONValue(image.displayIndex), "window_id": JSONValue(image.windowID.map(Int.init)),
            ]
            var message = t("Screenshot saved to \(url.path) (\(image.width)×\(image.height)).", "Captura guardada en \(url.path) (\(image.width)×\(image.height)).")
            if call.bool("include_ocr") == true {
                let lines = try await screen.ocr(image)
                data["ocr_lines"] = .array(lines.map(\.json))
                message += "\n" + t("Text on screen:\n", "Texto en pantalla:\n") + lines.map(\.text).joined(separator: "\n")
            }
            return .done(ToolOutput(message: message, data: .object(data.droppingNulls()), verification: .notApplicable))

        case Self.describeScreen:
            let description = try await screen.describe(display: call.int("display"), maxLines: call.int("max_lines") ?? 150)
            return .done(ToolOutput(message: description.text, data: description.json, verification: .notApplicable, warnings: description.notes))

        case Self.lockScreen:
            return .done(try await lockScreen(context: context))

        case Self.setAppearance:
            return .done(try await setAppearance(call.string("mode") ?? "toggle", context: context))

        case Self.scroll:
            guard let direction = call.string("direction").flatMap(ScrollDirection.init(name:)) else {
                throw JarvisError.invalidArgument(parameter: "direction", LocalizedText(en: "Direction must be up, down, left or right.", es: "La dirección debe ser up, down, left o right."))
            }
            let amount = call.double("amount") ?? 1
            let tree: UITree
            if let elementID = call.string("element_id") {
                guard let last = await accessibility.lastCapture(), last.element(elementID) != nil else {
                    throw JarvisError.notFound("element_not_found", en: "No element \(elementID) in the last screen reading; run computer.ui_elements first.", es: "No hay ningún elemento \(elementID) en la última lectura; ejecuta computer.ui_elements primero.")
                }
                tree = last
                let report = try await accessibility.scroll(elementID: elementID, direction: direction, amount: amount, in: tree)
                return .done(actionOutput(report, context: context, verb: t("Scrolled", "Desplazado")))
            }
            let scope = try await captureScope(call, context: context)
            guard case .scope(let captureScope) = scope else { return scope.outcome }
            tree = try await accessibility.capture(scope: captureScope, maxElements: 300)
            let report = try await accessibility.scroll(elementID: nil, direction: direction, amount: amount, in: tree)
            return .done(actionOutput(report, context: context, verb: t("Scrolled", "Desplazado")))

        default:
            throw JarvisError.unsupported(LocalizedText(en: "Unknown computer tool.", es: "Herramienta de ordenador desconocida."), alternative: nil)
        }
    }

    // MARK: Resolution helpers

    enum AppResolution {
        case none
        case one(AppInfo)
        case clarify(Clarification)

        var outcome: ToolOutcome {
            if case .clarify(let clarification) = self { return .clarify(clarification) }
            return .clarify(Clarification(question: "Which application?"))
        }
    }

    private func resolveApps(_ query: String, context: ExecutionContext) async throws -> AppResolution {
        let matches = await windows.findApps(query)
        guard let first = matches.first else {
            throw JarvisError.notFound("app_not_running", en: "No running app matches “\(query)”.", es: "Ninguna app en ejecución coincide con «\(query)».")
        }
        if matches.count == 1 { return .one(first) }
        return .clarify(
            Clarification(
                question: context.t("Which application?", "¿Qué aplicación?"),
                options: matches.map { ClarificationOption(label: $0.localizedName, detail: $0.bundleID, call: ToolCall(tool: "computer.focus_app", arguments: ["app": .string($0.bundleID ?? $0.localizedName)])) }))
    }

    enum WindowResolution {
        case one(WindowInfo)
        case clarify(Clarification)

        var outcome: ToolOutcome {
            if case .clarify(let clarification) = self { return .clarify(clarification) }
            return .clarify(Clarification(question: "Which window?"))
        }
    }

    private func resolveWindow(_ call: ValidatedToolCall, context: ExecutionContext) async throws -> WindowResolution {
        let all = await windows.windows(onScreenOnly: false)
        if let id = call.int("window_id") {
            var window = all.first { Int($0.id) == id }
            if window == nil { window = await windows.window(id: UInt32(max(0, id))) }
            guard let window else {
                throw JarvisError.notFound("window_not_found", en: "No window with id \(id).", es: "No hay ninguna ventana con id \(id).")
            }
            return .one(window)
        }
        var candidates = all
        if let query = call.string("app") {
            let resolved = try await resolveApps(query, context: context)
            guard case .one(let app) = resolved else {
                if case .clarify(let clarification) = resolved { return .clarify(clarification) }
                throw JarvisError.notFound("app_not_running", en: "No running app matches “\(query)”.", es: "Ninguna app en ejecución coincide con «\(query)».")
            }
            candidates = candidates.filter { $0.pid == app.pid }
            guard !candidates.isEmpty else {
                throw JarvisError.notFound("window_not_found", en: "\(app.localizedName) has no windows.", es: "\(app.localizedName) no tiene ventanas.")
            }
        }
        if let title = call.string("title") {
            let ranked = NameMatcher.rank(candidates, query: title, minimumScore: 50) { $0.title }
            guard let top = ranked.first?.score else {
                throw JarvisError.notFound("window_not_found", en: "No window titled “\(title)”.", es: "No hay ninguna ventana titulada «\(title)».")
            }
            let best = ranked.filter { $0.score == top }.map(\.item)
            if best.count == 1 { return .one(best[0]) }
            return .clarify(
                Clarification(
                    question: context.t("Which window?", "¿Qué ventana?"),
                    options: best.map { ClarificationOption(label: "\($0.appName): \($0.title)", detail: $0.frame.description, call: call.call.adding(["window_id": .int(Int($0.id))])) }))
        }
        if call.string("app") != nil {
            // The app's front window: on screen, not minimised, first in z-order.
            let visible = candidates.filter { $0.isOnScreen && !$0.isMinimized }
            if let window = visible.first ?? candidates.first { return .one(window) }
        }
        guard let focused = try await accessibility.focusedWindow(), focused.id != 0 else {
            throw JarvisError.notFound("window_not_found", en: "No window is focused; say which window.", es: "No hay ninguna ventana activa; indica cuál.")
        }
        return .one(focused)
    }

    enum ScopeResolution {
        case scope(CaptureScope)
        case clarify(Clarification)

        var outcome: ToolOutcome {
            if case .clarify(let clarification) = self { return .clarify(clarification) }
            return .clarify(Clarification(question: "Which application?"))
        }
    }

    private func captureScope(_ call: ValidatedToolCall, context: ExecutionContext) async throws -> ScopeResolution {
        let scope = call.string("scope") ?? "frontmost"
        if scope == "focused" { return .scope(.focusedElement) }
        if let query = call.string("app") {
            let resolved = try await resolveApps(query, context: context)
            guard case .one(let app) = resolved else {
                if case .clarify(let clarification) = resolved { return .clarify(clarification) }
                throw JarvisError.notFound("app_not_running", en: "No running app matches “\(query)”.", es: "Ninguna app en ejecución coincide con «\(query)».")
            }
            return .scope(.application(pid: app.pid))
        }
        return .scope(.frontmostWindow)
    }

    enum TreeResolution {
        case tree(UITree)
        case clarify(Clarification)

        var outcome: ToolOutcome {
            if case .clarify(let clarification) = self { return .clarify(clarification) }
            return .clarify(Clarification(question: "Which element?"))
        }
    }

    /// The tree and element a click refers to: by id in the last capture, or by label in a fresh capture.
    private func resolveElement(_ call: ValidatedToolCall, context: ExecutionContext) async throws -> (TreeResolution, UIElementSnapshot?) {
        if let elementID = call.string("element_id") {
            guard let tree = await accessibility.lastCapture(), let element = tree.element(elementID) ?? tree.element(elementID.lowercased()) else {
                throw JarvisError.notFound(
                    "element_not_found", en: "No element \(elementID) in the last screen reading; run computer.ui_elements first.",
                    es: "No hay ningún elemento \(elementID) en la última lectura; ejecuta computer.ui_elements primero.")
            }
            return (.tree(tree), element)
        }
        let label = call.string("label") ?? ""
        let scope = try await captureScope(call, context: context)
        guard case .scope(let captureScope) = scope else {
            if case .clarify(let clarification) = scope { return (.clarify(clarification), nil) }
            return (.clarify(Clarification(question: "Which application?")), nil)
        }
        let tree = try await accessibility.capture(scope: captureScope, maxElements: 400)
        let matches = tree.find(label).filter { $0.isInteractive || !$0.actions.isEmpty }
        guard let best = matches.first else {
            throw JarvisError.notFound("element_not_found", en: "No control named “\(label)” is visible in \(tree.app.localizedName).", es: "No hay ningún control llamado «\(label)» visible en \(tree.app.localizedName).")
        }
        let bestScore = ElementMatcher.score(query: label, element: best)
        let tied = matches.filter { ElementMatcher.score(query: label, element: $0) == bestScore && Safety.normalized($0.label) != Safety.normalized(best.label) }
        if !tied.isEmpty {
            return (
                .clarify(
                    Clarification(
                        question: context.t("Which control?", "¿Qué control?"),
                        options: ([best] + tied).prefix(6).map { ClarificationOption(label: "\($0.roleName) “\($0.label)”", detail: $0.frame.description, call: call.call.adding(["element_id": .string($0.id)])) })),
                nil
            )
        }
        return (.tree(tree), best)
    }

    // MARK: Output helpers

    private func actionOutput(_ report: ActionReport, context: ExecutionContext, verb: String) -> ToolOutput {
        let subject = report.label.isEmpty ? UIElementSnapshot.roleName(report.role) : "“\(report.label)”"
        var message = "\(verb) \(subject)"
        if report.changes.isEmpty == false { message += ". " + report.changes.joined(separator: "; ") }
        message += "."
        return ToolOutput(
            message: message, data: report.json,
            verification: report.verified
                ? .verified(context.t("Read back from the screen.", "Comprobado en pantalla."))
                : .unverified(context.t("The action ran but no effect could be read back.", "La acción se ejecutó pero no se pudo comprobar ningún efecto.")))
    }

    private func frameOutput(_ change: WindowChange, context: ExecutionContext, what: String) -> ToolOutput {
        ToolOutput(
            message: change.matched
                ? context.t("“\(change.window.title)” is now \(what): \(change.actual).", "«\(change.window.title)» está ahora en \(what): \(change.actual).")
                : context.t("“\(change.window.title)” moved to \(change.actual), not exactly \(what) (the app limits its size).", "«\(change.window.title)» quedó en \(change.actual), no exactamente \(what) (la app limita su tamaño)."),
            data: change.json,
            verification: change.matched
                ? .verified(context.t("Window frame read back.", "Marco de la ventana comprobado."))
                : .unverified(context.t("The frame read back differs from the request.", "El marco leído difiere de lo pedido.")))
    }

    // MARK: Lock screen and appearance

    static let cgSessionPath = "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession"

    private func lockScreen(context: ExecutionContext) async throws -> ToolOutput {
        var method = "CGSession"
        if FileManager.default.isExecutableFile(atPath: Self.cgSessionPath) {
            let result = try await ProcessSupport.run(executable: Self.cgSessionPath, arguments: ["-suspend"], timeout: 10)
            if result.status != 0 { method = "pmset" }
        } else {
            method = "pmset"
        }
        if method == "pmset" {
            let result = try await ProcessSupport.run(executable: "/usr/bin/pmset", arguments: ["displaysleepnow"], timeout: 10)
            guard result.status == 0 else {
                throw JarvisError.failed("lock_failed", en: "Neither CGSession nor pmset could lock the screen.", es: "Ni CGSession ni pmset pudieron bloquear la pantalla.")
            }
        }
        var locked = false
        for _ in 0..<15 {
            try? await Task.sleep(for: .milliseconds(100))
            if let session = CGSessionCopyCurrentDictionary() as? [String: Any], let onConsole = session[kCGSessionOnConsoleKey as String] as? Bool, !onConsole {
                locked = true
                break
            }
            if method == "pmset", CGDisplayIsAsleep(CGMainDisplayID()) != 0 { locked = true; break }
        }
        return ToolOutput(
            message: context.t("Screen lock requested (\(method)).", "Bloqueo de pantalla solicitado (\(method))."), data: ["method": .string(method), "locked": .bool(locked)],
            verification: locked
                ? .verified(context.t("The session left the console.", "La sesión salió de la consola."))
                : .unverified(context.t("macOS accepted the request; the lock state could not be read back yet.", "macOS aceptó la solicitud; aún no se pudo leer el estado de bloqueo.")))
    }

    /// Fixed script: the mode travels as `argv`, never as script text.
    static let appearanceScript = """
        on run argv
        set m to item 1 of argv
        tell application "System Events"
        tell appearance preferences
        if m is "dark" then set dark mode to true
        if m is "light" then set dark mode to false
        if m is "toggle" then set dark mode to not dark mode
        return (dark mode as text)
        end tell
        end tell
        end run
        """

    private func setAppearance(_ mode: String, context: ExecutionContext) async throws -> ToolOutput {
        let before = try await runAppearance("read")
        let result = try await runAppearance(mode)
        let expected: Bool
        switch mode {
        case "dark": expected = true
        case "light": expected = false
        default: expected = !before
        }
        let readBack = try await runAppearance("read")
        guard readBack == expected, result == expected else {
            throw JarvisError.verificationFailed(LocalizedText(en: "The appearance did not change.", es: "La apariencia no cambió."))
        }
        return ToolOutput(
            message: readBack ? context.t("Dark mode is on.", "El modo oscuro está activado.") : context.t("Light mode is on.", "El modo claro está activado."),
            data: ["dark": .bool(readBack)], verification: .verified(context.t("Appearance read back from System Events.", "Apariencia comprobada en System Events.")))
    }

    private func runAppearance(_ mode: String) async throws -> Bool {
        let result: ProcessResult
        do {
            result = try await ProcessSupport.runAppleScript(Self.appearanceScript, arguments: [mode], timeout: 20)
        } catch ProcessFailure.timedOut {
            throw JarvisError.timedOut(seconds: 20)
        }
        guard result.status == 0 else {
            let code = ProcessSupport.appleScriptErrorCode(result.standardError)
            if code == -1743 || code == -1744 { throw JarvisError.permissionRequired(ComputerPermissions.systemEventsAutomation) }
            throw JarvisError.failed("appearance_failed", en: "System Events refused: \(result.standardError.trimmingCharacters(in: .whitespacesAndNewlines))", es: "System Events rechazó la orden: \(result.standardError.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }
}
