// Portions adapted from Atticus (https://github.com/SaarthurR/atticus-mac), MIT License, Copyright (c) 2026 SaarthurR.
// Hands logic adapts ideas from Plip (https://github.com/hussainn7/plip-oss), MIT License, Copyright (c) 2026 Hussain.
// See NOTICE-ATTICUS.md (Map/Node description format and element ranking).
import CoreGraphics
import Foundation
import FridayCore

/// A running application, as plain data.
public struct AppInfo: Codable, Sendable, Hashable {
    public var pid: Int32
    public var bundleID: String?
    /// Short name (executable / bundle name).
    public var name: String
    /// What the user sees in the menu bar.
    public var localizedName: String

    public init(pid: Int32, bundleID: String?, name: String, localizedName: String) {
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.localizedName = localizedName
    }

    public var json: JSONValue {
        ["pid": .int(Int(pid)), "bundle_id": JSONValue(bundleID), "name": .string(name), "localized_name": .string(localizedName)]
    }
}

/// The window a capture was taken from.
public struct WindowRef: Codable, Sendable, Hashable {
    public var id: UInt32?
    public var title: String
    public var frame: ScreenRect

    public init(id: UInt32?, title: String, frame: ScreenRect) {
        self.id = id
        self.title = title
        self.frame = frame
    }
}

/// What part of the screen to read.
public enum CaptureScope: Sendable, Hashable, Codable {
    /// The focused window of the frontmost application (plus its menu bar items).
    case frontmostWindow
    /// The focused window of one application (plus its menu bar).
    case application(pid: Int32)
    /// Only the focused element and what is inside it.
    case focusedElement
}

/// One accessibility element as captured. Ids are stable within one capture (`e1`, `e2`… in traversal order).
public struct UIElementSnapshot: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var role: String
    public var subrole: String?
    /// Title, description, label, help or placeholder, in that order; the text of children for rows/buttons.
    public var label: String
    /// Masked value; `nil` for secure fields and when the element has no value.
    public var value: String?
    public var frame: ScreenRect
    public var actions: [String]
    public var enabled: Bool
    public var focused: Bool
    public var secure: Bool
    public var children: [String]
    /// Child indices from the capture root; `-1` as the first component means "the application's menu bar".
    public var path: [Int]
    /// The page URL of a web area.
    public var url: String?
    /// Vertical scroll position of a scroll area, 0 (top) … 1 (bottom).
    public var scrollPosition: Double?

    public init(
        id: String, role: String, subrole: String? = nil, label: String, value: String? = nil, frame: ScreenRect,
        actions: [String] = [], enabled: Bool = true, focused: Bool = false, secure: Bool = false, children: [String] = [],
        path: [Int] = [], url: String? = nil, scrollPosition: Double? = nil
    ) {
        self.id = id
        self.role = role
        self.subrole = subrole
        self.label = label
        self.value = value
        self.frame = frame
        self.actions = actions
        self.enabled = enabled
        self.focused = focused
        self.secure = secure
        self.children = children
        self.path = path
        self.url = url
        self.scrollPosition = scrollPosition
    }

    /// "AXPopUpButton" → "pop up button", "AXStaticText" → "text".
    public var roleName: String { Self.roleName(role) }

    public static func roleName(_ role: String) -> String {
        switch role {
        case "AXStaticText": return "text"
        case "AXTextField": return "text field"
        case "AXTextArea": return "text area"
        case "AXSecureTextField": return "password field"
        case "AXSearchField": return "search field"
        case "AXPopUpButton": return "pop-up"
        case "AXMenuBarItem": return "menu bar item"
        case "AXMenuItem": return "menu item"
        case "AXScrollArea": return "scroll area"
        case "AXWebArea": return "web page"
        default:
            let stripped = role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
            var words = ""
            for (index, character) in stripped.enumerated() {
                if character.isUppercase, index > 0 { words.append(" ") }
                words.append(character.lowercased())
            }
            return words.isEmpty ? "element" : words
        }
    }

    public var isTextField: Bool { AX.textFieldRoles.contains(role) }

    public var isInteractive: Bool {
        Self.interactiveRoles.contains(role) || actions.contains("AXPress") || actions.contains("AXPick") || actions.contains("AXConfirm")
    }

    public var isScrollable: Bool { role == "AXScrollArea" || actions.contains { $0.hasPrefix("AXScroll") } }

    static let interactiveRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXSwitch", "AXPopUpButton", "AXMenuButton", "AXMenuItem", "AXMenuBarItem",
        "AXTextField", "AXTextArea", "AXSecureTextField", "AXSearchField", "AXComboBox", "AXLink", "AXSlider", "AXIncrementor",
        "AXDisclosureTriangle", "AXTab", "AXRow", "AXCell", "AXColorWell", "AXDateField", "AXTimeField", "AXStepper",
        "AXToolbarButton",
    ]

    /// Roles that are pure containers: not listed in ``UITree/describe(maxLines:)`` unless they carry a label.
    static let containerRoles: Set<String> = [
        "AXGroup", "AXUnknown", "AXLayoutArea", "AXLayoutItem", "AXSplitGroup", "AXSplitter", "AXApplication", "AXToolbar", "AXList",
        "AXOutline", "AXTable", "AXBrowser", "AXTabGroup", "AXGenericElement", "AXRuler", "AXGrid", "AXDrawer", "AXGrowArea",
        "AXMenuBar", "AXMenu", "AXColumn", "AXMatte", "AXDockItem", "AXBusyIndicator", "AXProgressIndicator",
    ]

    /// One compact line for an LLM: `[e12] button "Save" (at 512,340) [focused]`.
    public var line: String {
        var text = "[\(id)] \(roleName)"
        if !label.isEmpty, Safety.normalized(label) != Safety.normalized(roleName) { text += " \(Self.quote(label))" }
        if secure {
            text += " [secure]"
        } else if let value, !value.isEmpty, value != label {
            text += " = \(Self.quote(String(value.prefix(80))))"
        }
        if let url, !url.isEmpty { text += " <\(String(url.prefix(120)))>" }
        var hints: [String] = []
        if focused { hints.append("focused") }
        if !enabled { hints.append("disabled") }
        if isScrollable, let scrollPosition { hints.append("scrolled \(Int((scrollPosition * 100).rounded()))%") } else if isScrollable { hints.append("scrollable") }
        if !hints.isEmpty { text += " [" + hints.joined(separator: ", ") + "]" }
        if !frame.isEmpty {
            let centre = frame.center
            text += " (at \(Int(centre.x.rounded())),\(Int(centre.y.rounded())))"
        }
        return text
    }

    static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: " ") + "\""
    }

    public var json: JSONValue {
        var object: JSONObject = [
            "id": .string(id), "role": .string(roleName), "label": .string(label), "frame": frame.json,
            "actions": .array(actions.map(JSONValue.string)), "enabled": .bool(enabled), "focused": .bool(focused),
        ]
        if let subrole { object["subrole"] = .string(subrole) }
        if secure { object["secure"] = true } else if let value { object["value"] = .string(value) }
        if let url { object["url"] = .string(url) }
        if let scrollPosition { object["scroll_position"] = .double(scrollPosition) }
        if !children.isEmpty { object["children"] = .array(children.map(JSONValue.string)) }
        return .object(object)
    }
}

/// A captured accessibility tree: the elements (flat map + children ids), the visible text and a compact
/// description for a text-only model. Produce one with ``AccessibilityService/capture(scope:maxElements:)``.
public struct UITree: Codable, Sendable {
    public var app: AppInfo
    public var window: WindowRef?
    public var scope: CaptureScope
    public var rootIDs: [String]
    public var elements: [String: UIElementSnapshot]
    /// Ids in traversal order (`describe` and `find` use it for stable ordering).
    public var order: [String]
    public var focusedID: String?
    /// Static text and headings in reading order (deduplicated, masked), for a quick skim.
    public var texts: [String]
    /// Whether the element budget cut the capture short.
    public var truncated: Bool
    /// Raw elements visited (including ones not recorded).
    public var visited: Int
    public var capturedAt: Date

    public init(
        app: AppInfo, window: WindowRef?, scope: CaptureScope, rootIDs: [String], elements: [String: UIElementSnapshot],
        order: [String], focusedID: String? = nil, texts: [String] = [], truncated: Bool = false, visited: Int = 0,
        capturedAt: Date = Date()
    ) {
        self.app = app
        self.window = window
        self.scope = scope
        self.rootIDs = rootIDs
        self.elements = elements
        self.order = order
        self.focusedID = focusedID
        self.texts = texts
        self.truncated = truncated
        self.visited = visited
        self.capturedAt = capturedAt
    }

    public var count: Int { order.count }
    public func element(_ id: String) -> UIElementSnapshot? { elements[id] }
    public var ordered: [UIElementSnapshot] { order.compactMap { elements[$0] } }
    public var focused: UIElementSnapshot? { focusedID.flatMap { elements[$0] } }

    /// Elements worth a line: controls, text fields, menu items, scroll areas, labelled containers and visible text.
    public var notable: [UIElementSnapshot] {
        ordered.filter { element in
            if element.isInteractive || element.isTextField || element.isScrollable { return true }
            if element.role == "AXWebArea" { return true }
            if ["AXStaticText", "AXHeading", "AXImage"].contains(element.role) { return !element.label.isEmpty }
            if UIElementSnapshot.containerRoles.contains(element.role) { return !element.label.isEmpty }
            return !element.label.isEmpty || !(element.value ?? "").isEmpty
        }
    }

    /// Adapted from Atticus `Map.rich`: enough structure for a text-only model to work from AX alone.
    public var isRich: Bool {
        let controls = ordered.filter { !$0.role.contains("Menu") && ($0.isInteractive || $0.isTextField) }.count
        return controls >= 8 || (controls >= 4 && texts.count >= 6)
    }

    /// Window title plus dialog/sheet labels: the context ``Safety/riskyLabel(_:context:)`` uses for generic buttons.
    public var contextText: String {
        let dialogs = ordered.filter { ["AXSheet", "AXDialog", "AXWindow"].contains($0.role) }.map(\.label)
        return ([window?.title ?? ""] + dialogs + texts.prefix(40)).joined(separator: " ")
    }

    /// Compact text for an LLM: header, focused element, one line per notable element (capped at `maxLines`), then the
    /// visible text.
    public func describe(maxLines: Int = 120) -> String {
        var lines: [String] = []
        var header = "App: \(app.localizedName) (pid \(app.pid))"
        if let window {
            header += " · Window: \(UIElementSnapshot.quote(Safety.mask(window.title))) \(window.frame)"
        }
        lines.append(header)
        if let focused {
            lines.append("Focused: \(focused.id) \(focused.roleName)" + (focused.label.isEmpty ? "" : " \(UIElementSnapshot.quote(focused.label))"))
        }
        let notable = notable
        let budget = max(1, maxLines - lines.count - 2)
        for element in notable.prefix(budget) { lines.append(element.line) }
        if notable.count > budget {
            lines.append("… \(notable.count - budget) more elements (raise max_lines)")
        } else if truncated {
            lines.append("… capture stopped at the element budget; more may exist")
        }
        if !texts.isEmpty {
            lines.append("Visible text: " + String(texts.joined(separator: " | ").prefix(1_400)))
        }
        return lines.joined(separator: "\n")
    }

    /// Fuzzy search on label, value, title and role (case- and accent-insensitive). Best first; ties keep screen order.
    public func find(_ query: String, limit: Int = 10) -> [UIElementSnapshot] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if let exact = elements[trimmed] { return [exact] }
        if let exact = elements[trimmed.lowercased()] { return [exact] }
        var scored: [(score: Int, offset: Int, element: UIElementSnapshot)] = []
        for (offset, element) in ordered.enumerated() {
            let score = ElementMatcher.score(query: trimmed, element: element)
            if score >= ElementMatcher.minimumScore { scored.append((score, offset, element)) }
        }
        scored.sort { lhs, rhs in lhs.score != rhs.score ? lhs.score > rhs.score : lhs.offset < rhs.offset }
        return scored.prefix(limit).map(\.element)
    }

    public var json: JSONValue {
        var object: JSONObject = [
            "app": app.json, "count": .int(count), "truncated": .bool(truncated),
            "elements": .array(notable.map(\.json)),
            "texts": .array(texts.map(JSONValue.string)),
        ]
        if let window {
            object["window"] = ["id": JSONValue(window.id.map(Int.init)), "title": .string(window.title), "frame": window.frame.json]
        }
        if let focusedID { object["focused"] = .string(focusedID) }
        return .object(object)
    }
}

/// Scores how well a user phrase names one element.
public enum ElementMatcher {
    public static let minimumScore = 50

    public static func score(query: String, element: UIElementSnapshot) -> Int {
        let normalizedQuery = Safety.normalized(query)
        guard !normalizedQuery.isEmpty else { return 0 }
        var best = 0
        for field in [element.label, element.value ?? ""] where !field.isEmpty {
            switch Safety.rank(field, normalizedQuery) {
            case 4: best = max(best, 100)
            case 3: best = max(best, 85)
            case 2: best = max(best, 75)
            case 1: best = max(best, 60)
            default: break
            }
            best = max(best, NameMatcher.score(query: normalizedQuery, candidate: field))
            best = max(best, FuzzyNameMatcher.score(query: normalizedQuery, candidate: field))
        }
        // "the search field", "botón Guardar": a role word plus a label.
        let roleName = Safety.normalized(element.roleName)
        if normalizedQuery == roleName { best = max(best, 55) }
        let roleWords = Set(roleName.split(separator: " ").map(String.init) + Self.spanishRoleWords(for: element.role))
        let queryWords = normalizedQuery.split(separator: " ").map(String.init)
        let withoutRole = queryWords.filter { !roleWords.contains($0) && !Self.filler.contains($0) }.joined(separator: " ")
        if withoutRole != normalizedQuery, !withoutRole.isEmpty {
            for field in [element.label, element.value ?? ""] where !field.isEmpty {
                let rank = Safety.rank(field, withoutRole)
                if rank == 4 { best = max(best, 95) } else if rank == 3 { best = max(best, 80) } else if rank >= 1 { best = max(best, 65) }
                best = max(best, NameMatcher.score(query: withoutRole, candidate: field) - 5)
            }
        }
        return best
    }

    static let filler: Set<String> = ["the", "a", "an", "el", "la", "los", "las", "un", "una", "de", "del", "on", "en"]

    static func spanishRoleWords(for role: String) -> [String] {
        switch role {
        case "AXButton", "AXToolbarButton": return ["boton", "botón"]
        case "AXTextField", "AXTextArea", "AXSearchField": return ["campo", "cuadro", "caja"]
        case "AXCheckBox": return ["casilla"]
        case "AXLink": return ["enlace", "vinculo"]
        case "AXMenuItem", "AXMenuBarItem": return ["menu"]
        case "AXTab": return ["pestana", "pestaña"]
        case "AXRow": return ["fila"]
        default: return []
        }
    }
}
