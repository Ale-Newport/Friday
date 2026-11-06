import Foundation
import FridayCore

/// Conversational commands that need no tools: help, greetings, thanks.
struct MetaRules: IntentRuleSet {
    private static let help = Rx.make(#"^(?:help|\?|ayuda|ayudame|auxilio|what can you do|what do you do|what can i say|what can i ask|que puedes hacer|que sabes hacer|que puedo decir|que haces|commands|comandos|como funciona|how does this work|how do i use this|capabilities|capacidades|examples|ejemplos)\s*[?!.]*$"#)
    // A bare "Friday" / "Jarvis" (the person just called the assistant) is a greeting too.
    private static let greeting = Rx.make(#"^(?:hi|hello|hey|hola|buenas|buenos dias|buenas tardes|buenas noches|good morning|good afternoon|good evening|yo|ey|hiya|que tal|como estas|how are you|jarvis|friday)(?:[,\s]+(?:jarvis|friday))?\s*[?!.]*$"#)
    private static let thanks = Rx.make(#"^(?:thanks|thank you|thx|ty|gracias|muchas gracias|genial gracias|perfecto gracias|ok thanks|great thanks)(?:[,\s]+(?:jarvis|friday))?\s*[!.]*$"#)
    private static let identity = Rx.make(#"^(?:who are you|what are you|quien eres|que eres|como te llamas|what is your name|what's your name)\s*[?!.]*$"#)

    func interpret(_ clause: Clause) -> [RuleResult] {
        let text = clause.folded
        if clause.whole(Self.help, groups: []) != nil { return [.reply(Self.helpText, confidence: 0.99)] }
        if clause.whole(Self.thanks, groups: []) != nil {
            return [.reply(LocalizedText(en: "You're welcome!", es: "¡De nada!"), confidence: 0.98)]
        }
        if clause.whole(Self.identity, groups: []) != nil {
            return [.reply(LocalizedText(
                en: "I'm Friday, your Mac's assistant: I turn what you say or type into real actions — Music, Reminders, Notes, Calendar, Clock, Mail, Messages, files, the weather, web research and your Mac itself. Say “help” for examples.",
                es: "Soy Friday, el asistente de tu Mac: convierto lo que dices o escribes en acciones reales — Música, Recordatorios, Notas, Calendario, Reloj, Correo, Mensajes, archivos, el tiempo, búsquedas web y el propio Mac. Di «ayuda» para ver ejemplos."
            ), confidence: 0.98)]
        }
        if clause.whole(Self.greeting, groups: []) != nil, !text.isEmpty {
            return [.reply(LocalizedText(
                en: "Hello! Tell me what to do — Music, Reminders, Notes, Calendar, Clock, Mail, Messages, files, weather, the web or your Mac — and say “help” for examples.",
                es: "¡Hola! Dime qué hacer — Música, Recordatorios, Notas, Calendario, Reloj, Correo, Mensajes, archivos, el tiempo, la web o tu Mac — y di «ayuda» para ver ejemplos."
            ), confidence: 0.97)]
        }
        return []
    }

    static let helpText = LocalizedText(
        en: """
        I'm Friday. I can work with Music, Reminders, Notes, Calendar, Clock, Mail, Messages, your files, the weather, the web and your Mac. Try:
        • Play my Study playlist · Pause the music · What's playing? · Volume 40
        • Remind me tomorrow at 6 PM to submit my assignment · Add milk to my Shopping reminders list · Show my pending reminders
        • Create a note called Project Ideas with the following content: … · Append … to my Project Ideas note
        • What's on my calendar tomorrow? · Schedule a meeting with Daniel on Friday at 3 PM for one hour · Move my meeting to 4 PM
        • Set an alarm for 7:30 tomorrow morning · Set a timer for 10 minutes · Set a Friday timer for 25 minutes
        • Draft an email to Ana about the invoice · Send a message to Pablo saying I'm running late · Read my latest emails
        • What's the weather in Madrid tomorrow? · Search the web for the best pasta recipe
        • Find PDFs in my Downloads · Open Safari · Set the volume to 30 · What's on my screen?
        You can chain actions: “Play my Chill playlist and remind me to study at 8 PM”. I always ask before sending or deleting anything.
        """,
        es: """
        Soy Friday. Puedo trabajar con Música, Recordatorios, Notas, Calendario, Reloj, Correo, Mensajes, tus archivos, el tiempo, la web y tu Mac. Prueba:
        • Pon mi lista Study · Pausa la música · ¿Qué suena? · Volumen 40
        • Recuérdame mañana a las 6 PM entregar mi tarea · Agrega leche a mi lista de recordatorios Compras · Muestra mis recordatorios pendientes
        • Crea una nota llamada Ideas con el siguiente contenido: … · Añade … a mi nota Ideas
        • ¿Qué tengo en mi calendario mañana? · Agenda una reunión con Daniel el viernes a las 3 PM por una hora · Mueve mi reunión a las 4 PM
        • Pon una alarma a las 7:30 de la mañana · Pon un temporizador de 10 minutos · Pon un temporizador de Friday de 25 minutos
        • Redacta un correo a Ana sobre la factura · Envía un mensaje a Pablo diciendo que llego tarde · Lee mis últimos correos
        • ¿Qué tiempo hará en Madrid mañana? · Busca en la web la mejor receta de pasta
        • Busca PDFs en mis Descargas · Abre Safari · Pon el volumen al 30 · ¿Qué hay en mi pantalla?
        Puedes encadenar acciones: «Pon mi lista Chill y recuérdame estudiar a las 8 PM». Siempre pregunto antes de enviar o borrar algo.
        """
    )
}
