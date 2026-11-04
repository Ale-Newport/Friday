import Foundation
import FridayAudio
import WakeWordKit

/// Persists the user's preferences in `UserDefaults`.
///
/// What is deliberately **not** stored here: credentials (they live in the Keychain), and the
/// "start at login" choice (the system owns it — `SMAppService` is the source of truth).
public final class SettingsStore: @unchecked Sendable {
    public enum Key {
        public static let isEnabled = "wakeWord.isEnabled"
        public static let engineID = "wakeWord.engineID"
        public static let sensitivity = "wakeWord.sensitivity"
        public static let inputDeviceUID = "audio.inputDeviceUID"
        public static let cooldown = "wakeWord.cooldownSeconds"
        public static let postSessionHoldoff = "wakeWord.postSessionHoldoffSeconds"
        public static let maxSessionDuration = "assistant.maxSessionSeconds"
        public static let sessionAudioPolicy = "assistant.sessionAudioPolicy"
        public static let developerMode = "app.developerMode"
        public static let hasSeenWelcome = "app.hasSeenWelcome"
    }

    /// Ranges the UI offers; stored values outside them are clamped on load.
    public static let cooldownRange = 0.5...10.0
    public static let holdoffRange = 0.0...5.0
    public static let sessionDurationRange = 5.0...600.0

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load(defaultEngineID: String) -> RuntimeSettings {
        func double(_ key: String, _ fallback: Double, _ range: ClosedRange<Double>) -> Double {
            guard defaults.object(forKey: key) != nil else { return fallback }
            return min(range.upperBound, max(range.lowerBound, defaults.double(forKey: key)))
        }
        let sensitivity = defaults.object(forKey: Key.sensitivity) == nil ? 0.5 : defaults.float(forKey: Key.sensitivity)
        return RuntimeSettings(
            isEnabled: defaults.object(forKey: Key.isEnabled) == nil ? true : defaults.bool(forKey: Key.isEnabled),
            engineID: defaults.string(forKey: Key.engineID) ?? defaultEngineID,
            sensitivity: min(1, max(0, sensitivity)),
            input: defaults.string(forKey: Key.inputDeviceUID).map { .device(uid: $0) } ?? .systemDefault,
            cooldown: double(Key.cooldown, 2.0, Self.cooldownRange),
            postSessionHoldoff: double(Key.postSessionHoldoff, 1.0, Self.holdoffRange),
            maxSessionDuration: double(Key.maxSessionDuration, 60, Self.sessionDurationRange),
            sessionAudioPolicy: defaults.string(forKey: Key.sessionAudioPolicy).flatMap(SessionAudioPolicy.init(rawValue:)) ?? .gateDetector,
            developerMode: defaults.bool(forKey: Key.developerMode)
        )
    }

    public func save(_ settings: RuntimeSettings) {
        defaults.set(settings.isEnabled, forKey: Key.isEnabled)
        defaults.set(settings.engineID, forKey: Key.engineID)
        defaults.set(settings.sensitivity, forKey: Key.sensitivity)
        switch settings.input {
        case .systemDefault: defaults.removeObject(forKey: Key.inputDeviceUID)
        case .device(let uid): defaults.set(uid, forKey: Key.inputDeviceUID)
        }
        defaults.set(settings.cooldown, forKey: Key.cooldown)
        defaults.set(settings.postSessionHoldoff, forKey: Key.postSessionHoldoff)
        defaults.set(settings.maxSessionDuration, forKey: Key.maxSessionDuration)
        defaults.set(settings.sessionAudioPolicy.rawValue, forKey: Key.sessionAudioPolicy)
        defaults.set(settings.developerMode, forKey: Key.developerMode)
    }

    public var hasSeenWelcome: Bool {
        get { defaults.bool(forKey: Key.hasSeenWelcome) }
        set { defaults.set(newValue, forKey: Key.hasSeenWelcome) }
    }
}
