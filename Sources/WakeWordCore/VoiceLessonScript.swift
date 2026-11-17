import Foundation

/// What a person is asked to say while teaching the app their voice, and how many times. Data, not logic: the session
/// (``VoiceLesson``) walks through it.
public struct VoiceLessonScript: Equatable, Sendable {
    public struct Step: Equatable, Sendable, Identifiable {
        public enum Kind: Equatable, Sendable {
            /// A phrase to say `count` times; each time the person pauses, one more is counted.
            case phrases(count: Int, maximumSeconds: Double)
            /// Ordinary talk without the word, read from `passages`, until `targetSeconds` of speech have been heard.
            case reading(targetSeconds: Double, minimumSeconds: Double)
        }

        public var id: String
        public var title: String
        public var instruction: String
        /// What to say, one entry per utterance (cycling when there are more utterances than entries); for a reading, the paragraphs.
        public var prompts: [String]
        public var kind: Kind

        public init(id: String, title: String, instruction: String, prompts: [String], kind: Kind) {
            self.id = id
            self.title = title
            self.instruction = instruction
            self.prompts = prompts
            self.kind = kind
        }

        /// How many utterances this step asks for (0 for a reading).
        public var requiredCount: Int {
            if case .phrases(let count, _) = kind { count } else { 0 }
        }

        /// The least that lets the person go on without finishing the step.
        public var minimumCount: Int {
            switch kind {
            case .phrases(let count, _): max(1, (count * 3 + 4) / 5)
            case .reading: 0
            }
        }

        public var isReading: Bool {
            if case .reading = kind { true } else { false }
        }

        /// The phrase to show for the utterance after `heard` have been counted.
        public func prompt(after heard: Int) -> String {
            prompts.isEmpty ? "" : prompts[heard % prompts.count]
        }
    }

    public var steps: [Step]
    /// Seconds of the room's own sound to listen to before the first step, to know what counts as speech.
    public var calibrationSeconds: Double
    /// A pause this long ends a phrase (see ``UtteranceSplitter``).
    public var pause: Double
    /// Sounds shorter than this are not phrases.
    public var shortest: Double
    /// Most audio the lesson can hold, in seconds (a lesson takes about four minutes; the rest is room for do-overs).
    public var maximumSeconds: Double

    public init(steps: [Step], calibrationSeconds: Double = 2, pause: Double = 0.45, shortest: Double = 0.25, maximumSeconds: Double = 480) {
        self.steps = steps
        self.calibrationSeconds = calibrationSeconds
        self.pause = pause
        self.shortest = shortest
        self.maximumSeconds = maximumSeconds
    }

    /// The utterances the lesson asks for in all.
    public var phraseCount: Int { steps.reduce(0) { $0 + $1.requiredCount } }

    /// Four minutes: the name on its own, the name called the way the person really calls it, a request after it, and ordinary
    /// talk — in the two languages the app's owner mixes.
    public static let standard = VoiceLessonScript(steps: [
        Step(
            id: "jarvis", title: "Say “Jarvis”",
            instruction: "Just the name, the way you say it day to day. Leave about a second between one and the next.",
            prompts: ["Jarvis"], kind: .phrases(count: 12, maximumSeconds: 3)
        ),
        Step(
            id: "hey-jarvis", title: "Call it",
            instruction: "As you really would, with the words run together. Use “hey”, “oye” or “ok” — whichever you use.",
            prompts: ["Hey Jarvis", "Oye Jarvis", "Ok Jarvis"], kind: .phrases(count: 10, maximumSeconds: 4)
        ),
        Step(
            id: "commands", title: "Ask it something",
            instruction: "The name and then the request, in one go.",
            prompts: [
                "Hey Jarvis, what time is it?", "Jarvis, enciende la luz", "Oye Jarvis, dime la hora",
                "Ok Jarvis, play some music", "Jarvis, abre la puerta", "Jarvis, ¿qué tiempo hace?",
            ],
            kind: .phrases(count: 6, maximumSeconds: 7)
        ),
        Step(
            id: "talk", title: "Now just talk",
            instruction: "Read this aloud at your usual pace — Friday learns what is not its wake word.",
            prompts: [
                "Esta mañana me levanté temprano y salí a dar un paseo antes de que hiciera calor. En la panadería de la esquina compré pan recién hecho y un par de cruasanes. De vuelta en casa, mi hermana ya había preparado café, así que abrí las ventanas y estuve un rato leyendo el periódico mientras la ciudad se despertaba. Luego revisé el calendario: reunión a las diez, comida con mi hermano y, por la tarde, una llamada con Javier para hablar del viaje de septiembre. Los niños ya habían salido al jardín cuando terminé.",
                "On weekends I like to cook something slowly and listen to music. Yesterday I tried a new recipe with roasted vegetables, rice and a little lemon. It took longer than I expected, but the kitchen smelled wonderful. After dinner we watched a documentary about the ocean, and my sister reminded me that the forecast for tomorrow is cloudy, with a chance of rain in the afternoon.",
                "Mañana tengo que terminar el informe y enviárselo a Marta antes de las cinco; ayer, cuando llegué a la oficina, la reunión ya había empezado. Después quiero pasar por el gimnasio, comprar algo de fruta y llamar a mis padres. Si me queda tiempo, ordenaré un poco el escritorio y prepararé la lista de cosas para el fin de semana.",
            ],
            kind: .reading(targetSeconds: 60, minimumSeconds: 40)
        ),
    ])

    /// Friday's lesson, in the app's language, with the person's own ways of calling it ("Jarbis", "Yarvis", "hey Jarvis")
    /// as a step of their own and a step for intonations (called from across the room, asking, tired, in a hurry). The
    /// tuner then also hears every recording over people talking, music and fan noise (``NoiseAugmentation``).
    public static func friday(spanish: Bool, variants: [String]) -> VoiceLessonScript {
        func t(_ en: String, _ es: String) -> String { spanish ? es : en }
        let ownWays = variants.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var steps: [Step] = [
            Step(
                id: "jarvis", title: t("Say “Jarvis”", "Di «Jarvis»"),
                instruction: t("Just the name, the way you say it day to day. Leave about a second between one and the next.",
                               "Solo el nombre, como lo dices normalmente. Deja más o menos un segundo entre uno y otro."),
                prompts: ["Jarvis"], kind: .phrases(count: 10, maximumSeconds: 3)
            ),
            Step(
                id: "intonations", title: t("With different tones", "Con distintas entonaciones"),
                instruction: t("Say it as the screen asks: louder, softer, asking, longer, in a hurry. A second's pause between each.",
                               "Dilo como te pide la pantalla: más fuerte, más bajo, preguntando, alargado, con prisa. Un segundo de pausa entre cada uno."),
                prompts: spanish
                    ? ["Jarvis (normal)", "¡Jarvis! (fuerte, desde lejos)", "Jarvis (bajito)", "¿Jarvis? (preguntando)", "Jaaarvis (alargado)", "Jarvis (rápido, con prisa)", "Jarvis (cansado)", "¡Eh, Jarvis!"]
                    : ["Jarvis (normal)", "Jarvis! (loud, from across the room)", "Jarvis (quietly)", "Jarvis? (asking)", "Jaaarvis (drawn out)", "Jarvis (quick)", "Jarvis (tired)", "Hey, Jarvis!"],
                kind: .phrases(count: 12, maximumSeconds: 3.5)
            ),
            Step(
                id: "hey-jarvis", title: t("Call it", "Llámalo"),
                instruction: t("As you really would, with the words run together.", "Como lo harías de verdad, con las palabras seguidas."),
                prompts: ["Hey Jarvis", "Oye Jarvis", "Ok Jarvis", "Hola Jarvis"], kind: .phrases(count: 8, maximumSeconds: 4)
            ),
        ]
        if !ownWays.isEmpty {
            steps.append(Step(
                id: "own-ways", title: t("Your own ways", "Tus propias formas"),
                instruction: t("The ways you call it that you listed in Settings, as you really say them.",
                               "Las formas de llamarlo que añadiste en Ajustes, tal como las dices de verdad."),
                prompts: ownWays, kind: .phrases(count: min(18, max(8, ownWays.count * 3)), maximumSeconds: 4)
            ))
        }
        steps.append(Step(
            id: "commands", title: t("Ask it something", "Pídele algo"),
            instruction: t("The name and then the request, in one go.", "El nombre y luego la petición, de seguido."),
            prompts: ["Jarvis, ¿qué hora es?", "Oye Jarvis, abre Notas", "Jarvis, pon música", "Hey Jarvis, what time is it?", "Jarvis, ¿qué tiempo hace mañana?", "Jarvis, para"],
            kind: .phrases(count: 6, maximumSeconds: 7)
        ))
        steps.append(standard.steps.last!)  // ordinary talk, which must never wake it
        if spanish, var talk = steps.last {
            talk.title = "Ahora habla normal"
            talk.instruction = "Lee esto en voz alta a tu ritmo: así Friday aprende lo que NO es su nombre."
            steps[steps.count - 1] = talk
        }
        return VoiceLessonScript(steps: steps)
    }
}
