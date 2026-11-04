import Foundation
import Testing
@testable import FridayIntelligence

@Suite struct UtteranceNormalizerTests {
    @Test func stripsWakeWordAndFillers() {
        let result = UtteranceNormalizer.normalize("Jarvis, um, open Chrome")
        #expect(result.text == "open Chrome")
        #expect(result.strippedWakeWord)
    }

    @Test func keepsOnlyTheCorrectedRequestInEnglish() {
        let result = UtteranceNormalizer.normalize("open... no, wait, open Notes instead")
        #expect(result.corrected)
        #expect(result.text == "open Notes instead")
    }

    @Test func keepsOnlyTheCorrectedRequestInSpanish() {
        let result = UtteranceNormalizer.normalize("Jarvis abre la... bueno no, primero ponme música")
        #expect(result.corrected)
        #expect(result.text == "primero ponme música")
    }

    @Test func shortCorrectionDoesNotDropTheRequest() {
        // "no" alone after the marker is too short to be the whole request; the original stays.
        let result = UtteranceNormalizer.normalize("add milk, actually no")
        #expect(!result.corrected)
    }

    @Test func simpleCommandDetection() {
        #expect(UtteranceNormalizer.isSimpleCommand("open Spotify"))
        #expect(UtteranceNormalizer.isSimpleCommand("volume down"))
        #expect(!UtteranceNormalizer.isSimpleCommand("find the pdf I downloaded yesterday and summarize it"))
        #expect(!UtteranceNormalizer.isSimpleCommand("pon música y luego abre el documento de ayer"))
    }
}

@Suite struct KeywordRouterTests {
    @Test func routesObviousCommandsInBothLanguages() {
        #expect(KeywordRouter.route("play some jazz") == .music)
        #expect(KeywordRouter.route("pon la playlist de estudiar") == .music)
        #expect(KeywordRouter.route("recuérdame comprar leche mañana") == .reminders)
        #expect(KeywordRouter.route("set a timer for 10 minutes") == .clock)
        #expect(KeywordRouter.route("what's the weather tomorrow") == .information)
        #expect(KeywordRouter.route("open Chrome") == .system)
        #expect(KeywordRouter.route("search for cheap flights to Barcelona") == .browser)
    }

    @Test func ambiguousTextIsNotRouted() {
        #expect(KeywordRouter.route("play the video on the website") == nil)  // music + browser
        #expect(KeywordRouter.route("hello there") == nil)
    }

    @Test func multistepAndDangerHeuristics() {
        #expect(KeywordRouter.looksMultistep("check the weather and then move my walk reminder"))
        #expect(KeywordRouter.looksMultistep("busca el documento y luego ábrelo"))
        #expect(!KeywordRouter.looksMultistep("open Notes"))
        #expect(KeywordRouter.looksDangerous("delete all my screenshots"))
        #expect(KeywordRouter.looksDangerous("envía el correo a Ana"))
        #expect(!KeywordRouter.looksDangerous("read my latest email"))
        #expect(KeywordRouter.looksLikeQuestion("¿qué hora es?"))
        #expect(KeywordRouter.looksLikeQuestion("how tall is the Eiffel tower"))
    }
}

@Suite struct PKCEAndJWTTests {
    @Test func pkceChallengeIsBase64URLOfSHA256() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        #expect(PKCE.challenge(for: verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func base64URLRoundTrip() {
        let data = Data((0..<64).map { UInt8($0) })
        #expect(PKCE.base64URLDecode(PKCE.base64URL(data)) == data)
    }

    @Test func derIntegerAddsLeadingZeroForHighBit() {
        let encoded = DER.integer(Data([0x80, 0x01]))
        #expect(Array(encoded) == [0x02, 0x03, 0x00, 0x80, 0x01])
        #expect(Array(DER.integer(Data([0x00, 0x00, 0x05]))) == [0x02, 0x01, 0x05])
    }

    @Test func httpErrorsMapToTypedErrors() {
        let body = #"{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"limit"}}"#.data(using: .utf8)!
        if case .usageLimitExceeded = HTTPErrorMapper.error(status: 429, body: body) {} else { Issue.record("expected usage limit") }
        if case .authenticationRequired = HTTPErrorMapper.error(status: 401, body: Data()) {} else { Issue.record("expected auth") }
        if case .temporarilyUnavailable = HTTPErrorMapper.error(status: 503, body: Data()) {} else { Issue.record("expected unavailable") }
    }
}

@Suite struct ResponsesRequestTests {
    @Test func planTokenRequestsFollowTheDocumentedConstraints() throws {
        let client = ResponsesAPIClient()
        let request = LLMRequest(
            model: "gpt-x", instructions: "sys", messages: [
                LLMMessage(role: .system, text: "dev"), .user("hi"), .assistant("", toolCalls: [LLMToolCall(id: "c1", name: "music__play", argumentsJSON: "{}")]),
                .toolResult(callID: "c1", "{\"ok\":true}"),
            ],
            tools: [LLMToolDefinition(name: "music__play", description: "play", parameters: ["type": "object"])],
            maxOutputTokens: 100, temperature: 0.2)
        let body = client.body(for: request, credentials: .init(bearer: "t", planToken: true), stream: true)
        #expect(body["store"] == .bool(false))
        #expect(body["stream"] == .bool(true))
        #expect(body["max_output_tokens"] == nil)
        #expect(body["temperature"] == nil)
        #expect(body["instructions"] == .string("sys"))
        let input = body["input"]?.arrayValue ?? []
        #expect(input.count == 4)
        #expect(input[0]["role"] == .string("developer"))   // never a system item
        #expect(input[2]["type"] == .string("function_call"))
        #expect(input[3]["type"] == .string("function_call_output"))
        #expect(body["tools"]?[0]?["type"] == .string("function"))
    }

    @Test func apiKeyRequestsKeepLimits() {
        let client = ResponsesAPIClient()
        let request = LLMRequest(model: "gpt-4.1", instructions: "s", messages: [.user("x")], maxOutputTokens: 50, temperature: 0.5)
        let body = client.body(for: request, credentials: .init(bearer: "k", planToken: false), stream: true)
        #expect(body["max_output_tokens"] == .int(50))
        #expect(body["temperature"] == .double(0.5))
    }
}

@Suite struct ModelTieringTests {
    @Test func tiersByName() {
        #expect(ModelTiering.tier(for: "gpt-5.1-mini") == .fast)
        #expect(ModelTiering.tier(for: "gpt-6.1-sol") == .capable)
        #expect(ModelTiering.tier(for: "o4-mini") == .fast)
        #expect(ModelTiering.tier(for: "qwen3:8b") == .capable)
    }

    @Test func defaultsPreferProviderOrder() {
        let models = [LLMModel(id: "a-mini", tier: .fast), LLMModel(id: "b", tier: .capable), LLMModel(id: "c", tier: .capable)]
        #expect(ModelTiering.defaultCapable(from: models)?.id == "b")
        #expect(ModelTiering.defaultFast(from: models)?.id == "a-mini")
    }
}
