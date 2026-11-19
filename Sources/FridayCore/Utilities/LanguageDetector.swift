import Foundation

/// A small, dependency-free detector for the two supported languages. It scores function words and
/// command verbs that only occur in one language; accents and Spanish punctuation add weight.
public enum LanguageDetector {
    private static let spanishWords: Set<String> = [
        "el", "la", "los", "las", "un", "una", "unos", "unas", "de", "del", "al", "para", "por", "con", "sin", "mi", "mis", "tu",
        "que", "qué", "y", "o", "en", "es", "es", "está", "esta", "este", "muy", "pero", "también", "mañana", "hoy", "ayer",
        "pon", "ponme", "reproduce", "pausa", "pausar", "detén", "detener", "para", "siguiente", "anterior", "sube", "baja",
        "recuérdame", "recuerdame", "recuerda", "recordatorio", "recordatorios", "agrega", "agregar", "añade", "añadir", "anade",
        "crea", "crear", "muestra", "muéstrame", "muestrame", "lista", "listas", "busca", "buscar", "lee", "abre", "agenda",
        "agendar", "programa", "programar", "mueve", "mover", "reprograma", "elimina", "eliminar", "borra", "borrar", "cancela",
        "cancelar", "marca", "completa", "apaga", "enciende", "alarma", "alarmas", "temporizador", "reunión", "reunion", "cita",
        "nota", "notas", "carpeta", "calendario", "evento", "eventos", "semana", "mes", "lunes", "martes", "miércoles",
        "miercoles", "jueves", "viernes", "sábado", "sabado", "domingo", "tarde", "noche", "hora", "horas", "minutos",
        "canción", "cancion", "música", "musica", "volumen", "despiértame", "despiertame", "dime", "cuál", "cuales", "tengo",
        "tienes", "hay", "ayuda", "gracias", "sí", "si", "dale", "vale", "próximo", "proximo", "próxima", "proxima", "luego",
        "después", "despues", "durante", "llamada", "llamado", "llamada", "contenido", "siguiente", "título", "titulo",
    ]

    private static let englishWords: Set<String> = [
        "the", "a", "an", "to", "of", "my", "me", "on", "at", "in", "for", "and", "then", "with", "from", "is", "are", "what",
        "what's", "whats", "please", "play", "pause", "resume", "stop", "next", "previous", "skip", "remind", "reminder",
        "reminders", "add", "create", "show", "list", "search", "find", "read", "open", "schedule", "move", "reschedule",
        "delete", "remove", "cancel", "mark", "complete", "turn", "set", "alarm", "alarms", "timer", "meeting", "appointment",
        "note", "notes", "folder", "calendar", "event", "events", "week", "month", "tomorrow", "today", "tonight", "yesterday",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "morning", "afternoon", "evening",
        "night", "hour", "hours", "minutes", "song", "music", "volume", "wake", "tell", "have", "do", "does", "how", "playlist",
        "content", "called", "named", "titled", "following", "yes", "thanks", "help", "append", "update", "lasting", "next",
    ]

    /// Words that exist in both languages or are too ambiguous to count.
    private static let neutral: Set<String> = ["no", "ok", "a", "si", "es", "para", "me", "mi", "in", "on"]

    /// The assistant's names, which people prepend to a command ("Friday, pon música") or append after a comma.
    /// As a vocative they say nothing about the language ("friday" would otherwise count as the English weekday),
    /// so they are removed before scoring; "on Friday" / "el viernes" inside a sentence still count as weekdays.
    private static let leadingVocative = try! NSRegularExpression(
        pattern: #"^\s*(?:(?:hey|hi|hello|ok|okay|oye|hola|ey)[,\s]+)?(?:jarvis|friday)\b[,!\s]*"#,
        options: .caseInsensitive)
    private static let trailingVocative = try! NSRegularExpression(
        pattern: #",\s*(?:jarvis|friday)\s*[?!.]*\s*$"#, options: .caseInsensitive)

    /// `text` without a leading or trailing address to the assistant.
    public static func strippingVocative(_ text: String) -> String {
        var current = text
        let whole = NSRange(current.startIndex..., in: current)
        if let match = leadingVocative.firstMatch(in: current, range: whole), match.range.length < whole.length,
            let range = Range(match.range, in: current)
        {
            current.removeSubrange(range)
        }
        let rest = NSRange(current.startIndex..., in: current)
        if let match = trailingVocative.firstMatch(in: current, range: rest), let range = Range(match.range, in: current) {
            current.removeSubrange(range)
        }
        return current
    }

    public static func detect(_ text: String, fallback: Language = .en) -> Language {
        let (spanish, english) = scores(text)
        if spanish > english { return .es }
        if english > spanish { return .en }
        return fallback
    }

    /// The language a transcript is in, when its words say so clearly (a margin of two or more cues), else `heard`:
    /// the label of the recognizer lane that produced it. A bilingual recognizer's Spanish lane can transcribe an
    /// English sentence well enough to win ("What time is it?" labelled Spanish), and the reply must follow the words.
    public static func resolve(_ text: String, heard: Language?) -> Language? {
        let (spanish, english) = scores(text)
        if spanish - english >= 2 { return .es }
        if english - spanish >= 2 { return .en }
        return heard ?? (spanish > english ? .es : english > spanish ? .en : nil)
    }

    /// Spanish and English cue scores for `text` (function words, command verbs, accents, Spanish punctuation).
    public static func scores(_ text: String) -> (spanish: Double, english: Double) {
        var spanish = 0.0
        var english = 0.0
        let text = strippingVocative(text)

        if text.contains("¿") || text.contains("¡") { spanish += 3 }
        if text.range(of: "[ñáéíóúü]", options: [.regularExpression, .caseInsensitive]) != nil { spanish += 1.5 }

        let words = text.lowercased().split(whereSeparator: { !($0.isLetter || $0 == "'" || $0 == "’") }).map(String.init)
        for word in words {
            if neutral.contains(word) { continue }
            let folded = TextFolding.fold(word)
            if spanishWords.contains(word) || spanishWords.contains(folded) { spanish += 1 }
            if englishWords.contains(word) || englishWords.contains(folded) { english += 1 }
        }
        return (spanish, english)
    }
}
