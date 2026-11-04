import Foundation
import FridayAssistant
import FridayIntelligence

/// Friday's own settings (voice, intelligence, shell), persisted as JSON blobs in `UserDefaults`.
/// Thread-safe: the actors read snapshots through closures; the UI writes on the main actor.
final class FridaySettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var voice: VoiceSettings
    private var intelligence: IntelligenceSettings

    static let voiceKey = "friday.voice.v1"
    static let intelligenceKey = "friday.intelligence.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        voice = Self.load(VoiceSettings.self, key: Self.voiceKey, defaults: defaults) ?? VoiceSettings()
        intelligence = Self.load(IntelligenceSettings.self, key: Self.intelligenceKey, defaults: defaults) ?? IntelligenceSettings()
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String, defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    var voiceSettings: VoiceSettings { lock.withLock { voice } }
    var intelligenceSettings: IntelligenceSettings { lock.withLock { intelligence } }

    func updateVoice(_ change: (inout VoiceSettings) -> Void) -> VoiceSettings {
        lock.withLock {
            change(&voice)
            voice.speakingRate = min(max(voice.speakingRate, 0.5), 2)
            voice.speakingVolume = min(max(voice.speakingVolume, 0), 1)
            voice.conversationTimeoutSeconds = min(max(voice.conversationTimeoutSeconds, 2), 60)
            voice.endpointSilenceSeconds = min(max(voice.endpointSilenceSeconds, 0.3), 3)
            if let data = try? JSONEncoder().encode(voice) { defaults.set(data, forKey: Self.voiceKey) }
            return voice
        }
    }

    func updateIntelligence(_ change: (inout IntelligenceSettings) -> Void) -> IntelligenceSettings {
        lock.withLock {
            change(&intelligence)
            intelligence.maxToolRounds = min(max(intelligence.maxToolRounds, 1), 24)
            intelligence.layaConfidenceThreshold = min(max(intelligence.layaConfidenceThreshold, 0.3), 0.95)
            if let data = try? JSONEncoder().encode(intelligence) { defaults.set(data, forKey: Self.intelligenceKey) }
            return intelligence
        }
    }
}
