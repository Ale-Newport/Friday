import Foundation
import FridayCore

/// Everything about listening and speaking. Persisted by the app; read per interaction.
public struct VoiceSettings: Codable, Sendable, Hashable {
    public var wakeWordEnabled = true
    public var wakeWord = "Jarvis"
    /// Keep listening for follow-ups after answering, without the wake word.
    public var conversationMode = true
    public var conversationTimeoutSeconds: Double = 8
    /// Seconds of silence that end an utterance.
    /// 0.7 s: Jarvis-Live measured 1.0 s as sluggish and 0.5 s as cutting people off mid-pause.
    public var endpointSilenceSeconds: Double = 0.7
    /// Give up when nothing is said after the wake word.
    public var noSpeechTimeoutSeconds: Double = 6
    public var maxUtteranceSeconds: Double = 25
    /// `apple` (SpeechAnalyzer) or `whisper` (sidecar, optional).
    public var recognizerID = "apple"
    /// `auto` detects per utterance; otherwise a fixed language.
    public var spokenLanguage: LanguagePreference = .automatic
    public var customVocabulary: [String] = []
    /// `auto` (online neural voice, then Piper/Kokoro/Apple as fallbacks, per phrase), `neural`, `piper`, `kokoro` or `apple`.
    public var ttsEngineID = "auto"
    public var englishVoiceID: String?
    public var spanishVoiceID: String?
    public var speakingRate: Float = 1.0
    public var speakingVolume: Float = 1.0
    public var speakResponses = true
    public var speakTypedResponses = false
    /// Short chime instead of a spoken "Yes?" on activation.
    public var acknowledgementStyle: Acknowledgement = .chime
    /// Sustained speech, clearly louder than the playback the microphone picks up, stops Friday mid-sentence.
    public var bargeInEnabled = true
    /// Second opinion on every activation: the audio around the wake word is transcribed and the activation is
    /// dropped quietly unless a spelling of the wake word is heard. Costs a few hundred milliseconds per activation
    /// (see `VoiceListener.verifyWakeWord`); on by default since 17 Nov 2026, when people talking Spanish in the room
    /// kept waking the free detector.
    public var verifyWakeWord = true
    /// Other ways the user calls Friday ("Jarbis", "Yarvis", "hey Jarvis"): recorded in the voice lesson, accepted by the
    /// wake-word check and stripped from commands.
    public var wakeWordVariants: [String] = []
    /// Speak a short "un momento" when a command is still working after a few seconds.
    public var acknowledgeLongTasks = true
    /// Listen for "para"/"cállate"/"stop" while a command runs and while Friday speaks (`VoiceListener.watchForCommand`).
    public var stopWatcherEnabled = true
    /// Bumped when a default changes in a way stored settings should follow (see `init(from:)`).
    public var revision = VoiceSettings.currentRevision
    public static let currentRevision = 2

    public enum Acknowledgement: String, Codable, Sendable, CaseIterable { case chime, spoken, silent }

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case wakeWordEnabled, wakeWord, conversationMode, conversationTimeoutSeconds, endpointSilenceSeconds, noSpeechTimeoutSeconds
        case maxUtteranceSeconds, recognizerID, spokenLanguage, customVocabulary, ttsEngineID, englishVoiceID, spanishVoiceID
        case speakingRate, speakingVolume, speakResponses, speakTypedResponses, acknowledgementStyle, bargeInEnabled, verifyWakeWord
        case wakeWordVariants, acknowledgeLongTasks, stopWatcherEnabled, revision
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = VoiceSettings()
        wakeWordEnabled = try c.decodeIfPresent(Bool.self, forKey: .wakeWordEnabled) ?? d.wakeWordEnabled
        wakeWord = try c.decodeIfPresent(String.self, forKey: .wakeWord) ?? d.wakeWord
        conversationMode = try c.decodeIfPresent(Bool.self, forKey: .conversationMode) ?? d.conversationMode
        conversationTimeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .conversationTimeoutSeconds) ?? d.conversationTimeoutSeconds
        endpointSilenceSeconds = try c.decodeIfPresent(Double.self, forKey: .endpointSilenceSeconds) ?? d.endpointSilenceSeconds
        noSpeechTimeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .noSpeechTimeoutSeconds) ?? d.noSpeechTimeoutSeconds
        maxUtteranceSeconds = try c.decodeIfPresent(Double.self, forKey: .maxUtteranceSeconds) ?? d.maxUtteranceSeconds
        recognizerID = try c.decodeIfPresent(String.self, forKey: .recognizerID) ?? d.recognizerID
        spokenLanguage = try c.decodeIfPresent(LanguagePreference.self, forKey: .spokenLanguage) ?? d.spokenLanguage
        customVocabulary = try c.decodeIfPresent([String].self, forKey: .customVocabulary) ?? d.customVocabulary
        ttsEngineID = try c.decodeIfPresent(String.self, forKey: .ttsEngineID) ?? d.ttsEngineID
        englishVoiceID = try c.decodeIfPresent(String.self, forKey: .englishVoiceID)
        spanishVoiceID = try c.decodeIfPresent(String.self, forKey: .spanishVoiceID)
        speakingRate = try c.decodeIfPresent(Float.self, forKey: .speakingRate) ?? d.speakingRate
        speakingVolume = try c.decodeIfPresent(Float.self, forKey: .speakingVolume) ?? d.speakingVolume
        speakResponses = try c.decodeIfPresent(Bool.self, forKey: .speakResponses) ?? d.speakResponses
        speakTypedResponses = try c.decodeIfPresent(Bool.self, forKey: .speakTypedResponses) ?? d.speakTypedResponses
        acknowledgementStyle = try c.decodeIfPresent(Acknowledgement.self, forKey: .acknowledgementStyle) ?? d.acknowledgementStyle
        bargeInEnabled = try c.decodeIfPresent(Bool.self, forKey: .bargeInEnabled) ?? d.bargeInEnabled
        verifyWakeWord = try c.decodeIfPresent(Bool.self, forKey: .verifyWakeWord) ?? d.verifyWakeWord
        wakeWordVariants = try c.decodeIfPresent([String].self, forKey: .wakeWordVariants) ?? d.wakeWordVariants
        acknowledgeLongTasks = try c.decodeIfPresent(Bool.self, forKey: .acknowledgeLongTasks) ?? d.acknowledgeLongTasks
        stopWatcherEnabled = try c.decodeIfPresent(Bool.self, forKey: .stopWatcherEnabled) ?? d.stopWatcherEnabled
        let stored = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 1
        if stored < 2 {
            // Revision 2: the old defaults (Kokoro, 0.8 s endpointing) move to the new ones; explicit choices stay.
            if ttsEngineID == "kokoro" { ttsEngineID = d.ttsEngineID }
            if endpointSilenceSeconds == 0.8 { endpointSilenceSeconds = d.endpointSilenceSeconds }
            // Conversations in Spanish near the Mac woke the free detector and their sentences were taken as
            // commands: the wake-word check is on unless the user had turned it on or off since revision 2.
            if !verifyWakeWord { verifyWakeWord = d.verifyWakeWord }
        }
        revision = Self.currentRevision
    }

    /// The language Friday speaks when it has to say something before hearing the user (prompts, acknowledgements).
    public var promptLanguage: Language {
        switch spokenLanguage {
        case .english: return .en
        case .spanish: return .es
        case .automatic: return Language(hint: Locale.current.language.languageCode?.identifier) ?? .en
        }
    }
}
