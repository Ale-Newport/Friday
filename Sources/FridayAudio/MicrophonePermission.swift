import AVFoundation
import Foundation

public enum MicrophoneAuthorization: Equatable, Sendable {
    /// The user has not been asked yet.
    case notDetermined
    case authorized
    /// The user declined (or later revoked access in System Settings).
    case denied
    /// Blocked by policy (parental controls, MDM). The user cannot change it.
    case restricted

    public var isAuthorized: Bool { self == .authorized }
}

/// Reads and requests microphone permission. Abstracted so the runtime can be tested with every
/// authorisation state without touching the real TCC database.
public protocol MicrophonePermissionProviding: Sendable {
    func status() -> MicrophoneAuthorization
    /// Shows the system prompt if the state is `.notDetermined`; otherwise returns the current state.
    func request() async -> MicrophoneAuthorization
}

/// The real macOS microphone permission (TCC).
public struct SystemMicrophonePermission: MicrophonePermissionProviding {
    public init() {}

    public func status() -> MicrophoneAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined: .notDetermined
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .denied
        }
    }

    public func request() async -> MicrophoneAuthorization {
        if status() == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        return status()
    }

    /// Deep link to System Settings ▸ Privacy & Security ▸ Microphone.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
}
