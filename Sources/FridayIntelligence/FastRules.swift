import Foundation
import FridayCore

/// A handful of universal, model-free answers (time and date), in English and Spanish. Everything else that is
/// deterministic lives in the Apple-Integrations parser; these only cover tools that project did not have.
public enum FastRules {
    static let timePatterns = [
        "what time is it", "what's the time", "whats the time", "tell me the time", "current time",
        "que hora es", "qué hora es", "dime la hora", "la hora", "hora es",
    ]
    static let datePatterns = [
        "what's the date", "whats the date", "what is the date", "what day is it", "what's today's date", "today's date", "which day is it",
        "que dia es hoy", "qué día es hoy", "que fecha es", "qué fecha es", "a que dia estamos", "a qué día estamos", "en que dia estamos", "que dia es",
    ]

    static let openVerbs = ["open", "launch", "start", "abre", "abrir", "lanza", "inicia", "ejecuta"]
    static let closeVerbs = ["close", "quit", "cierra", "cerrar", "sal de"]
    /// Words that mean the object is not an application name ("open my notes about Japan"), matched as whole words.
    static let notAnApp: Set<String> = ["my", "a", "an", "mi", "mis", "un", "una", "this", "that", "esto", "eso", "file", "archivo", "folder", "carpeta", "note", "nota", "link", "url", "page", "pagina", "website", "web", "tab", "pestana", "result", "resultado", "document", "documento", "pdf", "window", "ventana", "door", "puerta", "email", "correo electronico", "mail", "message", "mensaje"]
    /// Articles dropped before the app name ("abre la Calculadora", "open the Calendar").
    static let articles = ["the ", "el ", "la ", "los ", "las "]

    /// Spanish (and spoken) names of the apps people open most, mapped to the bundle names macOS knows.
    static let appAliases: [String: String] = [
        "notas": "Notes", "recordatorios": "Reminders", "calendario": "Calendar", "musica": "Music", "apple music": "Music",
        "correo": "Mail", "mensajes": "Messages", "calculadora": "Calculator", "fotos": "Photos", "contactos": "Contacts",
        "ajustes": "System Settings", "ajustes del sistema": "System Settings", "configuracion": "System Settings", "preferencias del sistema": "System Settings",
        "system preferences": "System Settings", "settings": "System Settings", "vista previa": "Preview", "mapas": "Maps", "terminal": "Terminal",
        "navegador": "Safari", "google chrome": "Google Chrome", "chrome": "Google Chrome", "finder": "Finder", "app store": "App Store",
        "tienda de apps": "App Store", "reloj": "Clock", "clock": "Clock", "notes": "Notes", "reminders": "Reminders", "calendar": "Calendar",
        "music": "Music", "mail": "Mail", "messages": "Messages", "calculator": "Calculator", "photos": "Photos", "contacts": "Contacts",
        "preview": "Preview", "maps": "Maps", "safari": "Safari", "atajos": "Shortcuts", "shortcuts": "Shortcuts", "tiempo": "Weather", "weather": "Weather",
        "bolsa": "Stocks", "notas de voz": "Voice Memos", "voice memos": "Voice Memos", "facetime": "FaceTime", "libros": "Books", "books": "Books",
        "podcasts": "Podcasts", "tv": "TV", "freeform": "Freeform", "keynote": "Keynote", "pages": "Pages", "numbers": "Numbers", "xcode": "Xcode",
    ]

    static let rememberPrefixes = ["remember that ", "remember: ", "please remember that ", "recuerda que ", "acuerdate de que ", "acuérdate de que ", "apunta que ", "ten en cuenta que ", "note that "]

    public static func plan(for text: String, language: Language, tools: [ToolDescriptor]) -> ToolPlan? {
        let folded = KeywordRouter.fold(text).trimmingCharacters(in: CharacterSet(charactersIn: " ?¿!¡.,"))
        let has: (String) -> Bool = { name in tools.contains { $0.name.rawValue == name } }
        // Explicit memory: "remember that my study playlist is called Deep Focus".
        if has("memory.remember") {
            for prefix in rememberPrefixes where folded.hasPrefix(KeywordRouter.fold(prefix)) {
                let content = String(text.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: " .,"))
                guard content.count >= 4 else { break }
                return ToolPlan(steps: [ToolCall(tool: "memory.remember", arguments: ["content": .string(content), "kind": "preference"], sourceText: text)], language: language, interpreter: "fast-rule")
            }
        }
        // Friday-native timers ("set a timer for 25 minutes", "pon un temporizador de 10 minutos").
        // Timer control words map to Friday's own timers (native Clock timers need user-made Shortcuts).
        if has("jarvis_timers.cancel"), (folded.contains("timer") || folded.contains("temporizador")), ["cancel", "cancela", "stop", "para ", "quita", "delete", "borra", "elimina"].contains(where: { folded.hasPrefix($0) || folded.contains(" " + $0) }) {
            return ToolPlan(steps: [ToolCall(tool: "jarvis_timers.cancel", arguments: ["label": .string(language == .es ? "Temporizador" : "Timer")], sourceText: text)], language: language, interpreter: "fast-rule")
        }
        if has("jarvis_timers.create"), let seconds = timerSeconds(folded) {
            return ToolPlan(steps: [ToolCall(tool: "jarvis_timers.create", arguments: ["duration_seconds": .int(seconds), "label": .string(language == .es ? "Temporizador" : "Timer")], sourceText: text)], language: language, interpreter: "fast-rule")
        }
        if let expression = arithmetic(folded), tools.contains(where: { $0.name.rawValue == "utilities.calculate" }) {
            return ToolPlan(steps: [ToolCall(tool: "utilities.calculate", arguments: ["expression": .string(expression)], sourceText: text)], language: language, interpreter: "fast-rule")
        }
        if let app = appCommand(folded, verbs: openVerbs), tools.contains(where: { $0.name.rawValue == "system.open_app" }) {
            return ToolPlan(steps: [ToolCall(tool: "system.open_app", arguments: ["application": .string(app)], sourceText: text)], language: language, interpreter: "fast-rule")
        }
        if let app = appCommand(folded, verbs: closeVerbs), tools.contains(where: { $0.name.rawValue == "system.close_app" }) {
            return ToolPlan(steps: [ToolCall(tool: "system.close_app", arguments: ["application": .string(app)], sourceText: text)], language: language, interpreter: "fast-rule")
        }
        guard folded.count <= 40, tools.contains(where: { $0.name.rawValue == "friday.current_time" }) else { return nil }
        let matches = (timePatterns + datePatterns).contains { pattern in
            let p = KeywordRouter.fold(pattern)
            return folded == p || folded.hasPrefix(p + " ") || folded.hasSuffix(" " + p) || folded == "jarvis " + p
        }
        guard matches else { return nil }
        return ToolPlan(steps: [ToolCall(tool: "friday.current_time", sourceText: text)], language: language, interpreter: "fast-rule")
    }

    /// "open Chrome" / "abre Notas" → the app name; nil for anything that is not a plain app launch.
    static func appCommand(_ folded: String, verbs: [String]) -> String? {
        for verb in verbs {
            guard folded.hasPrefix(verb + " ") else { continue }
            var rest = String(folded.dropFirst(verb.count + 1)).trimmingCharacters(in: .whitespaces)
            for filler in ["please", "por favor", "the app", "la app", "la aplicacion", "app"] where rest.hasSuffix(" " + filler) {
                rest = String(rest.dropLast(filler.count + 1)).trimmingCharacters(in: .whitespaces)
            }
            for article in articles where rest.hasPrefix(article) { rest = String(rest.dropFirst(article.count)).trimmingCharacters(in: .whitespaces); break }
            if let alias = appAliases[rest] { return alias }
            let words = rest.split(separator: " ").map(String.init)
            guard !rest.isEmpty, words.count <= 3, !words.contains(where: { notAnApp.contains($0) }),
                !rest.contains("http"), !rest.contains(".com"), !rest.contains("."), !rest.contains("/")
            else { return nil }
            return rest.capitalized
        }
        return nil
    }

    /// "set a timer for 25 minutes" / "temporizador de 90 segundos" / "timer for 1 hour and a half" → seconds.
    static func timerSeconds(_ raw: String) -> Int? {
        var folded = raw
        for (phrase, replacement) in [
            ("minuto y medio", "1.5 minutos"), ("a minute and a half", "1.5 minutes"), ("one and a half minutes", "1.5 minutes"), ("hora y media", "1.5 horas"),
            ("an hour and a half", "1.5 hours"), ("one and a half hours", "1.5 hours"), ("media hora", "0.5 horas"), ("half an hour", "0.5 hours"), ("medio minuto", "0.5 minutos"),
            ("half a minute", "0.5 minutes"), ("un cuarto de hora", "15 minutos"), ("a quarter of an hour", "15 minutes"), ("tres cuartos de hora", "45 minutos"),
        ] { folded = folded.replacingOccurrences(of: phrase, with: replacement) }
        guard folded.contains("timer") || folded.contains("temporizador") || folded.contains("cuenta atras") || folded.contains("countdown") else { return nil }
        guard !folded.contains("cancel") && !folded.contains("cancela") && !folded.contains("pause") && !folded.contains("pausa") && !folded.contains("stop") && !folded.contains("para ") else { return nil }
        let numberWords: [String: Int] = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "ten": 10, "fifteen": 15, "twenty": 20, "thirty": 30, "forty": 40, "forty five": 45, "sixty": 60, "an": 1, "a": 1, "un": 1, "una": 1, "uno": 1, "dos": 2, "tres": 3, "cuatro": 4, "cinco": 5, "diez": 10, "quince": 15, "veinte": 20, "treinta": 30, "cuarenta": 40, "cuarenta y cinco": 45, "sesenta": 60, "media": 0, "half": 0]
        let pattern = try! NSRegularExpression(pattern: #"(\d+(?:[.,]\d+)?|[a-z]+(?: y cinco)?)\s*(hours?|hora|horas|h\b|minutes?|minutos?|mins?\b|min\b|seconds?|segundos?|secs?\b|s\b)"#)
        var total = 0.0
        for match in pattern.matches(in: folded, range: NSRange(folded.startIndex..., in: folded)) {
            guard let amountRange = Range(match.range(at: 1), in: folded), let unitRange = Range(match.range(at: 2), in: folded) else { continue }
            let amountText = String(folded[amountRange]).replacingOccurrences(of: ",", with: ".")
            let unit = String(folded[unitRange])
            guard let amount = Double(amountText) ?? numberWords[amountText].map(Double.init) else { continue }
            let value = amountText == "media" || amountText == "half" ? 0.5 : amount
            if unit.hasPrefix("h") { total += value * 3600 } else if unit.hasPrefix("min") || unit.hasPrefix("m") { total += value * 60 } else { total += value }
        }
        if folded.contains("y media") || folded.contains("and a half") { total += total >= 3600 ? 1800 : 30 }
        let seconds = Int(total.rounded())
        return seconds > 0 && seconds <= 604_800 ? seconds : nil
    }

    /// "what's 17 times 24" / "cuánto es 3 por 4 más 2" → "17*24" / "3*4+2"; nil unless the whole thing is arithmetic.
    static func arithmetic(_ folded: String) -> String? {
        var text = folded
        for prefix in ["what's ", "whats ", "what is ", "how much is ", "calculate ", "compute ", "cuanto es ", "cuanto son ", "cuanto da ", "calcula ", "calculame ", "dime cuanto es "] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
            break
        }
        let replacements: [(String, String)] = [
            (" multiplied by ", "*"), (" multiplicado por ", "*"), (" times ", "*"), (" por ", "*"), (" x ", "*"),
            (" divided by ", "/"), (" dividido entre ", "/"), (" dividido por ", "/"), (" entre ", "/"), (" over ", "/"),
            (" plus ", "+"), (" mas ", "+"), (" and ", "+"), (" minus ", "-"), (" menos ", "-"),
            (" to the power of ", "^"), (" elevado a ", "^"), (" squared", "^2"), (" al cuadrado", "^2"), (" cubed", "^3"), (" al cubo", "^3"),
            (" percent of ", "/100*"), (" por ciento de ", "/100*"), ("% of ", "/100*"), ("% de ", "/100*"),
        ]
        text = " " + text + " "
        for (word, symbol) in replacements { text = text.replacingOccurrences(of: word, with: symbol) }
        text = text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        let allowed = CharacterSet(charactersIn: "0123456789+-*/^(). %")
        guard !text.isEmpty, text.unicodeScalars.allSatisfy({ allowed.contains($0) }), text.rangeOfCharacter(from: .decimalDigits) != nil,
            text.rangeOfCharacter(from: CharacterSet(charactersIn: "+-*/^")) != nil
        else { return nil }
        return text.replacingOccurrences(of: " ", with: "")
    }
}
