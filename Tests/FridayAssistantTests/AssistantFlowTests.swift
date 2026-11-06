import Foundation
import Testing
import FridayCore
import FridaySpeech
@testable import FridayAssistant
@testable import FridayBrowser

@Suite struct PhraseMatchingTests {
    @Test func endPhrasesSurviveInnerPunctuationAndAccents() {
        for text in ["Gracias, eso es todo.", "Thanks, that's all.", "Thanks, that’s all!", "¡Adiós!", "Ya está.", "Nada más", "that is all"] {
            #expect(Assistant.endPhrases.contains(Assistant.phraseKey(text)), "\(text) should end the conversation")
        }
    }

    @Test func stopPhrasesSurviveInnerPunctuationAndAccents() {
        for text in ["Stop.", "Cancel that!", "Never mind,", "¡Olvídalo!", "Déjalo.", "Espera"] {
            #expect(Assistant.stopPhrases.contains(Assistant.phraseKey(text)), "\(text) should stop")
        }
        #expect(!Assistant.stopPhrases.contains(Assistant.phraseKey("stop the music")))
    }

    @Test func spokenApprovalsAndManualAnswersAreClassified() {
        #expect(Assistant.spokenApproval("Yes, go ahead.") == true)
        #expect(Assistant.spokenApproval("Sí.") == true)
        #expect(Assistant.spokenApproval("No, cancel.") == false)
        #expect(Assistant.spokenApproval("deny") == false)
        #expect(Assistant.spokenApproval("what time is it") == nil)
        #expect(Assistant.spokenManualAnswer("Done!") == true)
        #expect(Assistant.spokenManualAnswer("Vale, listo.") == true)
        #expect(Assistant.spokenManualAnswer("I'm done") == true)
        #expect(Assistant.spokenManualAnswer("Cancel") == false)
        #expect(Assistant.spokenManualAnswer("Olvídalo") == false)
        #expect(Assistant.spokenManualAnswer("Ya.") == true)
        #expect(Assistant.spokenManualAnswer("ya no quiero seguir") == nil)
        #expect(Assistant.spokenManualAnswer("hello there") == nil)
    }
}

@Suite(.serialized) struct VoiceLoopTests {
    /// Finding 5: an end phrase ends the session at once instead of listening for another conversation window.
    @Test func anEndPhraseEndsTheSessionPromptly() async {
        var settings = SettingsBox.fast()
        settings.conversationTimeoutSeconds = 5
        let harness = AssistantHarness(script: ["Thanks, that's all."], settings: settings)
        harness.speakIntoMicrophone()
        let started = ContinuousClock.now
        await harness.assistant.runVoiceSession(wakeWordEndPosition: 0)
        #expect(milliseconds(since: started) < 2_500)
        #expect(harness.tts.spoken == ["Okay."])
        let snapshot = await harness.assistant.current
        #expect(!snapshot.inConversation && !snapshot.inVoiceSession)
        #expect(snapshot.phase == .idle)
    }

    @Test func aSpanishEndPhraseIsAnsweredInSpanish() async {
        let harness = AssistantHarness(script: ["Gracias, eso es todo."], language: .es)
        harness.speakIntoMicrophone()
        await harness.assistant.runVoiceSession(wakeWordEndPosition: 0)
        #expect(harness.tts.spoken == ["Hasta luego."])
    }

    /// Finding 29: speech without words gets a re-prompt in the user's language, not an error that ends the session.
    @Test func unintelligibleSpeechIsRepromptedOnce() async {
        var settings = SettingsBox.fast()
        settings.spokenLanguage = .spanish
        let harness = AssistantHarness(script: ["", ""], settings: settings)
        harness.speakIntoMicrophone()
        harness.recognizer.onSession = { [recorder = harness.recorder] index in if index == 1 { feed(recorder, utteranceAudio()) } }
        await harness.assistant.runVoiceSession(wakeWordEndPosition: 0)
        #expect(harness.tts.spoken == ["¿Perdona?"])
        #expect(harness.recognizer.createdSessions.count == 2)
        let snapshot = await harness.assistant.current
        #expect(snapshot.phase == .idle)
    }

    @Test func aRecogniserFailureIsSpokenAndShownInTheUsersLanguage() async {
        var settings = SettingsBox.fast()
        settings.recognizerID = "missing"
        settings.spokenLanguage = .spanish
        let harness = AssistantHarness(script: ["unused"], settings: settings)
        await harness.assistant.runVoiceSession(wakeWordEndPosition: 0)
        let snapshot = await harness.assistant.current
        #expect(snapshot.phase == .error("No hay ningún reconocedor de voz disponible."))
        #expect(harness.tts.spoken == ["No hay ningún reconocedor de voz disponible."])
        // The next interaction clears it.
        harness.settings.update { $0.speakResponses = false }
        _ = await harness.assistant.submit("echo hi", source: .app, session: "chat")
        #expect(await harness.assistant.current.phase == .idle)
    }

    @Test func silenceAfterTheWakeWordAsksOnceThenGivesUp() async {
        let harness = AssistantHarness(script: ["unused", "unused"])
        let started = ContinuousClock.now
        await harness.assistant.runVoiceSession(wakeWordEndPosition: 0)
        #expect(harness.tts.spoken == ["Yes?"])
        #expect(milliseconds(since: started) < 3_000)
    }

    /// Finding 28: a spoken question is answered by voice even when conversation mode is off, and the spoken
    /// answer reaches the engine's pending confirmation.
    @Test func aSpokenConfirmationIsListenedForWithConversationModeOff() async {
        var settings = SettingsBox.fast()
        settings.conversationMode = false
        settings.conversationTimeoutSeconds = 2
        let harness = AssistantHarness(script: ["delete the report", "yes"], settings: settings)
        harness.speakIntoMicrophone()
        harness.recognizer.onSession = { [recorder = harness.recorder] index in if index == 1 { feed(recorder, utteranceAudio()) } }
        await harness.assistant.runVoiceSession(wakeWordEndPosition: 0)
        #expect(harness.tts.spoken == ["Delete it?", "Deleted."])
        #expect(harness.tools.calls.map(\.confirmed) == [false, true])
        let snapshot = await harness.assistant.current
        #expect(snapshot.pending == nil)
        #expect(!snapshot.inConversation)
        // A plain answer with conversation mode off ends the session: only two captures were made.
        #expect(harness.recognizer.createdSessions.count == 2)
    }

    /// Finding 7: the words that interrupt Friday are kept — the next capture starts where the interruption began.
    @Test func bargeInStopsTheSpeechAndHearsTheInterruption() async {
        var settings = SettingsBox.fast()
        settings.bargeInEnabled = true
        settings.conversationMode = false
        let harness = AssistantHarness(script: ["hello", "stop"], settings: settings)
        harness.tts.delays = [.seconds(8)]  // the reply would take 8 s unless interrupted
        harness.speakIntoMicrophone()
        let toneStart = Mutex<Int?>(nil)
        let feeder = Task { [recorder = harness.recorder] in
            // Quiet room while the reply starts and the detector calibrates, then the interruption, then quiet.
            for _ in 0..<34 { feed(recorder, tone(seconds: 0.05, amplitude: 0.001)); try? await Task.sleep(for: .milliseconds(50)) }
            toneStart.set(recorder.position)
            for _ in 0..<20 { feed(recorder, tone(seconds: 0.05, amplitude: 0.3)); try? await Task.sleep(for: .milliseconds(50)) }
            for _ in 0..<30 { feed(recorder, tone(seconds: 0.05, amplitude: 0.001)); try? await Task.sleep(for: .milliseconds(50)) }
        }
        let started = ContinuousClock.now
        await harness.assistant.runVoiceSession(wakeWordEndPosition: 0)
        feeder.cancel()
        #expect(milliseconds(since: started) < 6_500, "the session must not wait for the 8 s reply")
        #expect(harness.tts.spoken == ["Reply to hello", "Okay."])
        #expect(harness.recognizer.createdSessions.count == 2)
        // The second capture began at the interruption (0.2 s margin), so it heard the whole "stop".
        if let second = harness.recognizer.createdSessions.last, let start = toneStart.get() {
            let heardFrom = harness.recorder.position - second.samplesFed
            #expect(heardFrom <= start, "capture started at \(heardFrom), the interruption at \(start)")
            #expect(heardFrom >= start - MicrophoneRecorder.sampleRate / 2)
        }
    }
}

@Suite(.serialized) struct CommandSerialisationTests {
    /// Finding 27: a command from another session waits instead of cancelling the one in flight.
    @Test func aChatCommandDoesNotCancelARunningVoiceCommand() async {
        let harness = AssistantHarness()
        harness.settings.update { $0.speakResponses = false }
        let assistant = harness.assistant
        let voice = Task { await assistant.submit("slow 700", source: .voice, session: "voice") }
        try? await Task.sleep(for: .milliseconds(100))
        let chatStarted = ContinuousClock.now
        let chat = await assistant.submit("echo hi", source: .app, session: "chat")
        let voiceResponse = await voice.value
        #expect(voiceResponse.status == .completed, "\(voiceResponse.status): \(voiceResponse.message)")
        #expect(chat.status == .completed && chat.message.contains("Echo: hi"))
        #expect(milliseconds(since: chatStarted) >= 450, "the chat command waited for the voice command")
        let snapshot = await assistant.current
        #expect(snapshot.phase == .idle)
    }

    @Test func aNewerCommandOfTheSameSessionSupersedesTheRunningOne() async {
        let harness = AssistantHarness()
        harness.settings.update { $0.speakResponses = false }
        let assistant = harness.assistant
        let first = Task { await assistant.submit("slow 3000", source: .app, session: "chat") }
        try? await Task.sleep(for: .milliseconds(100))
        let started = ContinuousClock.now
        let second = await assistant.submit("echo two", source: .app, session: "chat")
        let firstResponse = await first.value
        #expect(firstResponse.status != .completed)
        #expect(second.message.contains("Echo: two"))
        #expect(milliseconds(since: started) < 2_000, "the superseded command gave way")
    }

    /// Finding 8: Stop (and the spoken stop phrase that calls it) cancels the engine's pending confirmation.
    @Test func interruptCancelsThePendingConfirmationInTheEngine() async {
        let harness = AssistantHarness()
        harness.settings.update { $0.speakResponses = false }
        let assistant = harness.assistant
        let asked = await assistant.submit("delete everything", source: .voice, session: "voice")
        #expect(asked.status == .needsConfirmation)
        #expect(await harness.engine.pendingCount == 1)
        #expect(await assistant.current.pending != nil)
        await assistant.interrupt()
        #expect(await harness.engine.pendingCount == 0)
        #expect(await assistant.current.pending == nil)
        // A later "yes" must not run the deletion.
        let later = await assistant.submit("yes", source: .voice, session: "voice")
        #expect(later.status != .completed)
        #expect(!harness.tools.calls.contains { $0.confirmed })
    }

    @Test func engineEventsAreAppliedInOrderAndNeverAfterTheFinalText() async {
        let harness = AssistantHarness()
        harness.settings.update { $0.speakResponses = false }
        let response = await harness.assistant.submit("echo order", source: .app, session: "chat")
        let transcript = await harness.assistant.current.transcript
        let answer = transcript.last { $0.role == .assistant }
        #expect(answer?.text == response.message)
        #expect(answer?.isStreaming == false)
        #expect(transcript.contains { $0.role == .step && $0.text.contains("Echo") })
    }
}

@Suite(.serialized) struct BrowserPromptTests {
    private func approval() -> BrowserApproval {
        BrowserApproval(taskID: "t1", confirmationID: "c1", kind: "purchase", question: "Buy the ticket for 45 euros?", detail: nil)
    }

    /// Findings 25/32: a UI answer given while Friday is still asking aloud wins and cuts the question short.
    @Test func approvingFromTheUIWhileFridaySpeaksIsHonoured() async {
        let harness = AssistantHarness()
        harness.tts.delays = [.seconds(5)]
        let assistant = harness.assistant
        let started = ContinuousClock.now
        let decision = Task { await assistant.approve(approval()) }
        try? await Task.sleep(for: .milliseconds(200))
        await assistant.answerBrowserApproval(true)
        let approved = await decision.value
        #expect(approved)
        #expect(milliseconds(since: started) < 3_000)
        #expect(await assistant.current.pending == nil)
    }

    /// Finding 26: Stop while the question is being asked denies it instead of leaving the web task waiting.
    @Test func stopWhileAskingDeniesTheApproval() async {
        let harness = AssistantHarness()
        harness.tts.delays = [.seconds(5)]
        let assistant = harness.assistant
        let decision = Task { await assistant.approve(approval()) }
        try? await Task.sleep(for: .milliseconds(200))
        await assistant.interrupt()
        let approved = await decision.value
        #expect(!approved)
        #expect(await assistant.current.pending == nil)
    }

    @Test func aSpokenYesApproves() async {
        let harness = AssistantHarness(script: ["yes, go ahead"])
        harness.recognizer.onSession = { [recorder = harness.recorder] _ in feed(recorder, utteranceAudio()) }
        let approved = await harness.assistant.approve(approval())
        #expect(approved)
        #expect(harness.tts.spoken.first?.hasSuffix("Should I continue?") == true)
    }

    @Test func theUIAnswerWinsWhenNoSpeechIsHeardInTime() async {
        let harness = AssistantHarness(script: ["unused"])
        let assistant = harness.assistant
        let decision = Task { await assistant.approve(approval()) }
        try? await Task.sleep(for: .milliseconds(300))
        await assistant.answerBrowserApproval(false)
        #expect(await decision.value == false)
    }

    /// Finding 6: the spoken "done"/"listo" resumes the browser task.
    @Test func aSpokenDoneResumesTheBrowserTask() async {
        let harness = AssistantHarness(script: ["hmm", "vale, listo"])
        harness.recognizer.onSession = { [recorder = harness.recorder] _ in feed(recorder, utteranceAudio()) }
        let started = ContinuousClock.now
        let resumed = await harness.assistant.waitForUser(taskID: "t1", kind: "captcha", message: "Resuelve el captcha", url: nil)
        #expect(resumed)
        #expect(milliseconds(since: started) < 5_000)
        #expect(harness.recognizer.createdSessions.count == 2)
        #expect(harness.tts.spoken.first?.contains("listo") == true)
        let transcript = await harness.assistant.current.transcript
        #expect(transcript.contains { $0.text == "vale, listo" && $0.source == "voice" })
    }

    @Test func theDoneButtonStillWorksWhileListening() async {
        let harness = AssistantHarness(script: ["unused"])
        let assistant = harness.assistant
        let started = ContinuousClock.now
        let wait = Task { await assistant.waitForUser(taskID: "t1", kind: "login", message: "Sign in to the site", url: nil) }
        try? await Task.sleep(for: .milliseconds(300))
        await assistant.answerManual(true)
        #expect(await wait.value)
        #expect(milliseconds(since: started) < 3_000)
        #expect(await assistant.current.pending == nil)
    }

    @Test func stopCancelsTheManualWait() async {
        let harness = AssistantHarness(script: ["unused"])
        let assistant = harness.assistant
        let wait = Task { await assistant.waitForUser(taskID: "t1", kind: "login", message: "Sign in to the site", url: nil) }
        try? await Task.sleep(for: .milliseconds(300))
        await assistant.interrupt()
        #expect(await wait.value == false)
    }
}
