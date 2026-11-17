import Foundation
import FridayCore
import FridaySidecar
import os

/// The categories the fast router distinguishes. They narrow the tools offered to the planner; they never execute
/// anything by themselves.
public enum IntentCategory: String, Sendable, Codable, CaseIterable, Hashable {
    case music, reminders, notes, calendar, browser, files, system, communication, information, clock, unknown
}

public struct RoutingDecision: Sendable, Hashable {
    public var category: IntentCategory
    public var confidence: Double
    public var multistepProbability: Double
    public var dangerProbability: Double
    public var questionProbability: Double
    public var source: String
    public var latencyMs: Int

    public static let unknown = RoutingDecision(category: .unknown, confidence: 0, multistepProbability: 0.5, dangerProbability: 0, questionProbability: 0.5, source: "none", latencyMs: 0)

    public var isConfident: Bool { category != .unknown && confidence >= 0.6 }
    public var looksMultistep: Bool { multistepProbability >= 0.6 }
    public var looksDangerous: Bool { dangerProbability >= 0.3 }
}

/// Context the router and planner may use to resolve references ("this", "that").
public struct RequestContext: Sendable, Hashable {
    public var frontmostApp: String?
    public var frontmostWindowTitle: String?
    public var selectedText: String?
    public var browserTab: String?
    public var nowPlaying: String?
    public var clipboardPreview: String?
    public init(frontmostApp: String? = nil, frontmostWindowTitle: String? = nil, selectedText: String? = nil, browserTab: String? = nil, nowPlaying: String? = nil, clipboardPreview: String? = nil) {
        self.frontmostApp = frontmostApp
        self.frontmostWindowTitle = frontmostWindowTitle
        self.selectedText = selectedText
        self.browserTab = browserTab
        self.nowPlaying = nowPlaying
        self.clipboardPreview = clipboardPreview
    }
}

/// Fast intent classification: bilingual keyword rules first (microseconds), then Laya through the sidecar
/// (tens of milliseconds), then "unknown" so the planner sees every tool.
public actor IntentRouter {
    static let logger = Logger(subsystem: "com.alejandro.friday", category: "router")

    private var client: SidecarClient?
    private var sidecarUnavailableUntil: Date = .distantPast
    public private(set) var lastDecision: RoutingDecision?

    public init(client: SidecarClient? = nil) { self.client = client }

    public func setClient(_ client: SidecarClient?) { self.client = client }

    public func route(_ text: String, language: Language?, context: RequestContext?, useLaya: Bool) async -> RoutingDecision {
        let started = ContinuousClock.now
        if let ruled = KeywordRouter.route(text) {
            var decision = RoutingDecision(
                category: ruled, confidence: 0.9, multistepProbability: KeywordRouter.looksMultistep(text) ? 0.8 : 0.1,
                dangerProbability: KeywordRouter.looksDangerous(text) ? 0.8 : 0.05, questionProbability: KeywordRouter.looksLikeQuestion(text) ? 0.8 : 0.1,
                source: "rules", latencyMs: 0)
            decision.latencyMs = Int(started.duration(to: .now).components.attoseconds / 1_000_000_000_000_000)
            lastDecision = decision
            return decision
        }
        guard useLaya, let client, Date() >= sidecarUnavailableUntil else {
            let decision = RoutingDecision(
                category: .unknown, confidence: 0, multistepProbability: KeywordRouter.looksMultistep(text) ? 0.8 : 0.4,
                dangerProbability: KeywordRouter.looksDangerous(text) ? 0.8 : 0.1, questionProbability: KeywordRouter.looksLikeQuestion(text) ? 0.8 : 0.3,
                source: "none", latencyMs: 0)
            lastDecision = decision
            return decision
        }
        var body: JSONObject = ["text": .string(text)]
        if let language { body["language"] = .string(language.rawValue) }
        if let context {
            var object: JSONObject = [:]
            if let app = context.frontmostApp { object["frontmost_app"] = .string(app) }
            if context.selectedText != nil { object["has_selection"] = true }
            if let tab = context.browserTab { object["browser_tab"] = .string(tab) }
            body["context"] = .object(object)
        }
        do {
            // Routing sits in the per-command hot path: a slow answer is treated like no answer (the planner then
            // sees every tool), and the sidecar is left alone for a while.
            let response = try await client.post("api/route", .object(body), timeout: 0.5)
            let decision = RoutingDecision(
                category: IntentCategory(rawValue: response["category"]?.stringValue ?? "unknown") ?? .unknown,
                confidence: response["confidence"]?.doubleValue ?? 0,
                multistepProbability: response["multistep"]?.doubleValue ?? 0.5,
                dangerProbability: max(response["dangerous"]?.doubleValue ?? 0, KeywordRouter.looksDangerous(text) ? 0.8 : 0),
                questionProbability: response["question"]?.doubleValue ?? 0.5,
                source: response["source"]?.stringValue ?? "laya",
                latencyMs: response["latency_ms"]?.intValue ?? Int(started.duration(to: .now).components.attoseconds / 1_000_000_000_000_000))
            lastDecision = decision
            return decision
        } catch {
            Self.logger.warning("route failed: \(error.localizedDescription, privacy: .public)")
            sidecarUnavailableUntil = Date().addingTimeInterval(30)
            let decision = RoutingDecision.unknown
            lastDecision = decision
            return decision
        }
    }
}

/// Deterministic, bilingual keyword routing for obvious cases. Returns nil when zero or several categories match.
public enum KeywordRouter {
    static let table: [(IntentCategory, [String])] = [
        (.music, ["play ", "pause", "skip", "next song", "previous song", "playlist", "song", "album", "artist", "shuffle", "repeat", "apple music", "spotify", "pon ", "ponme", "canción", "cancion", "música", "musica", "lista de reproducción", "siguiente", "anterior", "volumen de la música"]),
        (.reminders, ["remind", "reminder", "to-do", "todo", "groceries", "shopping list", "recuérdame", "recuerdame", "recordatorio", "lista de la compra", "lista de compras", "tarea", "pendiente"]),
        (.notes, ["note", "notes", "nota", "notas", "apunta", "apúntame", "apuntame"]),
        (.calendar, ["calendar", "event", "meeting", "appointment", "schedule", "free slot", "calendario", "evento", "reunión", "reunion", "cita", "agenda"]),
        (.browser, ["search for", "google", "website", "web ", "chrome", "youtube", "flight", "flights", "amazon", "browse", "open the first result", "download the", "busca en", "página", "pagina", "vuelo", "vuelos", "navegador", "internet"]),
        (.files, ["file", "files", "folder", "finder", "downloads folder", "rename", "convert", "archivo", "archivos", "carpeta", "descargas", "renombra", "convierte", "duplicados", "duplicates"]),
        (.system, ["volume", "brightness", "open ", "close ", "quit ", "window", "windows", "screenshot", "dark mode", "lock", "clipboard", "wifi", "bluetooth", "volumen", "brillo", "abre ", "cierra ", "ventana", "captura de pantalla", "modo oscuro", "bloquea", "portapapeles", "pantalla"]),
        (.communication, ["email", "e-mail", "mail", "message", "messages", "text ", "whatsapp", "slack", "contact", "correo", "mensaje", "mensajes", "contacto", "escríbele", "escribele", "envía", "envia"]),
        (.information, ["weather", "forecast", "what is", "what's", "who is", "how much", "how many", "calculate", "convert ", "translate", "define", "explain", "tiempo", "clima", "qué es ", "que es ", "quién es ", "quien es ", "cuánto", "cuanto", "cuántos", "cuantos", "calcula", "traduce", "explica", "define"]),
        (.clock, ["timer", "alarm", "stopwatch", "countdown", "temporizador", "alarma", "cronómetro", "cronometro", "cuenta atrás"]),
    ]

    public static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil).lowercased()
    }

    /// The folded text with every run of punctuation or whitespace collapsed to one space, and a space at both ends,
    /// so keywords can be matched at word starts ("mail" never matches "gmail", "lock" never matches "clock").
    static func spaced(_ text: String) -> String {
        var out = " "
        var lastSpace = true
        for character in fold(text) {
            if character.isLetter || character.isNumber || character == "'" || character == "-" {
                out.append(character)
                lastSpace = false
            } else if !lastSpace {
                out.append(" ")
                lastSpace = true
            }
        }
        if !lastSpace { out.append(" ") }
        return out
    }

    public static func route(_ text: String) -> IntentCategory? {
        let folded = " " + fold(text) + " "
        let haystack = spaced(text)
        var hits: Set<IntentCategory> = []
        for (category, keywords) in table {
            for keyword in keywords {
                // A keyword with a trailing space is a whole word ("play "); without one it is a word start ("remind").
                let needle = keyword.hasSuffix(" ") ? spaced(keyword) : String(spaced(keyword).dropLast())
                guard haystack.contains(needle) else { continue }
                hits.insert(category)
                break
            }
        }
        // "open Chrome" is a system command (launch an app), not browsing; "open youtube.com" is browsing.
        if hits == [.system, .browser] {
            if folded.contains(".com") || folded.contains("http") || folded.contains("search") || folded.contains("busca") { return .browser }
            if folded.contains("open chrome") || folded.contains("abre chrome") || folded.contains("open safari") { return .system }
        }
        return hits.count == 1 ? hits.first : nil
    }

    public static func looksMultistep(_ text: String) -> Bool {
        let folded = fold(text)
        let connectors = [" and then ", " then ", " after that ", " y luego ", " y despues ", " despues ", " luego ", " and also ", " y tambien ", " if ", " si llueve", " whenever ", " cuando "]
        if connectors.contains(where: { folded.contains($0) }) { return true }
        return folded.components(separatedBy: " and ").count > 2 || folded.components(separatedBy: " y ").count > 2
    }

    public static func looksDangerous(_ text: String) -> Bool {
        let folded = fold(text)
        let words = ["delete", "remove", "erase", "send ", "purchase", "buy ", "pay ", "transfer", "format", "uninstall", "borra", "elimina", "quita", "envia", "manda", "compra", "paga", "transfiere", "formatea", "desinstala", "vacia la papelera", "empty the trash"]
        return words.contains { folded.contains($0) }
    }

    public static func looksLikeQuestion(_ text: String) -> Bool {
        let folded = fold(text).trimmingCharacters(in: .whitespaces)
        if folded.hasSuffix("?") || folded.hasPrefix("¿") { return true }
        let starters = ["what", "who", "when", "where", "why", "how", "is ", "are ", "do ", "does ", "can ", "could ", "que ", "quien", "cuando", "donde", "por que", "como", "cual", "cuanto", "es ", "hay "]
        return starters.contains { folded.hasPrefix($0) }
    }
}
