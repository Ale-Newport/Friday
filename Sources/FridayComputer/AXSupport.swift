// Portions adapted from Atticus (https://github.com/SaarthurR/atticus-mac), MIT License, Copyright (c) 2026 SaarthurR.
// Hands logic adapts ideas from Plip (https://github.com/hussainn7/plip-oss), MIT License, Copyright (c) 2026 Hussain.
// See NOTICE-ATTICUS.md for the exact functions and licence texts.
import AppKit
import ApplicationServices
import Foundation
import FridayCore

/// A thread-safe handle to one accessibility element.
///
/// `AXUIElementRef` is an immutable Core Foundation token that identifies a remote object (process + element id);
/// Apple documents the Accessibility client API as usable from any thread, so the wrapper is `@unchecked Sendable`.
public struct AXElement: @unchecked Sendable, Hashable, CustomStringConvertible {
    public let raw: AXUIElement

    public init(_ raw: AXUIElement) { self.raw = raw }

    public static func == (lhs: AXElement, rhs: AXElement) -> Bool { CFEqual(lhs.raw, rhs.raw) }
    public func hash(into hasher: inout Hasher) { hasher.combine(CFHash(raw)) }

    public static func application(pid: pid_t) -> AXElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.5)
        return AXElement(element)
    }

    public static var systemWide: AXElement {
        let element = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(element, 0.5)
        return AXElement(element)
    }

    public var description: String { "AXElement(\(AX.role(self)) \"\(AX.name(self))\")" }
}

/// A rectangle in screen points using the Core Graphics / Accessibility convention: origin at the top-left corner
/// of the main display, y growing downwards. Every frame this module reports uses this space.
public struct ScreenRect: Codable, Sendable, Hashable, CustomStringConvertible {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(_ rect: CGRect) {
        self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }

    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    public var center: CGPoint { CGPoint(x: x + width / 2, y: y + height / 2) }
    public var isEmpty: Bool { width <= 0 || height <= 0 }
    public var description: String { "(\(Int(x.rounded())),\(Int(y.rounded())) \(Int(width.rounded()))×\(Int(height.rounded())))" }

    /// `true` when the two rectangles differ by at most `tolerance` points on every edge.
    public func matches(_ other: ScreenRect, tolerance: Double = 2) -> Bool {
        abs(x - other.x) <= tolerance && abs(y - other.y) <= tolerance && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }

    public var json: JSONValue {
        ["x": .double(x.rounded()), "y": .double(y.rounded()), "width": .double(width.rounded()), "height": .double(height.rounded())]
    }
}

/// Thin, synchronous wrappers over the Accessibility client API. All functions are pure reads or single calls;
/// callers decide where they run (`AccessibilityService` serialises them on its own queue).
enum AX {
    // MARK: Attributes (adapted from Atticus `axAttribute` and `Hands.attribute/element/children/frame`)

    static func attribute(_ element: AXElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element.raw, name as CFString, &value) == .success ? value : nil
    }

    static func string(_ element: AXElement, _ name: String) -> String? {
        guard let value = attribute(element, name) else { return nil }
        if let text = value as? String { return text }
        if let attributed = value as? NSAttributedString { return attributed.string }
        if let url = value as? URL { return url.absoluteString }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    static func bool(_ element: AXElement, _ name: String) -> Bool? {
        guard let value = attribute(element, name) else { return nil }
        if CFGetTypeID(value) == CFBooleanGetTypeID() { return CFBooleanGetValue((value as! CFBoolean)) }
        return (value as? NSNumber)?.boolValue
    }

    static func number(_ element: AXElement, _ name: String) -> Double? {
        (attribute(element, name) as? NSNumber)?.doubleValue
    }

    static func element(_ element: AXElement, _ name: String) -> AXElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return AXElement(value as! AXUIElement)
    }

    static func elements(_ element: AXElement, _ name: String) -> [AXElement] {
        guard let value = attribute(element, name), CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        let array = value as! CFArray
        var result: [AXElement] = []
        for index in 0..<CFArrayGetCount(array) {
            guard let pointer = CFArrayGetValueAtIndex(array, index) else { continue }
            let item = Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue()
            if CFGetTypeID(item) == AXUIElementGetTypeID() { result.append(AXElement(item as! AXUIElement)) }
        }
        return result
    }

    static func children(_ element: AXElement, limit: Int = 400) -> [AXElement] {
        Array(elements(element, kAXChildrenAttribute).prefix(limit))
    }

    static func frame(_ element: AXElement) -> CGRect {
        var origin = CGPoint.zero
        var size = CGSize.zero
        if let value = attribute(element, kAXPositionAttribute), CFGetTypeID(value) == AXValueGetTypeID() {
            AXValueGetValue(value as! AXValue, .cgPoint, &origin)
        }
        if let value = attribute(element, kAXSizeAttribute), CFGetTypeID(value) == AXValueGetTypeID() {
            AXValueGetValue(value as! AXValue, .cgSize, &size)
        }
        return CGRect(origin: origin, size: size)
    }

    static func role(_ element: AXElement) -> String { string(element, kAXRoleAttribute) ?? "" }
    static func subrole(_ element: AXElement) -> String? { string(element, kAXSubroleAttribute) }
    static func title(_ element: AXElement) -> String? { string(element, kAXTitleAttribute) }
    static func isEnabled(_ element: AXElement) -> Bool { bool(element, kAXEnabledAttribute) ?? true }

    static func pid(of element: AXElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element.raw, &pid) == .success ? pid : nil
    }

    static func isSettable(_ element: AXElement, _ name: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element.raw, name as CFString, &settable) == .success && settable.boolValue
    }

    @discardableResult
    static func set(_ element: AXElement, _ name: String, _ value: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(element.raw, name as CFString, value)
    }

    @discardableResult
    static func set(_ element: AXElement, _ name: String, point: CGPoint) -> AXError {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return .failure }
        return set(element, name, value)
    }

    @discardableResult
    static func set(_ element: AXElement, _ name: String, size: CGSize) -> AXError {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return .failure }
        return set(element, name, value)
    }

    @discardableResult
    static func set(_ element: AXElement, _ name: String, range: CFRange) -> AXError {
        var range = range
        guard let value = AXValueCreate(.cfRange, &range) else { return .failure }
        return set(element, name, value)
    }

    // MARK: Names (adapted from Atticus `Hands.name`)

    /// The human-readable name of a control: its own title/description/label/help/placeholder, else the text of its
    /// children (rows, cells, buttons…), else the text of its siblings. Secrets are masked and the result is capped.
    static func name(_ element: AXElement) -> String {
        func direct(_ item: AXElement) -> String {
            for key in [kAXTitleAttribute, kAXDescriptionAttribute, "AXLabel", kAXHelpAttribute, "AXPlaceholderValue"] {
                if let text = string(item, key), !text.isEmpty { return String(Safety.mask(text).prefix(160)) }
            }
            let role = Self.role(item)
            guard ["AXStaticText", "AXHeading"].contains(role) else { return "" }
            return String(Safety.mask(string(item, kAXValueAttribute) ?? "").prefix(160))
        }
        let own = direct(element)
        let role = Self.role(element)
        let roleNames = [Safety.normalized(role), Safety.normalized(role.replacingOccurrences(of: "AX", with: ""))]
        if !own.isEmpty, !roleNames.contains(Safety.normalized(own)) { return own }
        guard
            ["AXRow", "AXCell", "AXButton", "AXCheckBox", "AXSwitch", "AXRadioButton", "AXPopUpButton", "AXDisclosureTriangle", "AXMenuButton"]
                .contains(role)
        else { return own }
        var queue = children(element)
        var cursor = 0
        var parts: [String] = []
        if let title = self.element(element, kAXTitleUIElementAttribute) {
            let text = direct(title)
            if !text.isEmpty { parts.append(text) }
        }
        while cursor < queue.count, cursor < 24, parts.joined(separator: " ").count < 160 {
            let child = queue[cursor]
            cursor += 1
            let text = direct(child)
            if !text.isEmpty, !parts.contains(text) { parts.append(text) }
            queue += children(child)
        }
        if parts.isEmpty, let parent = self.element(element, kAXParentAttribute) {
            var nearby = children(parent)
            var index = 0
            while index < nearby.count, index < 24, parts.joined(separator: " ").count < 160 {
                let item = nearby[index]
                index += 1
                if item != element {
                    let text = direct(item)
                    if !text.isEmpty, !parts.contains(text) { parts.append(text) }
                }
                nearby += children(item)
            }
        }
        return String(parts.joined(separator: " ").prefix(160))
    }

    // MARK: Actions (adapted from Atticus `Hands.actions/perform`)

    static func actions(_ element: AXElement) -> [String] {
        var names: CFArray?
        AXUIElementCopyActionNames(element.raw, &names)
        return names as? [String] ?? []
    }

    /// Performs the first supported action of `names`. `cannotComplete` counts as performed: the press opened a modal
    /// sheet and the app stopped answering AX while the action ran, so it must never be retried with the mouse.
    static func perform(_ element: AXElement, _ names: [String]) -> Bool {
        let supported = actions(element)
        return names.contains { name in
            supported.contains(name) && [.success, .cannotComplete].contains(AXUIElementPerformAction(element.raw, name as CFString))
        }
    }

    // MARK: Geometry and focus (adapted from Atticus `Hands.visibleFrame/fieldFocused/stringValue/selectedRange`)

    /// The element's frame clipped by every enclosing window, sheet, scroll area and web area.
    static func visibleFrame(_ element: AXElement) -> CGRect {
        var visible = frame(element)
        var current = element
        for _ in 0..<40 {
            guard let parent = self.element(current, kAXParentAttribute) else { break }
            let role = Self.role(parent)
            if ["AXWindow", "AXScrollArea", "AXWebArea", "AXSheet"].contains(role) {
                let parentFrame = frame(parent)
                if !parentFrame.isEmpty { visible = visible.intersection(parentFrame) }
            }
            current = parent
        }
        return visible
    }

    /// Whether `element` is the focused element of its application, waiting up to `wait` seconds (web and Electron
    /// apps apply an AX focus request a moment later).
    static func fieldFocused(_ element: AXElement, pid: pid_t, wait: TimeInterval = 0) -> Bool {
        let end = Date().addingTimeInterval(wait)
        let application = AXElement.application(pid: pid)
        while true {
            if let focused = self.element(application, kAXFocusedUIElementAttribute), focused == element { return true }
            if Date() >= end { return false }
            usleep(50_000)
        }
    }

    static func stringValue(_ element: AXElement) -> String? {
        let raw = attribute(element, kAXValueAttribute)
        return raw as? String ?? (raw as? NSAttributedString)?.string
    }

    static func selectedRange(_ element: AXElement) -> CFRange? {
        guard let value = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }

    static func windows(of application: AXElement) -> [AXElement] { elements(application, kAXWindowsAttribute) }

    static func isSecure(_ element: AXElement) -> Bool {
        role(element) == "AXSecureTextField" || subrole(element) == "AXSecureTextField"
    }

    static let textFieldRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXSecureTextField"]
}

/// Secret masking, risky-label detection and label normalisation (adapted from Atticus `Hands.secretPattern`,
/// `riskyPattern`, `riskyLabel`, `secret`, `mask`, `normalized`, `rank`; Spanish vocabulary added for Friday).
public enum Safety {
    static let secretPattern =
        #"(?i)password|passcode|passphrase|passport|\bpin\b|card|cvv|cvc|security (answer|code)|\bssn\b|social security|api.?key|token|secret|one.?time|verification|auth.*code|2fa|\botp\b|bank|account.?number|routing|iban|tax.?id|recovery|seed|mnemonic|contrase[nñ]a|clave|tarjeta|c[oó]digo de (seguridad|verificaci[oó]n)|cuenta bancaria|pasaporte"#

    static let riskyPattern =
        #"(?i)\b(buy|purchase|pay|payment|checkout|order|send|delete|remove|trash|submit|publish|post|sign.?out|log.?out|unsubscribe|subscribe|transfer|bid|erase|withdraw|donate|authorize|grant access|allow access|logout|book|reserve|merge|deploy|discard|wipe|format|empty trash|uninstall|reset|shut down|restart|quit|apply(?! filters| changes| settings| coupon| code| promo| discount| theme| style| formatting)|confirm|comprar|compra|pagar|pago|enviar|env[ií]o|eliminar|elimina|borrar|borra|suprimir|quitar|vaciar|publicar|transferir|retirar|donar|autorizar|descartar|formatear|desinstalar|restablecer|reiniciar|apagar|cerrar sesi[oó]n|salir|confirmar|reservar|comprobar|finalizar compra)\b"#

    static let genericConfirmationPattern = #"(?i)^\s*(ok|yes|continue|allow|accept|agree|complete|finish|grant|s[ií]|aceptar|continuar|permitir|acepto|de acuerdo|finalizar|conceder)\s*$"#

    static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    /// `true` for labels such as Delete, Remove, Purchase, Pay, Send, Erase, Format (and eliminar, borrar, comprar, pagar,
    /// enviar…). A generic confirmation ("OK", "Yes", "Aceptar") is risky when `context` (window title, dialog text)
    /// itself talks about a risky operation.
    public static func riskyLabel(_ label: String, context: String? = nil) -> Bool {
        let normalized = normalized(label)
        if ["cancel", "cancelar", "close", "cerrar"].contains(normalized) { return false }
        if matches(label, riskyPattern) { return true }
        guard let context else { return matches(label, genericConfirmationPattern) }
        return matches(label, genericConfirmationPattern) && matches(context, riskyPattern)
    }

    /// Whether a label suggests the field holds a secret (password, card number, token…).
    public static func secret(_ text: String) -> Bool { matches(text, secretPattern) }

    /// Replaces card-like digit runs, social security numbers and one-time codes with `[SECRET]`.
    public static func mask(_ text: String) -> String {
        var masked = text.replacingOccurrences(
            of: #"\b\d(?:[ -]?\d){12,18}\b|\b\d{3}[- ]\d{2}[- ]\d{4}\b|\b\d{6,8}\b"#, with: "[SECRET]", options: .regularExpression)
        if matches(masked, #"(?i)(one.?time|verification|security|auth|otp|code|c[oó]digo)\D{0,20}\d{4,8}"#) {
            masked = masked.replacingOccurrences(of: #"\b\d{4,8}\b"#, with: "[SECRET]", options: .regularExpression)
        }
        return masked
    }

    /// Lowercases, collapses whitespace, folds diacritics and normalises ellipses and the Unicode hyphens macOS
    /// writes into labels ("Wi‑Fi" uses a non-breaking hyphen).
    public static func normalized(_ text: String) -> String {
        TextFolding.fold(text)
            .replacingOccurrences(of: "…", with: "...")
            .replacingOccurrences(of: "[\u{2010}-\u{2015}\u{2212}]", with: "-", options: .regularExpression)
    }

    /// How well `text` names `label`: 4 exact, 3 prefix, 2 whole word, 1 substring, 0 no match.
    public static func rank(_ label: String, _ text: String) -> Int {
        let l = normalized(label)
        let t = normalized(text)
        guard !t.isEmpty, !l.isEmpty else { return 0 }
        if l == t { return 4 }
        if l.hasPrefix(t) { return 3 }
        if matches(l, #"\b"# + NSRegularExpression.escapedPattern(for: t) + #"\b"#) { return 2 }
        return l.contains(t) ? 1 : 0
    }
}
