import Foundation
import Testing
@testable import FridayAssistant
import FridayCore

@Suite struct StopCommandTests {
    @Test func stopCommandsEndTheSessionInBothLanguages() {
        for text in ["Para", "¡Para!", "para ya", "Jarvis, para", "Cállate", "cállate ya", "Calla", "Silencio", "Basta", "ya basta", "Basta ya, Jarvis",
                     "Deja de hablar", "No sigas", "Detente", "Stop", "stop it", "Stop talking", "Shut up", "Be quiet", "That's enough", "Enough",
                     "Gracias, eso es todo", "Cancela", "Olvídalo", "vale, para", "ok stop", "para, por favor"] {
            #expect(Assistant.stopKind(text) == .stop, "\(text) should stop")
        }
    }

    @Test func waitHoldsWithoutEndingTheSession() {
        for text in ["Espera", "Espera un momento", "Un momento", "Wait", "Hold on"] {
            #expect(Assistant.stopKind(text) == .hold, "\(text) should hold")
        }
    }

    @Test func requestsThatContainStopWordsAreNotStops() {
        for text in ["Pon una alarma para las siete", "¿Para qué sirve esto?", "para la música", "stop the music", "Busca vuelos para Madrid",
                     "Recuérdame comprar pan para mañana", "What is the enough rule in poker?", "Cancela la reunión de mañana con Marta"] {
            #expect(Assistant.stopKind(text) == nil, "\(text) is a request, not a stop")
        }
    }
}

@Suite struct SpeechSegmenterTests {
    @Test func firstPhraseIsCutEarlyAtAClause() {
        let segments = SpeechSegmenter.segments("Claro, mañana tienes tres reuniones. La primera es a las nueve con Marta.")
        #expect(segments.first == "Claro,")
        #expect(segments.count == 3)
        #expect(segments.joined(separator: " ") == "Claro, mañana tienes tres reuniones. La primera es a las nueve con Marta.")
    }

    @Test func longFirstSentenceWithoutPunctuationIsCutAfterAFewWords() {
        let text = "Hoy en Madrid va a hacer un día bastante soleado con máximas de veinticinco grados y algo de viento por la tarde."
        let segments = SpeechSegmenter.segments(text)
        #expect(segments.count >= 2)
        #expect(segments[0].split(separator: " ").count <= 8)
        #expect(segments.joined(separator: " ") == text)
    }

    @Test func decimalsAndAbbreviationsAreNotCut() {
        let segments = SpeechSegmenter.segments("Son 3.5 kilos. Vale.")
        #expect(segments == ["Son 3.5 kilos.", "Vale."])
    }

    @Test func incrementalSegmentsMatchTheWhole() {
        let text = "Vale, ya lo tengo. He abierto Notas y he creado la lista. ¿Algo más?"
        var segmenter = SpeechSegmenter.Incremental()
        var phrases: [String] = []
        for character in text { phrases += segmenter.append(String(character)) }
        phrases += segmenter.finish()
        #expect(phrases == SpeechSegmenter.segments(text))
    }
}

@Suite struct VoiceReplyStreamTests {
    func collect(_ stream: AsyncStream<String>) async -> [String] {
        var out: [String] = []
        for await phrase in stream { out.append(phrase) }
        return out
    }

    @Test func streamedReplyIsNotRepeatedWhenTheFinalMatches() async {
        let (stream, continuation) = AsyncStream<String>.makeStream()
        let reply = VoiceReplyStream(continuation: continuation)
        let final = "La capital de Australia es Canberra, no Sídney. Se eligió como compromiso entre Sídney y Melbourne."
        var sofar = ""
        for word in final.split(separator: " ") { sofar += (sofar.isEmpty ? "" : " ") + word; reply.receive(sofar) }
        #expect(reply.hasSpoken)
        reply.finish(with: final)
        let phrases = await collect(stream)
        #expect(phrases.joined(separator: " ") == final)
    }

    @Test func aShortClaimIsHeldAndReplacedByTheRealReply() async {
        let (stream, continuation) = AsyncStream<String>.makeStream()
        let reply = VoiceReplyStream(continuation: continuation)
        reply.receive("Hecho.")
        #expect(!reply.hasSpoken)
        reply.finish(with: "No he podido crear el recordatorio: Recordatorios no tiene permiso.")
        let phrases = await collect(stream)
        #expect(phrases.joined(separator: " ") == "No he podido crear el recordatorio: Recordatorios no tiene permiso.")
    }

    @Test func aDifferentFinalReplyIsSpokenAfterTheStream() async {
        let (stream, continuation) = AsyncStream<String>.makeStream()
        let reply = VoiceReplyStream(continuation: continuation)
        reply.receive("Voy a mirar tu calendario de mañana para ver qué reuniones tienes. ")
        reply.finish(with: "Mañana tienes dos reuniones.")
        let phrases = await collect(stream)
        #expect(phrases.last == "Mañana tienes dos reuniones.")
    }

    @Test func cancelledReplySaysNothingMore() async {
        let (stream, continuation) = AsyncStream<String>.makeStream()
        let reply = VoiceReplyStream(continuation: continuation)
        reply.finish(with: nil)
        #expect(await collect(stream).isEmpty)
    }
}

@Suite struct VoiceSettingsMigrationTests {
    @Test func oldDefaultsMoveToTheNewOnes() throws {
        let old = #"{"ttsEngineID":"kokoro","endpointSilenceSeconds":0.8,"spanishVoiceID":"ef_dora"}"#
        let settings = try JSONDecoder().decode(VoiceSettings.self, from: Data(old.utf8))
        #expect(settings.ttsEngineID == "auto")
        #expect(settings.endpointSilenceSeconds == 0.7)
        #expect(settings.revision == VoiceSettings.currentRevision)
    }

    @Test func explicitChoicesAfterTheMigrationStay() throws {
        var current = VoiceSettings()
        current.ttsEngineID = "kokoro"
        current.endpointSilenceSeconds = 0.8
        let decoded = try JSONDecoder().decode(VoiceSettings.self, from: JSONEncoder().encode(current))
        #expect(decoded.ttsEngineID == "kokoro")
        #expect(decoded.endpointSilenceSeconds == 0.8)
    }

    @Test func degreesAreReadAloud() {
        #expect(SpokenText.forVoice("Mañana 21°C en Madrid", language: .es) == "Mañana 21 grados en Madrid")
        #expect(SpokenText.forVoice("Tomorrow 70°F", language: .en) == "Tomorrow 70 degrees Fahrenheit")
    }
}

@Suite struct WakeWordVariantTests {
    @Test func userVariantsAreAcceptedByTheCheck() {
        #expect(!WakeWordMatcher.matches("oye garbiz abre notas", wakeWord: "Jarvis"))
        #expect(WakeWordMatcher.matches("oye garbiz abre notas", wakeWord: "Jarvis", variants: ["Garbiz"]))
    }
}

@Suite struct FollowUpAddressingTests {
    @Test func requestsAndQuestionsAreForFriday() {
        for text in ["¿Y mañana?", "y mañana qué tiempo hará", "Abre Spotify", "vale, pon música", "Dime la hora", "What about tomorrow?",
                     "Open Safari", "también recuérdame comprar pan", "Jarvis, apaga la luz", "para", "gracias"] {
            #expect(Assistant.isAddressedToFriday(text, wakeWord: "Jarvis", variants: []), "\(text)")
        }
    }

    @Test func roomChatterIsNot() {
        for text in ["Sí, tengo los dos un 8,75.", "Marc y Albert.", "Que estaba en el gimnasio", "Muy bien.", "Tengo que empezar a",
                     "Because, you know, long we will see that.", "Sí, pero no debería de estar sorprendida, te lo dije.",
                     "Me ha servido mi amor.", "Psicológicamente hablando, no debería de jugar al Minecraft en verdad. No jugar.", "my heart."] {
            #expect(!Assistant.isAddressedToFriday(text, wakeWord: "Jarvis", variants: []), "\(text)")
        }
    }
}
