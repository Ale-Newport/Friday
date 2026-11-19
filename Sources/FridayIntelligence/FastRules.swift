import Foundation
import FridayCore
import FridayInterpreter

/// A handful of universal, model-free answers (time and date), in English and Spanish. Everything else that is
/// deterministic lives in the Apple-Integrations parser; these only cover tools that project did not have.
public enum FastRules {
    static let timePatterns = [
        "what time is it", "what's the time", "whats the time", "tell me the time", "current time", "the time",
        "que hora es", "qué hora es", "dime la hora", "la hora", "hora es", "que hora tenemos",
    ]
    static let datePatterns = [
        "what's the date", "whats the date", "what is the date", "what day is it", "what's today's date", "today's date", "which day is it", "what day is today", "what's the date today",
        "que dia es hoy", "qué día es hoy", "que fecha es", "qué fecha es", "a que dia estamos", "a qué día estamos", "en que dia estamos", "que dia es", "que fecha es hoy", "que dia es hoy",
    ]
    /// Words around a time/date question that do not change it ("Friday, what time is it, please").
    static let leadingFillers = ["friday", "jarvis", "oye", "hey", "hola", "dime", "tell me", "sabes", "do you know", "me dices", "me puedes decir", "puedes decirme", "can you tell me", "could you tell me", "por favor", "please", "y", "and", "so", "entonces"]
    static let trailingFillers = ["por favor", "please", "ahora", "ahora mismo", "right now", "now", "friday", "jarvis", "gracias", "thanks", "thank you"]

    static let openVerbs = ["open", "launch", "start", "abre", "abrir", "lanza", "inicia", "ejecuta"]
    static let closeVerbs = ["close", "quit", "cierra", "cerrar", "sal de"]
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

    // Timers. The control verb must come BEFORE the timer word: "para el temporizador" cancels, "pon un
    // temporizador para 10 minutos" creates ("para" is also the preposition "for").
    static let timerWords: Set<String> = ["timer", "timers", "temporizador", "temporizadores", "countdown"]
    static let timerCancelVerbs: Set<String> = ["cancel", "cancela", "cancelar", "cancelame", "stop", "para", "parar", "deten", "detener", "quita", "quitar", "quitame", "delete", "borra", "borrar", "elimina", "eliminar", "apaga", "apagar", "remove", "kill", "end", "termina", "terminar"]
    static let timerCreateVerbs: Set<String> = ["set", "start", "create", "make", "put", "pon", "ponme", "poner", "crea", "creame", "inicia", "empieza", "arranca", "activa", "programa", "lanza", "new", "nuevo", "nueva"]
    /// Other timer controls: never a creation, and not handled by a fast rule (the model has the timer list).
    static let timerOtherControls: Set<String> = ["pause", "pausa", "pausar", "resume", "reanuda", "reanudar", "continua", "continuar", "extend", "extiende", "alarga", "add", "anade", "agrega", "suma", "list", "lista", "cuantos", "how", "cuanto", "queda", "quedan", "left", "remaining", "check"]
    /// What may follow a leading Spanish "para" for it to mean "stop" rather than "for".
    static let paraStopFollowers: Set<String> = ["el", "la", "los", "las", "mi", "mis", "ese", "esa", "este", "esta", "todos", "todo", "ya", "temporizador", "temporizadores", "timer", "countdown"]

    public static func plan(for text: String, language: Language, tools: [ToolDescriptor], installedApps: [String: String] = [:]) -> ToolPlan? {
        let folded = KeywordRouter.fold(text).trimmingCharacters(in: CharacterSet(charactersIn: " ?¿!¡.,"))
        let has: (String) -> Bool = { name in tools.contains { $0.name.rawValue == name } }
        // A compound command ("set a timer for 10 minutes and remind me to call mom") is never a fast rule: the rule
        // would run one clause and silently drop the rest. The model (or the clause-aware parser) handles it.
        // Fillers go first so "Friday, what time is it" is not read as two clauses.
        guard !KeywordRouter.looksMultistep(folded), DeterministicInterpreter.clauseCount(stripFillers(folded)) <= 1 else { return nil }
        // Explicit memory: "remember that my study playlist is called Deep Focus".
        if has("memory.remember") {
            for prefix in rememberPrefixes where folded.hasPrefix(KeywordRouter.fold(prefix)) {
                let content = String(text.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: " .,"))
                guard content.count >= 4 else { break }
                return ToolPlan(steps: [ToolCall(tool: "memory.remember", arguments: ["content": .string(content), "kind": "preference"], sourceText: text)], language: language, interpreter: "fast-rule")
            }
        }
        // Friday-native timers ("set a timer for 25 minutes", "pon un temporizador de 10 minutos", "stop the timer").
        // Timer control words map to Friday's own timers (native Clock timers need user-made Shortcuts).
        if has("jarvis_timers.cancel"), isTimerCancel(folded) {
            // No label: the integration cancels the only running timer, or offers the running ones as options.
            return ToolPlan(steps: [ToolCall(tool: "jarvis_timers.cancel", sourceText: text)], language: language, interpreter: "fast-rule")
        }
        if has("jarvis_timers.create"), isTimerCreation(folded), let seconds = timerSeconds(folded) {
            return ToolPlan(steps: [ToolCall(tool: "jarvis_timers.create", arguments: ["duration_seconds": .int(seconds), "label": .string(language == .es ? "Temporizador" : "Timer")], sourceText: text)], language: language, interpreter: "fast-rule")
        }
        if let expression = arithmetic(folded, language: language), tools.contains(where: { $0.name.rawValue == "utilities.calculate" }) {
            return ToolPlan(steps: [ToolCall(tool: "utilities.calculate", arguments: ["expression": .string(expression)], sourceText: text)], language: language, interpreter: "fast-rule")
        }
        if let app = appCommand(folded, verbs: openVerbs, installedApps: installedApps), tools.contains(where: { $0.name.rawValue == "system.open_app" }) {
            return ToolPlan(steps: [ToolCall(tool: "system.open_app", arguments: ["application": .string(app)], sourceText: text)], language: language, interpreter: "fast-rule")
        }
        if let app = appCommand(folded, verbs: closeVerbs, installedApps: installedApps), tools.contains(where: { $0.name.rawValue == "system.close_app" }) {
            return ToolPlan(steps: [ToolCall(tool: "system.close_app", arguments: ["application": .string(app)], sourceText: text)], language: language, interpreter: "fast-rule")
        }
        guard folded.count <= 40, tools.contains(where: { $0.name.rawValue == "friday.current_time" }) else { return nil }
        // The whole utterance (minus fillers) must be the question: "qué hora es la reunión" is about the meeting.
        let stripped = stripFillers(folded)
        let matches = (timePatterns + datePatterns).contains { stripped == KeywordRouter.fold($0) }
        guard matches else { return nil }
        return ToolPlan(steps: [ToolCall(tool: "friday.current_time", sourceText: text)], language: language, interpreter: "fast-rule")
    }

    /// Drops leading/trailing filler words repeatedly ("hey friday what time is it please" → "what time is it").
    static func stripFillers(_ folded: String) -> String {
        var text = folded.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
        var changed = true
        while changed {
            changed = false
            for filler in leadingFillers where text.hasPrefix(filler + " ") || text.hasPrefix(filler + ", ") {
                text = String(text.dropFirst(filler.count)).trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
                changed = true
            }
            for filler in trailingFillers where text.hasSuffix(" " + filler) || text.hasSuffix(", " + filler) {
                text = String(text.dropLast(filler.count)).trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
                changed = true
            }
        }
        return text
    }

    static func words(_ folded: String) -> [String] {
        folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// "cancel the timer", "para el temporizador", "stop my pasta timer": a cancel verb before the timer word, and
    /// no creation verb ahead of it ("pon un temporizador para 10 minutos" is a creation).
    static func isTimerCancel(_ folded: String) -> Bool {
        let tokens = words(folded)
        guard let timerIndex = tokens.firstIndex(where: { timerWords.contains($0) }) else { return false }
        let before = Array(tokens[..<timerIndex])
        guard let cancelIndex = before.firstIndex(where: { token in
            if token == "para" || token == "parar" {
                // "para" is "for" unless it starts the command and is followed by the timer or an article.
                guard let position = before.firstIndex(of: token), position == 0 else { return false }
                let next = before.count > 1 ? before[1] : "temporizador"
                return paraStopFollowers.contains(next)
            }
            return timerCancelVerbs.contains(token)
        }) else { return false }
        if let createIndex = before.firstIndex(where: { timerCreateVerbs.contains($0) }), createIndex < cancelIndex { return false }
        return true
    }

    /// A timer command that is not a cancel/pause/resume/extend/list ("set a timer…", "temporizador de 10 minutos").
    static func isTimerCreation(_ folded: String) -> Bool {
        let tokens = words(folded)
        guard tokens.contains(where: { timerWords.contains($0) || $0 == "cuenta" }) else { return false }
        if isTimerCancel(folded) { return false }
        let controls = timerCancelVerbs.subtracting(["para", "parar"]).union(timerOtherControls)
        return !tokens.contains(where: { controls.contains($0) })
    }

    /// "open Chrome" / "abre Notas" → the app name; nil for anything that is not a plain launch of an installed
    /// application ("open youtube", "start recording", "cierra todo" are left to the router and the model).
    static func appCommand(_ folded: String, verbs: [String], installedApps: [String: String]) -> String? {
        for verb in verbs {
            guard folded.hasPrefix(verb + " ") else { continue }
            var rest = String(folded.dropFirst(verb.count + 1)).trimmingCharacters(in: .whitespaces)
            for filler in ["please", "por favor", "the app", "la app", "la aplicacion", "app", "instead", "then", "now", "mejor", "entonces", "ahora", "ya"] where rest.hasSuffix(" " + filler) {
                rest = String(rest.dropLast(filler.count + 1)).trimmingCharacters(in: .whitespaces)
            }
            for article in articles where rest.hasPrefix(article) { rest = String(rest.dropFirst(article.count)).trimmingCharacters(in: .whitespaces); break }
            guard !rest.isEmpty, !rest.contains("http"), !rest.contains(".com"), !rest.contains("."), !rest.contains("/") else { return nil }
            if let alias = appAliases[rest] {
                // An alias of an app that is not installed (no Chrome) is better handled by the model (a website, say).
                return installedApps.isEmpty || installedApps[KeywordRouter.fold(alias)] != nil ? alias : nil
            }
            guard rest.split(separator: " ").count <= 3, let installed = installedApps[rest] else { return nil }
            return installed
        }
        return nil
    }

    static let numberWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90, "forty five": 45,
        "an": 1, "a": 1, "un": 1, "una": 1, "uno": 1, "dos": 2, "tres": 3, "cuatro": 4, "cinco": 5, "seis": 6, "siete": 7, "ocho": 8, "nueve": 9, "diez": 10,
        "once": 11, "doce": 12, "trece": 13, "catorce": 14, "quince": 15, "dieciseis": 16, "diecisiete": 17, "dieciocho": 18, "diecinueve": 19,
        "veinte": 20, "veintiuno": 21, "veintiun": 21, "veintidos": 22, "veintitres": 23, "veinticuatro": 24, "veinticinco": 25, "veintiseis": 26, "veintisiete": 27, "veintiocho": 28, "veintinueve": 29,
        "treinta": 30, "cuarenta": 40, "cincuenta": 50, "sesenta": 60, "setenta": 70, "ochenta": 80, "noventa": 90, "cuarenta y cinco": 45,
        "media": 0, "half": 0,
    ]

    /// "forty five", "twenty-five", "cuarenta y cinco", "veinticinco" → 45 / 25 / 45 / 25.
    static func spelledNumber(_ text: String) -> Double? {
        if let direct = numberWords[text] { return Double(direct) }
        let parts = text.replacingOccurrences(of: "-", with: " ").split(separator: " ").map(String.init).filter { $0 != "y" && $0 != "and" }
        if parts.count == 1, let single = numberWords[parts[0]] { return Double(single) }
        guard parts.count == 2, let tens = numberWords[parts[0]], tens >= 20, tens % 10 == 0, let units = numberWords[parts[1]], (1...9).contains(units) else { return nil }
        return Double(tens + units)
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
        // Amounts: digits, one spelled number, or two ("forty five", "twenty-five", "cuarenta y cinco").
        let pattern = try! NSRegularExpression(pattern: #"(\d+(?:[.,]\d+)?|[a-z]+(?:(?:[ -]|[ -]y[ -]|[ -]and[ -])[a-z]+)?)\s*(hours?|hora|horas|h\b|minutes?|minutos?|mins?\b|min\b|seconds?|segundos?|secs?\b|s\b)"#)
        var total = 0.0
        for match in pattern.matches(in: folded, range: NSRange(folded.startIndex..., in: folded)) {
            guard let amountRange = Range(match.range(at: 1), in: folded), let unitRange = Range(match.range(at: 2), in: folded) else { continue }
            let amountText = String(folded[amountRange]).replacingOccurrences(of: ",", with: ".")
            let unit = String(folded[unitRange])
            var amount = Double(amountText) ?? spelledNumber(amountText)
            if amount == nil, let last = amountText.split(whereSeparator: { $0 == " " || $0 == "-" }).last {
                // "for ten minutes": the regex took "for ten"; the number is the last word.
                amount = numberWords[String(last)].map(Double.init)
                if amount != nil, last == "media" || last == "half" { amount = 0.5 }
            }
            guard let value = amount.map({ amountText == "media" || amountText == "half" ? 0.5 : $0 }) else { continue }
            if unit.hasPrefix("h") { total += value * 3600 } else if unit.hasPrefix("min") || unit.hasPrefix("m") { total += value * 60 } else { total += value }
        }
        if folded.contains("y media") || folded.contains("and a half") { total += total >= 3600 ? 1800 : 30 }
        let seconds = Int(total.rounded())
        return seconds > 0 && seconds <= 604_800 ? seconds : nil
    }

    /// "what's 17 times 24" / "cuánto es 3 por 4 más 2" → "17*24" / "3*4+2"; nil unless the whole thing is arithmetic.
    /// Digit grouping follows the language: "2,450" is two thousand four hundred and fifty in English and "2.450" in
    /// Spanish; a lone comma is a decimal point in either ("2,5" → 2.5).
    static func arithmetic(_ folded: String, language: Language = .en) -> String? {
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
        text = normalizeNumbers(text, language: language).trimmingCharacters(in: .whitespaces)
        let allowed = CharacterSet(charactersIn: "0123456789+-*/^(). %")
        guard !text.isEmpty, text.unicodeScalars.allSatisfy({ allowed.contains($0) }), text.rangeOfCharacter(from: .decimalDigits) != nil,
            text.rangeOfCharacter(from: CharacterSet(charactersIn: "+-*/^")) != nil
        else { return nil }
        return text.replacingOccurrences(of: " ", with: "")
    }

    /// Rewrites grouped numbers into plain decimals: thousands separators are removed and the decimal separator
    /// becomes ".". English groups with "," ("1,234,567.5"); Spanish with "." ("1.234.567,5"). Anything that is not a
    /// well-formed grouped number keeps the old behaviour: a comma is a decimal point.
    static func normalizeNumbers(_ text: String, language: Language) -> String {
        let (group, decimal) = language == .es ? (#"\."#, ",") : (",", #"\."#)
        let pattern = #"(?<![\d.,])\d{1,3}(?:"# + group + #"\d{3})+(?:"# + decimal + #"\d+)?(?![\d.,]*\d)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text.replacingOccurrences(of: ",", with: ".") }
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let token = String(result[range])
            let plain = language == .es
                ? token.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
                : token.replacingOccurrences(of: ",", with: "")
            result.replaceSubrange(range, with: plain)
        }
        return result.replacingOccurrences(of: ",", with: ".")
    }
}

/// The applications installed on this Mac (folded name → display name), scanned with FileManager so the planner
/// needs no AppKit, and refreshed every few minutes. Lets the fast path open only apps that exist.
public final class InstalledApplications: @unchecked Sendable {
    public static let shared = InstalledApplications()

    private let lock = NSLock()
    private var cache: (names: [String: String], at: Date)?
    private let roots: [String]
    private let lifetime: TimeInterval

    public init(roots: [String]? = nil, lifetime: TimeInterval = 300) {
        self.roots = roots ?? [
            "/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
            "/System/Library/CoreServices", NSHomeDirectory() + "/Applications",
        ]
        self.lifetime = lifetime
    }

    public func names(now: Date = Date()) -> [String: String] {
        lock.withLock {
            if let cache, now.timeIntervalSince(cache.at) < lifetime { return cache.names }
            let names = Self.scan(roots)
            cache = (names, now)
            return names
        }
    }

    static func scan(_ roots: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for root in roots {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            for item in items where item.hasSuffix(".app") {
                let name = String(item.dropLast(4))
                result[KeywordRouter.fold(name)] = name
            }
        }
        return result
    }
}
