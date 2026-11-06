// Portions adapted from Atticus (https://github.com/SaarthurR/atticus-mac), MIT License, Copyright (c) 2026 SaarthurR.
// Hands logic adapts ideas from Plip (https://github.com/hussainn7/plip-oss), MIT License, Copyright (c) 2026 Hussain.
// See NOTICE-ATTICUS.md (`Hands.capture/at/menuItem/menu/scroll/contentMoved/typeText/sendKeys`, `frontMouse`,
// `frontWheel`, `borrowPasteboard`).
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import FridayCore

/// What happened after an element action: whether it ran, how, and what changed on screen afterwards.
public struct ActionReport: Sendable {
    public var elementID: String
    public var role: String
    public var label: String
    /// `AXPress`, `AXPick`, `mouse`, `AXValue`, `AXSelectedText`, `keystrokes`, `AXScrollDownByPage`, `scroll_wheel`…
    public var method: String
    public var performed: Bool
    /// Whether a read-back confirmed the intended effect (for presses: that the screen changed).
    public var verified: Bool
    /// What changed on screen, in both languages (the JSON data carries the English form).
    public var changes: [LocalizedText]
    public var after: UITree?

    public init(
        elementID: String, role: String, label: String, method: String, performed: Bool, verified: Bool, changes: [LocalizedText],
        after: UITree?
    ) {
        self.elementID = elementID
        self.role = role
        self.label = label
        self.method = method
        self.performed = performed
        self.verified = verified
        self.changes = changes
        self.after = after
    }

    public var json: JSONValue {
        var object: JSONObject = [
            "element_id": .string(elementID), "role": .string(UIElementSnapshot.roleName(role)), "label": .string(label),
            "method": .string(method), "performed": .bool(performed), "verified": .bool(verified),
            "changes": .array(changes.map { .string($0.en) }),
        ]
        if let after { object["focused"] = JSONValue(after.focusedID); object["window"] = JSONValue(after.window?.title) }
        return .object(object)
    }

    /// The change note that means "the screen looks the same".
    public static let nothingChanged = LocalizedText(en: "nothing visibly changed", es: "nada cambió visiblemente")
}

/// Result of typing text.
public struct TypeReport: Sendable, Hashable {
    /// `AXSelectedText`, `keystrokes`, `paste` or `none`.
    public var method: String
    public var characters: Int
    public var verified: Bool
    public var targetRole: String?
    public var targetLabel: String?
}

/// Thrown when text with line breaks cannot be inserted through Accessibility and the caller has not allowed the
/// keystroke/paste fallback: a synthesised line break can send a message or run a command, so the user decides.
public struct MultilineInsertionRefused: Error, Sendable, Hashable {
    public var app: AppInfo
    /// Label (or role name) of the element that would receive the text; empty when unknown.
    public var target: String
    public var lines: Int
}

/// Result of a menu command.
public struct MenuReport: Sendable, Hashable {
    /// The labels actually resolved (and pressed), e.g. `["File", "Save As…"]`.
    public var path: [String]
    public var pressed: Bool
    /// Whether the menu closed again after the press (the usual sign that the command ran).
    public var menuClosed: Bool
    /// `true` when the resolved item is risky and was not pressed because the caller did not allow risky items;
    /// `path` then names the item that needs confirmation.
    public var needsConfirmation = false
}

/// One menu bar item or menu item.
public struct MenuEntry: Sendable, Hashable, Codable {
    public var title: String
    public var enabled: Bool
    public var shortcut: String?
    public var children: [MenuEntry]

    public var json: JSONValue {
        var object: JSONObject = ["title": .string(title), "enabled": .bool(enabled)]
        if let shortcut { object["shortcut"] = .string(shortcut) }
        if !children.isEmpty { object["items"] = .array(children.map(\.json)) }
        return .object(object)
    }
}

public enum ScrollDirection: String, Sendable, Hashable, Codable, CaseIterable {
    case up, down, left, right

    public init?(name: String) {
        switch TextFolding.fold(name) {
        case "up", "arriba": self = .up
        case "down", "abajo": self = .down
        case "left", "izquierda": self = .left
        case "right", "derecha": self = .right
        default: return nil
        }
    }

    public var localizedName: LocalizedText {
        switch self {
        case .up: return LocalizedText(en: "up", es: "arriba")
        case .down: return LocalizedText(en: "down", es: "abajo")
        case .left: return LocalizedText(en: "left", es: "a la izquierda")
        case .right: return LocalizedText(en: "right", es: "a la derecha")
        }
    }
}

/// Reads and drives the user interface of running apps through macOS Accessibility and Quartz events.
///
/// All AX and CGEvent calls run on the actor's own serial queue; AppKit (`NSWorkspace`, `NSRunningApplication`,
/// `NSPasteboard`) is only touched on the main actor. Requires the Accessibility permission
/// (``ComputerPermissions/accessibility``); every entry point throws `JarvisError.permissionRequired` without it.
public actor AccessibilityService {
    private let executor = SerialQueueExecutor(label: "com.newportdiaz.friday.computer.accessibility")
    public nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }

    /// Whether ``selectedText()`` may borrow the pasteboard (save → ⌘C → read → restore) when AX exposes no selection.
    public private(set) var allowPasteboardFallback: Bool
    private var lastTree: UITree?

    public init(allowPasteboardFallback: Bool = false) {
        self.allowPasteboardFallback = allowPasteboardFallback
    }

    public func setAllowPasteboardFallback(_ allowed: Bool) { allowPasteboardFallback = allowed }

    /// The most recent capture; element ids in tool calls refer to it.
    public func lastCapture() -> UITree? { lastTree }

    // MARK: Applications and windows

    /// The app in front; when Friday itself is in front, the user's app behind it (see `Apps.frontmost()`).
    public func frontmostApplication() async throws -> AppInfo {
        guard let app = await Apps.frontmost() else {
            throw JarvisError.failed("no_frontmost_app", en: "No application is in front.", es: "No hay ninguna aplicación en primer plano.")
        }
        return app
    }

    /// The app that should receive keyboard input: the frontmost app, activated first when Friday's own window is
    /// currently in front so the keystrokes do not land in the assistant.
    private func frontmostForInput() async throws -> AppInfo {
        let app = try await frontmostApplication()
        if await Apps.isOwnProcessInFront() {
            guard await Apps.activate(pid: app.pid) else {
                throw JarvisError.failed("activate_failed", en: "Could not bring \(app.localizedName) to the front.", es: "No se pudo traer \(app.localizedName) al frente.")
            }
        }
        return app
    }

    /// The focused window of the frontmost application, or `nil` when it has none (or AX is not trusted).
    public func focusedWindow() async throws -> WindowInfo? {
        try requireTrust()
        let app = try await frontmostApplication()
        let application = AXElement.application(pid: app.pid)
        guard let window = AX.element(application, kAXFocusedWindowAttribute) ?? AX.element(application, kAXMainWindowAttribute) else {
            return nil
        }
        return await windowInfo(for: window, app: app)
    }

    func windowInfo(for window: AXElement, app: AppInfo) async -> WindowInfo {
        let frame = AX.frame(window)
        let id = CGWindows.windowNumber(pid: app.pid, frame: frame)
        let record = id.flatMap(CGWindows.record)
        let displays = await Displays.current()
        return WindowInfo(
            id: id ?? 0, pid: app.pid, appName: app.localizedName, bundleID: app.bundleID,
            title: Safety.mask(AX.title(window) ?? AX.name(window)), frame: ScreenRect(frame),
            isOnScreen: record?.isOnScreen ?? false, displayIndex: Displays.index(containing: frame, in: displays),
            isMinimized: AX.bool(window, kAXMinimizedAttribute) ?? false)
    }

    // MARK: Capture

    /// Reads the accessibility tree for `scope` into a ``UITree`` with stable ids, a flat map and a compact description.
    public func capture(scope: CaptureScope = .frontmostWindow, maxElements: Int = 400) async throws -> UITree {
        try requireTrust()
        let app: AppInfo
        switch scope {
        case .frontmostWindow, .focusedElement: app = try await frontmostApplication()
        case .application(let pid):
            guard let found = await Apps.info(pid: pid) else {
                throw JarvisError.notFound("app_not_running", en: "That application is not running.", es: "Esa aplicación no se está ejecutando.")
            }
            app = found
        }
        let tree = try captureTree(app: app, scope: scope, maxElements: max(20, min(maxElements, 2_000)))
        lastTree = tree
        return tree
    }

    /// Adapted from Atticus `Hands.capture`: breadth-first, budgeted, clipped to the window, content before chrome,
    /// web pages last, text fields not descended, secrets masked, duplicates dropped.
    private func captureTree(app: AppInfo, scope: CaptureScope, maxElements: Int) throws -> UITree {
        let application = AXElement.application(pid: app.pid)
        // Unsupported attributes are harmless; this asks apps with lazy accessibility to build their trees.
        AX.set(application, "AXManualAccessibility", kCFBooleanTrue)
        let start = Date()
        let rootElement: AXElement
        var windowRef: WindowRef?
        switch scope {
        case .focusedElement:
            guard let focused = AX.element(application, kAXFocusedUIElementAttribute) else {
                throw JarvisError.notFound("no_focused_element", en: "Nothing is focused in \(app.localizedName).", es: "No hay nada enfocado en \(app.localizedName).")
            }
            rootElement = focused
            if let window = AX.element(focused, kAXWindowAttribute) ?? AX.element(application, kAXFocusedWindowAttribute) {
                windowRef = windowReference(window, pid: app.pid)
            }
        case .frontmostWindow, .application:
            guard let window = try rootWindow(of: application, app: app) else {
                throw JarvisError.notFound("no_window", en: "\(app.localizedName) has no accessible window.", es: "\(app.localizedName) no tiene ninguna ventana accesible.")
            }
            rootElement = window
            windowRef = windowReference(window, pid: app.pid)
        }

        let focusedElement = AX.element(application, kAXFocusedUIElementAttribute)
        var elements: [String: UIElementSnapshot] = [:]
        var order: [String] = []
        var rootIDs: [String] = []
        var texts: [String] = []
        var focusedID: String?
        var truncated = false
        var visitedCount = 0
        var visited: Set<AXElement> = []
        typealias Item = (element: AXElement, path: [Int], clip: CGRect, parent: String?)
        var queue: [Item] = [(rootElement, [], .null, nil)]
        if scope != .focusedElement, let menuBar = AX.element(application, kAXMenuBarAttribute) {
            queue.append((menuBar, [-1], .null, nil))
        }
        var later: [Item] = []
        var deferring = true
        var cursor = 0
        let visitBudget = max(1_800, maxElements * 5)
        let deadline: TimeInterval = 1.5

        while true {
            if cursor == queue.count, deferring {
                deferring = false
                queue += later
            }
            guard cursor < queue.count else { break }
            guard cursor < visitBudget, Date().timeIntervalSince(start) < deadline, elements.count < maxElements else {
                truncated = true
                break
            }
            try Task.checkCancellation()
            let (item, path, clip, parent) = queue[cursor]
            cursor += 1
            if visited.contains(item) { continue }
            visited.insert(item)
            visitedCount += 1

            let role = AX.role(item)
            let bounds = AX.frame(item)
            let visible = clip.isNull ? bounds : bounds.intersection(clip)
            let isMenu = role.contains("Menu")
            let shown = isMenu || bounds.isEmpty || (!visible.isNull && visible.width >= 4 && visible.height >= 4)
            if !shown { continue }
            if role == "AXWebArea", deferring {
                later.append((item, path, clip, parent))
                visited.remove(item)
                continue
            }

            let label = AX.name(item)
            let secure = AX.isSecure(item) || Safety.secret(label)
            var value: String?
            if !secure, let raw = AX.string(item, kAXValueAttribute), !raw.isEmpty {
                value = String(Safety.mask(raw).prefix(400))
            }
            var url: String?
            if role == "AXWebArea", let page = AX.string(item, "AXURL"), page.hasPrefix("http") { url = Safety.mask(page) }
            var scrollPosition: Double?
            if role == "AXScrollArea", let bar = AX.element(item, kAXVerticalScrollBarAttribute) {
                scrollPosition = AX.number(bar, kAXValueAttribute)
            }
            let isFocused = focusedElement.map { $0 == item } ?? false

            if ["AXStaticText", "AXHeading"].contains(role) {
                let text = label.isEmpty ? (value ?? "") : label
                if !text.isEmpty, !texts.contains(text), texts.count < 60 { texts.append(text) }
            }

            var recordedID: String? = nil
            let isRoot = path.isEmpty || path == [-1]
            let container = UIElementSnapshot.containerRoles.contains(role)
            let record = isRoot || !(container && label.isEmpty) && !(role.isEmpty && label.isEmpty) && role != "AXApplication"
            if record {
                let frame = ScreenRect(isMenu ? bounds : (visible.isNull ? bounds : visible))
                let duplicate = !isRoot && !isFocused && elements.values.contains { $0.role == role && $0.label == label && $0.frame == frame && $0.value == value }
                if !duplicate {
                    let id = "e\(order.count + 1)"
                    let snapshot = UIElementSnapshot(
                        id: id, role: role, subrole: AX.subrole(item), label: label.isEmpty && isRoot ? UIElementSnapshot.roleName(role) : label,
                        value: value, frame: frame, actions: AX.actions(item), enabled: AX.isEnabled(item), focused: isFocused,
                        secure: secure, children: [], path: path, url: url, scrollPosition: scrollPosition)
                    elements[id] = snapshot
                    order.append(id)
                    if let parent { elements[parent]?.children.append(id) } else { rootIDs.append(id) }
                    if isFocused { focusedID = id }
                    recordedID = id
                }
            }
            let parentForChildren = recordedID ?? parent

            var childClip = clip
            if ["AXWindow", "AXSheet", "AXScrollArea", "AXWebArea", "AXDialog"].contains(role), !bounds.isEmpty {
                childClip = clip.isNull ? bounds : clip.intersection(bounds)
            }
            if AX.textFieldRoles.contains(role) { continue }
            if role == "AXMenuBarItem", AX.bool(item, kAXSelectedAttribute) != true { continue }
            let children = AX.children(item).enumerated()
            let ordered = children.sorted { lhs, rhs in
                func priority(_ child: AXElement) -> Int {
                    let childRole = AX.role(child)
                    if ["AXSplitGroup", "AXOutline", "AXTable", "AXScrollArea", "AXSheet"].contains(childRole) { return 0 }
                    if ["AXToolbar", "AXMenuBar", "AXMenu"].contains(childRole) { return 2 }
                    return 1
                }
                return priority(lhs.element) < priority(rhs.element)
            }
            for (index, child) in ordered { queue.append((child, path + [index], childClip, parentForChildren)) }
        }

        return UITree(
            app: app, window: windowRef, scope: scope, rootIDs: rootIDs, elements: elements, order: order, focusedID: focusedID,
            texts: texts, truncated: truncated, visited: visitedCount, capturedAt: Date())
    }

    private func windowReference(_ window: AXElement, pid: Int32) -> WindowRef {
        let frame = AX.frame(window)
        return WindowRef(
            id: CGWindows.windowNumber(pid: pid, frame: frame), title: Safety.mask(AX.title(window) ?? AX.name(window)),
            frame: ScreenRect(frame))
    }

    /// The window to read: focused, else main, else the first AX window, else the status-item menu of a menu-bar app.
    private func rootWindow(of application: AXElement, app: AppInfo) throws -> AXElement? {
        func isWindow(_ element: AXElement) -> Bool { ["AXWindow", "AXSheet", "AXDialog"].contains(AX.role(element)) }
        let candidates = [AX.element(application, kAXFocusedWindowAttribute), AX.element(application, kAXMainWindowAttribute)].compactMap { $0 }
            + AX.windows(of: application)
        if let window = candidates.first(where: isWindow) { return window }
        if let extras = AX.element(application, "AXExtrasMenuBar") { return extras }
        return nil
    }

    // MARK: Finding and resolving

    public func find(_ query: String, in tree: UITree) -> [UIElementSnapshot] { tree.find(query) }

    private func snapshot(_ elementID: String, in tree: UITree) throws -> UIElementSnapshot {
        guard let snapshot = tree.element(elementID) ?? tree.element(elementID.lowercased()) else {
            throw JarvisError.notFound(
                "element_not_found", en: "No element \(elementID) in the last capture; read the screen again.",
                es: "No hay ningún elemento \(elementID) en la última lectura; vuelve a leer la pantalla.")
        }
        return snapshot
    }

    /// Re-resolves a captured element to its live `AXUIElement` by walking the captured path, checking the app is
    /// still running and the role (and label) still match (adapted from Atticus `Hands.at`).
    private func live(_ snapshot: UIElementSnapshot, in tree: UITree) throws -> AXElement {
        guard Apps.isAlive(pid: tree.app.pid) else {
            throw JarvisError.notFound("app_closed", en: "\(tree.app.localizedName) is no longer running.", es: "\(tree.app.localizedName) ya no se está ejecutando.")
        }
        let application = AXElement.application(pid: tree.app.pid)
        var path = snapshot.path
        var current: AXElement
        if path.first == -1 {
            path.removeFirst()
            guard let menuBar = AX.element(application, kAXMenuBarAttribute) else { throw screenChanged() }
            current = menuBar
        } else {
            switch tree.scope {
            case .focusedElement:
                guard let focused = AX.element(application, kAXFocusedUIElementAttribute) else { throw screenChanged() }
                current = focused
            case .frontmostWindow, .application:
                var window = tree.window.flatMap { windowElement(matching: $0, in: application) }
                if window == nil { window = try rootWindow(of: application, app: tree.app) }
                guard let window else { throw screenChanged() }
                current = window
            }
        }
        for index in path {
            let children = AX.children(current)
            guard children.indices.contains(index) else { throw screenChanged() }
            current = children[index]
        }
        guard AX.role(current) == snapshot.role else { throw screenChanged() }
        let liveLabel = AX.name(current)
        if !snapshot.label.isEmpty, snapshot.label != UIElementSnapshot.roleName(snapshot.role), Safety.rank(liveLabel, snapshot.label) < 2 {
            throw screenChanged()
        }
        return current
    }

    private func screenChanged() -> JarvisError {
        JarvisError.failed(
            "screen_changed", en: "The screen changed since it was read; read it again and retry.",
            es: "La pantalla cambió desde la última lectura; vuelve a leerla e inténtalo de nuevo.")
    }

    /// The live AX window matching a captured window reference (frame within 2 pt, then title).
    func windowElement(matching ref: WindowRef, in application: AXElement) -> AXElement? {
        let candidates = [AX.element(application, kAXFocusedWindowAttribute), AX.element(application, kAXMainWindowAttribute)].compactMap { $0 }
            + AX.windows(of: application)
        if let byFrame = candidates.first(where: { ScreenRect(AX.frame($0)).matches(ref.frame) }) { return byFrame }
        if !ref.title.isEmpty, let byTitle = candidates.first(where: { Safety.mask(AX.title($0) ?? AX.name($0)) == ref.title }) { return byTitle }
        return nil
    }

    // MARK: Actions

    /// Performs `action` (default `AXPress`) on a captured element: re-resolves it, checks it is still there and visible,
    /// performs, then re-captures to report what changed.
    public func perform(action: String = "AXPress", on elementID: String, in tree: UITree) async throws -> ActionReport {
        try requireTrust()
        let snapshot = try snapshot(elementID, in: tree)
        let element = try live(snapshot, in: tree)
        try ensureVisible(element, snapshot: snapshot)
        let before = tree
        let performed = AX.perform(element, [action])
        guard performed else {
            throw JarvisError.failed(
                "action_unsupported", en: "\(snapshot.roleName) “\(snapshot.label)” does not support \(action).",
                es: "\(snapshot.roleName) «\(snapshot.label)» no admite \(action).")
        }
        return await report(snapshot: snapshot, method: action, before: before)
    }

    /// Clicks: `AXPress` (or pick/open/confirm) first, a real mouse click at the element's centre as the fallback.
    /// The fallback activates the app first and then checks that the point it is about to click still belongs to
    /// that app's window (a floating panel, a notification banner or Spotlight on top would receive the click).
    public func click(elementID: String, in tree: UITree) async throws -> ActionReport {
        try requireTrust()
        let snapshot = try snapshot(elementID, in: tree)
        let element = try live(snapshot, in: tree)
        try ensureVisible(element, snapshot: snapshot)
        if AX.perform(element, ["AXPress", "AXPick", "AXOpen", "AXConfirm", "AXShowMenu"]) {
            let method = AX.actions(element).first { ["AXPress", "AXPick", "AXOpen", "AXConfirm", "AXShowMenu"].contains($0) } ?? "AXPress"
            return await report(snapshot: snapshot, method: method, before: tree)
        }
        guard await Apps.activate(pid: tree.app.pid) else {
            throw JarvisError.failed("activate_failed", en: "Could not bring the app to the front to click.", es: "No se pudo traer la app al frente para hacer clic.")
        }
        let frame = AX.visibleFrame(element)
        guard !frame.isNull, frame.width >= 1, frame.height >= 1 else { throw screenChanged() }
        let point = CGPoint(x: frame.midX, y: frame.midY)
        guard let top = CGWindows.topWindow(at: point), top.pid == tree.app.pid else {
            throw JarvisError.failed(
                "element_covered", en: "Something is covering “\(snapshot.label)”; move or close the window on top and try again.",
                es: "Algo tapa «\(snapshot.label)»; aparta o cierra la ventana que está encima e inténtalo de nuevo.")
        }
        try mouseClick(at: point)
        return await report(snapshot: snapshot, method: "mouse", before: tree)
    }

    /// Sets a text field's value (AXValue, then AXSelectedText after select-all, then keystrokes) and reads it back.
    /// Only editable elements are accepted: on anything else the keystroke fallback would select all and type into
    /// the app. Text with line breaks is only ever pasted (never typed with Return presses), and only when
    /// `allowMultilineFallback` is set, because a line break may send a message or run a command.
    public func setValue(elementID: String, text: String, in tree: UITree, allowMultilineFallback: Bool = false) async throws -> ActionReport {
        try requireTrust()
        let snapshot = try snapshot(elementID, in: tree)
        let element = try live(snapshot, in: tree)
        let role = AX.role(element)
        let isTextRole = snapshot.isTextField || AX.textFieldRoles.contains(role)
        let editable = isTextRole || AX.isSettable(element, kAXSelectedTextAttribute)
            || (AX.isSettable(element, kAXValueAttribute) && AX.stringValue(element) != nil)
        guard editable else {
            throw JarvisError.invalidArgument(
                parameter: "element_id",
                LocalizedText(
                    en: "\(snapshot.roleName) “\(snapshot.label)” is not a text field; pick a text field from computer.ui_elements or omit element_id to type into the focused field.",
                    es: "\(UIElementSnapshot.roleName(snapshot.role, language: .es)) «\(snapshot.label)» no es un campo de texto; elige un campo de texto de computer.ui_elements u omite element_id para escribir en el campo enfocado."))
        }
        let text = Self.normalizedLineBreaks(text)
        let secure = snapshot.secure || AX.isSecure(element)
        _ = await Apps.activate(pid: tree.app.pid)
        AX.set(element, kAXFocusedAttribute, kCFBooleanTrue)
        let focused = AX.fieldFocused(element, pid: tree.app.pid, wait: 0.5)
        func verified() -> Bool { !secure && AX.stringValue(element) == text }
        var method = "AXValue"
        if AX.isSettable(element, kAXValueAttribute), AX.set(element, kAXValueAttribute, text as CFString) == .success, secure || verified() {
            return finish(snapshot, method: method, verified: verified())
        }
        guard focused else {
            throw JarvisError.failed("focus_failed", en: "Could not focus “\(snapshot.label)”.", es: "No se pudo enfocar «\(snapshot.label)».")
        }
        let length = (AX.stringValue(element) ?? "").utf16.count
        AX.set(element, kAXSelectedTextRangeAttribute, range: CFRange(location: 0, length: length))
        method = "AXSelectedText"
        if AX.set(element, kAXSelectedTextAttribute, text as CFString) == .success, secure || verified() {
            return finish(snapshot, method: method, verified: verified())
        }
        guard isTextRole else {
            throw JarvisError.failed("value_not_settable", en: "“\(snapshot.label)” did not accept the text.", es: "«\(snapshot.label)» no aceptó el texto.")
        }
        // Ask before touching the field at all: a refused multi-line fill must not leave its contents selected.
        if text.contains("\n"), !allowMultilineFallback {
            throw MultilineInsertionRefused(app: tree.app, target: snapshot.label, lines: text.split(separator: "\n", omittingEmptySubsequences: false).count)
        }
        try postShortcut(KeyboardShortcut(key: "a", keyCode: 0, modifiers: [.command]))
        method = try await insertByKeyboard(text, app: tree.app, target: snapshot.label, allowMultiline: allowMultilineFallback)
        usleep(150_000)
        return finish(snapshot, method: method, verified: verified())
    }

    private func finish(_ snapshot: UIElementSnapshot, method: String, verified: Bool) -> ActionReport {
        ActionReport(
            elementID: snapshot.id, role: snapshot.role, label: snapshot.label, method: method, performed: true, verified: verified,
            changes: [verified ? LocalizedText(en: "value set", es: "valor establecido") : LocalizedText(en: "value could not be read back", es: "no se pudo releer el valor")],
            after: nil)
    }

    /// `\r\n` and `\r` become `\n` so every path sees one kind of line break.
    static func normalizedLineBreaks(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// Gives keyboard focus to an element and confirms it.
    public func focus(elementID: String, in tree: UITree) async throws -> ActionReport {
        try requireTrust()
        let snapshot = try snapshot(elementID, in: tree)
        let element = try live(snapshot, in: tree)
        _ = await Apps.activate(pid: tree.app.pid)
        AX.set(element, kAXFocusedAttribute, kCFBooleanTrue)
        let focused = AX.fieldFocused(element, pid: tree.app.pid, wait: 0.5)
        return ActionReport(
            elementID: snapshot.id, role: snapshot.role, label: snapshot.label, method: "AXFocused", performed: true, verified: focused,
            changes: [focused ? LocalizedText(en: "focused", es: "enfocado") : LocalizedText(en: "focus not confirmed", es: "foco no confirmado")], after: nil)
    }

    /// Scrolls a scroll area (the element, its enclosing scroll area, or the window's largest one when `elementID` is
    /// `nil`) by `amount` pages, trying AX scroll actions, the scroll bar, then a scroll-wheel event at the centre.
    public func scroll(elementID: String?, direction: ScrollDirection, amount: Double = 1, in tree: UITree) async throws -> ActionReport {
        try requireTrust()
        let pages = max(0.1, min(amount, 20))
        let area: AXElement
        let snapshot: UIElementSnapshot
        if let elementID {
            snapshot = try self.snapshot(elementID, in: tree)
            let element = try live(snapshot, in: tree)
            area = scrollArea(enclosing: element) ?? element
        } else {
            guard let found = largestScrollArea(in: tree) else {
                throw JarvisError.notFound("no_scroll_area", en: "Nothing scrollable was found.", es: "No se encontró nada que desplazar.")
            }
            snapshot = found.snapshot
            area = found.element
        }
        let vertical = direction == .up || direction == .down
        let bar = AX.element(area, vertical ? kAXVerticalScrollBarAttribute : kAXHorizontalScrollBarAttribute)
        let positive = direction == .down || direction == .right
        let valueBefore = bar.flatMap { AX.number($0, kAXValueAttribute) }
        if let valueBefore, abs(valueBefore - (positive ? 1 : 0)) < 0.001 {
            return ActionReport(
                elementID: snapshot.id, role: snapshot.role, label: snapshot.label, method: "none", performed: false, verified: true,
                changes: [LocalizedText(en: "already at the end", es: "ya está al final")], after: nil)
        }
        let frame = AX.visibleFrame(area)
        let fraction = min(1, pages)
        let steps = Int(ceil(pages))
        let actionName = "AXScroll\(direction.rawValue.capitalized)ByPage"
        var methods: [(String, () throws -> Bool)] = [
            (actionName, { fraction == 1 && AX.perform(area, [actionName]) }),
            (positive ? "AXIncrement" : "AXDecrement", { bar.map { AX.perform($0, [positive ? "AXIncrement" : "AXDecrement"]) } ?? false }),
            ("AXValue", {
                guard let bar, let value = AX.number(bar, kAXValueAttribute) else { return false }
                let target = max(0, min(1, value + (positive ? 0.15 : -0.15) * fraction))
                return AX.set(bar, kAXValueAttribute, NSNumber(value: target)) == .success
            }),
        ]
        if !frame.isNull, frame.width > 4, frame.height > 4 {
            let spot = CGPoint(x: frame.midX, y: frame.midY)
            let pid = tree.app.pid
            methods.append(("scroll_wheel", { try self.scrollWheel(direction, at: spot, pid: pid, fraction: fraction) }))
        }
        var performed = 0
        var method = "none"
        var textsBefore = Set(tree.texts)
        for _ in 0..<steps {
            try Task.checkCancellation()
            let before = bar.flatMap { AX.number($0, kAXValueAttribute) }
            var moved = false
            for (name, run) in methods {
                guard (try run()) else { continue }
                for poll in 0..<3 {
                    usleep(poll == 0 ? 40_000 : 80_000)
                    if let before, let now = bar.flatMap({ AX.number($0, kAXValueAttribute) }), abs(now - before) >= 0.001 { moved = true; break }
                    if before == nil, let after = try? captureTree(app: tree.app, scope: tree.scope, maxElements: 150), contentMoved(textsBefore, after) {
                        textsBefore = Set(after.texts)
                        moved = true
                        break
                    }
                }
                if moved { method = name; break }
            }
            guard moved else { break }
            performed += 1
        }
        let position = bar.flatMap { AX.number($0, kAXValueAttribute) }
        var changes: [LocalizedText] = []
        if performed > 0 {
            changes.append(
                LocalizedText(
                    en: "scrolled \(direction.localizedName.en) \(performed) step\(performed == 1 ? "" : "s")",
                    es: "desplazado \(direction.localizedName.es) \(performed) paso\(performed == 1 ? "" : "s")"))
        }
        if let position {
            let percent = Int((position * 100).rounded())
            changes.append(LocalizedText(en: "now at \(percent)%", es: "ahora al \(percent)%"))
        }
        if performed == 0 { changes.append(LocalizedText(en: "no movement detected", es: "no se detectó movimiento")) }
        let after = try? captureTree(app: tree.app, scope: tree.scope, maxElements: 400)
        if let after { lastTree = after }
        return ActionReport(
            elementID: snapshot.id, role: snapshot.role, label: snapshot.label, method: method, performed: performed > 0,
            verified: performed > 0, changes: changes, after: after)
    }

    private func scrollArea(enclosing element: AXElement) -> AXElement? {
        var current = element
        for _ in 0..<40 {
            if AX.role(current) == "AXScrollArea" { return current }
            guard let parent = AX.element(current, kAXParentAttribute) else { return nil }
            current = parent
        }
        return nil
    }

    private func largestScrollArea(in tree: UITree) -> (snapshot: UIElementSnapshot, element: AXElement)? {
        let areas = tree.ordered.filter { $0.role == "AXScrollArea" }.sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
        for area in areas {
            if let element = try? live(area, in: tree) { return (area, element) }
        }
        return nil
    }

    /// Adapted from Atticus `contentMoved`: at least three texts left and three arrived.
    private func contentMoved(_ before: Set<String>, _ after: UITree) -> Bool {
        let now = Set(after.texts)
        return before.subtracting(now).count >= 3 && now.subtracting(before).count >= 3
    }

    private func ensureVisible(_ element: AXElement, snapshot: UIElementSnapshot) throws {
        if snapshot.path.first == -1 { return }  // menus have no frame until open
        let frame = AX.visibleFrame(element)
        guard !frame.isNull, frame.width >= 1, frame.height >= 1 else {
            throw JarvisError.failed(
                "element_not_visible", en: "“\(snapshot.label)” is not visible; scroll to it first.",
                es: "«\(snapshot.label)» no está visible; desplázate hasta él primero.")
        }
    }

    private func report(snapshot: UIElementSnapshot, method: String, before: UITree) async -> ActionReport {
        usleep(150_000)
        let after = try? captureTree(app: before.app, scope: before.scope, maxElements: 400)
        if let after { lastTree = after }
        let changes = after.map { diff(before, $0) } ?? [LocalizedText(en: "could not re-read the screen", es: "no se pudo releer la pantalla")]
        return ActionReport(
            elementID: snapshot.id, role: snapshot.role, label: snapshot.label, method: method, performed: true,
            verified: after != nil && !changes.isEmpty && changes != [ActionReport.nothingChanged], changes: changes, after: after)
    }

    /// What differs between two captures, in a few short phrases (in both languages).
    func diff(_ before: UITree, _ after: UITree) -> [LocalizedText] {
        var changes: [LocalizedText] = []
        func named(_ element: UIElementSnapshot) -> LocalizedText {
            LocalizedText(en: "\(element.roleName) “\(element.label)”", es: "\(UIElementSnapshot.roleName(element.role, language: .es)) «\(element.label)»")
        }
        func list(_ elements: [UIElementSnapshot]) -> LocalizedText {
            let extra = elements.count > 5 ? " (+\(elements.count - 5))" : ""
            let shown = elements.prefix(5).map(named)
            return LocalizedText(en: shown.map(\.en).joined(separator: ", ") + extra, es: shown.map(\.es).joined(separator: ", ") + extra)
        }
        if before.window?.title != after.window?.title, let title = after.window?.title {
            changes.append(LocalizedText(en: "window is now “\(title)”", es: "la ventana ahora es «\(title)»"))
        }
        if before.app.pid != after.app.pid {
            changes.append(LocalizedText(en: "front app is now \(after.app.localizedName)", es: "la app en primer plano ahora es \(after.app.localizedName)"))
        }
        if before.focusedID != after.focusedID, let focused = after.focused {
            let target = focused.label.isEmpty
                ? LocalizedText(en: focused.roleName, es: UIElementSnapshot.roleName(focused.role, language: .es))
                : named(focused)
            changes.append(LocalizedText(en: "focus moved to \(target.en)", es: "el foco pasó a \(target.es)"))
        }
        let beforeKeys = Set(before.ordered.map { "\($0.role)|\($0.label)" })
        let afterKeys = Set(after.ordered.map { "\($0.role)|\($0.label)" })
        let appeared = after.ordered.filter { !beforeKeys.contains("\($0.role)|\($0.label)") && !$0.label.isEmpty }
        let vanished = before.ordered.filter { !afterKeys.contains("\($0.role)|\($0.label)") && !$0.label.isEmpty }
        if let sheet = appeared.first(where: { ["AXSheet", "AXDialog"].contains($0.role) }) {
            changes.append(LocalizedText(en: "a dialog opened: “\(sheet.label)”", es: "se abrió un diálogo: «\(sheet.label)»"))
        }
        if let menu = appeared.first(where: { $0.role == "AXMenu" }) {
            changes.append(LocalizedText(en: "a menu opened: “\(menu.label)”", es: "se abrió un menú: «\(menu.label)»"))
        }
        if !appeared.isEmpty {
            let items = list(appeared)
            changes.append(LocalizedText(en: "appeared: " + items.en, es: "apareció: " + items.es))
        }
        if !vanished.isEmpty {
            let items = list(vanished)
            changes.append(LocalizedText(en: "gone: " + items.en, es: "desapareció: " + items.es))
        }
        let newTexts = Set(after.texts).subtracting(before.texts)
        if changes.isEmpty, !newTexts.isEmpty {
            let joined = newTexts.prefix(3).joined(separator: " | ")
            changes.append(LocalizedText(en: "new text: " + joined, es: "texto nuevo: " + joined))
        }
        for (id, element) in before.elements {
            guard let same = after.elements[id], same.role == element.role, same.label == element.label, same.value != element.value, let value = same.value else { continue }
            let quoted = UIElementSnapshot.quote(String(value.prefix(60)))
            changes.append(LocalizedText(en: "“\(element.label)” is now \(quoted)", es: "«\(element.label)» ahora es \(quoted)"))
            if changes.count > 8 { break }
        }
        return changes.isEmpty ? [ActionReport.nothingChanged] : changes
    }

    // MARK: Text

    /// The selected text of the focused element (`AXSelectedText`, else the selected range of its value). Never reads
    /// secure fields. When AX exposes nothing and ``allowPasteboardFallback`` is on, borrows the pasteboard for one ⌘C.
    public func selectedText() async throws -> String? {
        try requireTrust()
        let app = try await frontmostApplication()
        let application = AXElement.application(pid: app.pid)
        guard let focused = AX.element(application, kAXFocusedUIElementAttribute) else { return nil }
        if AX.isSecure(focused) || Safety.secret(AX.name(focused)) {
            throw JarvisError.failed(
                "secure_field", en: "The focused field is a password field; Friday never reads those.",
                es: "El campo enfocado es una contraseña; Friday nunca lee esos campos.")
        }
        if let text = AX.string(focused, kAXSelectedTextAttribute), !text.isEmpty { return text }
        if let range = AX.selectedRange(focused), range.length > 0, let value = AX.stringValue(focused) {
            let utf16 = Array(value.utf16)
            if range.location >= 0, range.location + range.length <= utf16.count,
                let text = String(utf16CodeUnits: Array(utf16[range.location..<(range.location + range.length)]), count: range.length) as String?
            {
                return text
            }
        }
        guard allowPasteboardFallback else { return nil }
        return try await borrowPasteboardCopy(pid: app.pid)
    }

    /// Adapted from Atticus `borrowPasteboard`: saves every pasteboard item, sends ⌘C, reads the result and restores the
    /// user's items unless something else was copied meanwhile.
    private func borrowPasteboardCopy(pid: Int32) async throws -> String? {
        let saved = await Self.savePasteboard()
        try postShortcut(KeyboardShortcut(key: "c", keyCode: 8, modifiers: [.command]))
        var text: String?
        for _ in 0..<10 {
            usleep(50_000)
            let read = await MainActor.run { () -> (Int, String?) in (NSPasteboard.general.changeCount, NSPasteboard.general.string(forType: .string)) }
            if read.0 != saved.count { text = read.1; break }
        }
        await Self.restorePasteboard(saved.items)
        return text.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Inserts `text` through the pasteboard: the user's items are saved, the text is put on the pasteboard, ⌘V is
    /// posted, the app gets a moment to take it, and the user's items are restored. Pasting keeps line breaks as
    /// literal text in editors and chat composers, whereas a synthesised Return would send or run each line.
    private func pasteText(_ text: String) async throws {
        let saved = await Self.savePasteboard()
        await MainActor.run {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        do {
            try postShortcut(KeyboardShortcut(key: "v", keyCode: 9, modifiers: [.command]))
        } catch {
            await Self.restorePasteboard(saved.items)
            throw error
        }
        usleep(250_000)
        await Self.restorePasteboard(saved.items)
    }

    /// Every pasteboard item with its data, plus the change count, then clears the pasteboard.
    private static func savePasteboard() async -> (items: [[(NSPasteboard.PasteboardType, Data)]], count: Int) {
        await MainActor.run { () -> (items: [[(NSPasteboard.PasteboardType, Data)]], count: Int) in
            let pasteboard = NSPasteboard.general
            let items = pasteboard.pasteboardItems?.map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } } ?? []
            pasteboard.clearContents()
            return (items, pasteboard.changeCount)
        }
    }

    private static func restorePasteboard(_ items: [[(NSPasteboard.PasteboardType, Data)]]) async {
        await MainActor.run {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects(
                items.map { pairs in
                    let item = NSPasteboardItem()
                    for (type, data) in pairs { item.setData(data, forType: type) }
                    return item
                })
        }
    }

    /// Types `text` into the focused element: inserted through AX when a text field is focused, else as Unicode
    /// keystrokes in small chunks. Activates `pid` first when given (or the user's app when Friday is in front).
    /// Text with line breaks is inserted through AX or pasted, never typed with Return presses; the paste fallback
    /// runs only with `allowMultilineFallback`, otherwise ``MultilineInsertionRefused`` is thrown so the caller can ask.
    public func typeText(_ text: String, pid: Int32? = nil, allowMultilineFallback: Bool = false) async throws -> TypeReport {
        try requireTrust()
        let text = Self.normalizedLineBreaks(text)
        guard !text.isEmpty else { return TypeReport(method: "none", characters: 0, verified: true, targetRole: nil, targetLabel: nil) }
        let app: AppInfo
        if let pid {
            guard let info = await Apps.info(pid: pid) else {
                throw JarvisError.notFound("app_not_running", en: "That application is not running.", es: "Esa aplicación no se está ejecutando.")
            }
            app = info
            guard await Apps.activate(pid: pid) else {
                throw JarvisError.failed("activate_failed", en: "Could not bring \(app.localizedName) to the front.", es: "No se pudo traer \(app.localizedName) al frente.")
            }
        } else {
            app = try await frontmostForInput()
        }
        let application = AXElement.application(pid: app.pid)
        let focused = AX.element(application, kAXFocusedUIElementAttribute)
        let role = focused.map(AX.role)
        let label = focused.map(AX.name)
        let secure = focused.map { AX.isSecure($0) || Safety.secret(AX.name($0)) } ?? false
        if let focused, let role, AX.textFieldRoles.contains(role) {
            let before = secure ? nil : AX.stringValue(focused)
            if AX.set(focused, kAXSelectedTextAttribute, text as CFString) == .success {
                let after = secure ? nil : AX.stringValue(focused)
                // A successful insertion counts as typed when the value changed or cannot be read at all (secure
                // field, or an app that hides its value): never type again on top of an AX insertion.
                if secure || before == nil || after != before {
                    let verified = !secure && (after?.contains(text) ?? false)
                    return TypeReport(method: "AXSelectedText", characters: text.count, verified: verified, targetRole: role, targetLabel: label)
                }
            }
            let method = try await insertByKeyboard(text, app: app, target: label ?? "", allowMultiline: allowMultilineFallback)
            usleep(100_000)
            let after = secure ? nil : AX.stringValue(focused)
            return TypeReport(method: method, characters: text.count, verified: !secure && after != before && (after?.contains(text) ?? false), targetRole: role, targetLabel: label)
        }
        let method = try await insertByKeyboard(text, app: app, target: label ?? "", allowMultiline: allowMultilineFallback)
        return TypeReport(method: method, characters: text.count, verified: false, targetRole: role, targetLabel: label)
    }

    /// Single-line text goes out as Unicode keystrokes; text with line breaks is pasted, and only when allowed.
    private func insertByKeyboard(_ text: String, app: AppInfo, target: String, allowMultiline: Bool) async throws -> String {
        guard text.contains("\n") else {
            try postUnicode(text)
            return "keystrokes"
        }
        guard allowMultiline else {
            throw MultilineInsertionRefused(app: app, target: target, lines: text.split(separator: "\n", omittingEmptySubsequences: false).count)
        }
        try await pasteText(text)
        return "paste"
    }

    /// Presses a shortcut such as `cmd+shift+s` through Quartz events, `times` times.
    @discardableResult
    public func pressKeys(_ shortcut: String, times: Int = 1) async throws -> KeyboardShortcut {
        try requireTrust()
        let parsed: KeyboardShortcut
        do {
            parsed = try KeyboardShortcut.parse(shortcut)
        } catch {
            throw JarvisError.invalidArgument(
                parameter: "keys", LocalizedText(en: "Unrecognised shortcut “\(shortcut)”: \(error).", es: "Atajo no reconocido «\(shortcut)»: \(error)."))
        }
        // Keys go to whatever is in front; when that is Friday itself, hand the focus back to the user's app first.
        if await Apps.isOwnProcessInFront() { _ = try await frontmostForInput() }
        for _ in 0..<max(1, min(times, 50)) {
            try Task.checkCancellation()
            try postShortcut(parsed)
            usleep(30_000)
        }
        return parsed
    }

    /// Adapted from Atticus `sendKeys` (public-API path only): key down + key up with the modifier flags.
    private func postShortcut(_ shortcut: KeyboardShortcut) throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { throw eventFailure() }
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: down) else { throw eventFailure() }
            event.flags = shortcut.flags
            event.post(tap: .cghidEventTap)
            usleep(8_000)
        }
    }

    /// Types single-line text as Unicode key events in chunks of 20 UTF-16 units. Line breaks are never synthesised
    /// here (a Return can send a message or run a command); any that slip through become spaces. Multi-line text
    /// goes through `pasteText`.
    private func postUnicode(_ text: String) throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { throw eventFailure() }
        let units = Array(text.replacingOccurrences(of: "\n", with: " ").utf16)
        var index = 0
        while index < units.count {
            let chunk = Array(units[index..<min(index + 20, units.count)])
            index += chunk.count
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { throw eventFailure() }
                chunk.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: $0.baseAddress) }
                event.flags = []
                event.post(tap: .cghidEventTap)
                usleep(4_000)
            }
            usleep(12_000)
        }
    }

    /// Adapted from Atticus `frontMouse`: a real click at `point` (the app must already be in front and the point
    /// checked to belong to it); the pointer returns to where it was.
    private func mouseClick(at point: CGPoint) throws {
        guard let source = CGEventSource(stateID: .combinedSessionState), let saved = CGEvent(source: source)?.location else { throw eventFailure() }
        defer { CGWarpMouseCursorPosition(saved) }
        func post(_ type: CGEventType) throws {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { throw eventFailure() }
            event.flags = []
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.post(tap: .cghidEventTap)
        }
        try post(.mouseMoved)
        usleep(20_000)
        try post(.leftMouseDown)
        usleep(30_000)
        try post(.leftMouseUp)
    }

    /// Adapted from Atticus `frontWheel`: a scroll-wheel event at `spot` (the app must be in front).
    private func scrollWheel(_ direction: ScrollDirection, at spot: CGPoint, pid: Int32, fraction: Double) throws -> Bool {
        guard CGWindows.windowAt(spot, pid: pid) != nil else { return false }
        guard let source = CGEventSource(stateID: .combinedSessionState), let saved = CGEvent(source: source)?.location else { throw eventFailure() }
        defer { CGWarpMouseCursorPosition(saved) }
        CGWarpMouseCursorPosition(spot)
        let vertical = direction == .up || direction == .down
        let amount = Int32(((direction == .down || direction == .right ? -400.0 : 400.0) * fraction).rounded())
        guard
            let event = CGEvent(
                scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: vertical ? amount : 0, wheel2: vertical ? 0 : amount, wheel3: 0)
        else { throw eventFailure() }
        event.flags = []
        event.post(tap: .cghidEventTap)
        return true
    }

    private func eventFailure() -> JarvisError {
        JarvisError.failed("event_failed", en: "Could not create the input event.", es: "No se pudo crear el evento de entrada.")
    }

    // MARK: Menus

    /// Lists the application's menu bar: top-level items, with their menu items when `depth` ≥ 2.
    public func menuBarItems(pid: Int32? = nil, depth: Int = 1) async throws -> [MenuEntry] {
        try requireTrust()
        let app = try await resolveApp(pid)
        let application = AXElement.application(pid: app.pid)
        guard let menuBar = AX.element(application, kAXMenuBarAttribute) else {
            throw JarvisError.notFound("no_menu_bar", en: "\(app.localizedName) has no accessible menu bar.", es: "\(app.localizedName) no tiene una barra de menús accesible.")
        }
        func entries(_ parent: AXElement, level: Int) -> [MenuEntry] {
            var result: [MenuEntry] = []
            for child in AX.children(parent) {
                let role = AX.role(child)
                if role == "AXMenu" {
                    result += entries(child, level: level)
                    continue
                }
                let title = Safety.mask(AX.name(child))
                if title.isEmpty, role == "AXMenuItem" { continue }  // separators
                var shortcut: String?
                if let char = AX.string(child, "AXMenuItemCmdChar"), !char.isEmpty {
                    let modifiers = Int(AX.number(child, "AXMenuItemCmdModifiers") ?? 0)
                    var parts: [String] = []
                    if modifiers & 4 != 0 { parts.append("ctrl") }
                    if modifiers & 2 != 0 { parts.append("alt") }
                    if modifiers & 1 != 0 { parts.append("shift") }
                    if modifiers & 8 == 0 { parts.append("cmd") }
                    shortcut = (parts + [char.lowercased()]).joined(separator: "+")
                }
                let children = level < depth ? entries(child, level: level + 1) : []
                result.append(MenuEntry(title: title, enabled: AX.isEnabled(child), shortcut: shortcut, children: children))
            }
            return result
        }
        return entries(menuBar, level: 1)
    }

    /// Runs a menu command by walking AXMenuBar → AXMenuBarItem → AXMenu → AXMenuItem with fuzzy titles, pressing the
    /// final item, and checking the menu closed again. Adapted from Atticus `Hands.menuItem/menu`.
    ///
    /// The risky check runs on the item the fuzzy walk actually resolved ("Empty" → "Empty Trash…", "Close" →
    /// "Close All"): with `allowRisky == false` such an item is not pressed; the menus are closed again and the
    /// report comes back with `needsConfirmation` and the resolved `path` so the caller can ask the user.
    public func menuAction(path: [String], pid: Int32? = nil, allowRisky: Bool = true) async throws -> MenuReport {
        try requireTrust()
        let parts = path.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard parts.count >= 2 else {
            throw JarvisError.invalidArgument(
                parameter: "path", LocalizedText(en: "Give the menu and the item, e.g. File > Save As…", es: "Indica el menú y el elemento, p. ej. Archivo > Guardar como…"))
        }
        let app = try await resolveApp(pid)
        guard await Apps.activate(pid: app.pid) else {
            throw JarvisError.failed("activate_failed", en: "Could not bring \(app.localizedName) to the front.", es: "No se pudo traer \(app.localizedName) al frente.")
        }
        let application = AXElement.application(pid: app.pid)
        guard let menuBar = AX.element(application, kAXMenuBarAttribute) else {
            throw JarvisError.notFound("no_menu_bar", en: "\(app.localizedName) has no accessible menu bar.", es: "\(app.localizedName) no tiene una barra de menús accesible.")
        }
        var parent = menuBar
        var labels: [String] = []
        var walked: [AXElement] = []
        var opened = false
        var topLevel: AXElement?
        for (index, part) in parts.enumerated() {
            try Task.checkCancellation()
            var item = menuItem(part, in: parent)
            if item == nil, index > 0, !opened {
                // AppKit exposes closed submenus through AX; some apps only do so once the menus are open.
                for ancestor in walked {
                    _ = AX.perform(ancestor, ["AXPress", "AXPick", "AXOpen", "AXShowMenu"])
                    usleep(80_000)
                }
                opened = true
                item = menuItem(part, in: parent)
            }
            guard let found = item else {
                closeMenus(topLevel)
                throw JarvisError.notFound(
                    "menu_item_not_found", en: "No menu item “\(part)” under \(labels.isEmpty ? "the menu bar" : labels.joined(separator: " > ")).",
                    es: "No hay ningún elemento «\(part)» en \(labels.isEmpty ? "la barra de menús" : labels.joined(separator: " > ")).")
            }
            if index == 0 { topLevel = found }
            labels.append(Safety.mask(AX.name(found)))
            walked.append(found)
            parent = found
        }
        guard AX.isEnabled(parent) else {
            closeMenus(topLevel)
            throw JarvisError.failed("menu_item_disabled", en: "“\(labels.joined(separator: " > "))” is disabled right now.", es: "«\(labels.joined(separator: " > "))» está desactivado ahora mismo.")
        }
        if !allowRisky, let final = labels.last, Safety.riskyMenuItem(final) {
            closeMenus(topLevel)
            return MenuReport(path: labels, pressed: false, menuClosed: true, needsConfirmation: true)
        }
        let pressed = AX.perform(parent, ["AXPress", "AXPick"])
        usleep(200_000)
        var closed = false
        if let topLevel {
            closed = AX.bool(topLevel, kAXSelectedAttribute) != true
            if !closed { closeMenus(topLevel); usleep(100_000); closed = AX.bool(topLevel, kAXSelectedAttribute) != true }
        }
        return MenuReport(path: labels, pressed: pressed, menuClosed: closed)
    }

    /// Adapted from Atticus `Hands.menuItem`: the child (through AXMenu / AXMenuBarItem containers) best named `text`.
    private func menuItem(_ text: String, in parent: AXElement) -> AXElement? {
        var queue = AX.children(parent)
        var index = 0
        var best: (AXElement, Int)?
        while index < queue.count, index < 300 {
            let element = queue[index]
            index += 1
            let role = AX.role(element)
            if role == "AXMenu" { queue += AX.children(element); continue }
            let name = AX.name(element)
            let rank = Safety.rank(name, text)
            if rank == 4 { return element }
            if rank > 0, rank > (best?.1 ?? 0) { best = (element, rank) }
            else if rank == 0, best == nil, NameMatcher.score(query: text, candidate: name) >= 80 { best = (element, 1) }
        }
        return best?.0
    }

    private func closeMenus(_ topLevel: AXElement?) {
        if let topLevel, AX.bool(topLevel, kAXSelectedAttribute) == true {
            _ = AX.perform(topLevel, ["AXCancel"])
            if AX.bool(topLevel, kAXSelectedAttribute) == true { try? postShortcut(KeyboardShortcut(key: "escape", keyCode: 53, modifiers: [])) }
        }
    }

    // MARK: Helpers

    private func resolveApp(_ pid: Int32?) async throws -> AppInfo {
        if let pid {
            guard let info = await Apps.info(pid: pid) else {
                throw JarvisError.notFound("app_not_running", en: "That application is not running.", es: "Esa aplicación no se está ejecutando.")
            }
            return info
        }
        return try await frontmostApplication()
    }

    private func requireTrust() throws {
        guard AXIsProcessTrusted() else { throw JarvisError.permissionRequired(ComputerPermissions.accessibility) }
    }
}
