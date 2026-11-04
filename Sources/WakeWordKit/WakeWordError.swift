import Foundation

/// How a failure can be resolved. The supervisor uses this to decide between automatic retry,
/// waiting for the user, or giving up — without knowing which engine produced the error.
public enum Recovery: Equatable, Sendable {
    /// Likely transient (for example no network for licence validation). Retry with backoff.
    case retryAutomatically
    /// Retrying is pointless until the user does something.
    case needsUserAction(UserAction)
    /// Programming or environment error; surface it and wait for a manual retry.
    case manualRetryOnly
}

public enum UserAction: Equatable, Sendable {
    /// A credential (for example an API key) is missing or was rejected.
    case provideCredential(CredentialKey)
    /// The engine's native library or model files are not installed.
    case installEngineFiles
    /// The licence or plan behind the credential does not permit this use.
    case reviewLicence
}

/// The one error domain every wake-word engine reports through. Engines map their native
/// failures into these cases (typed throws makes forgetting to do so a compile error), so the
/// supervisor, state machine and UI never need engine-specific error handling.
public enum WakeWordError: Error, Equatable, Sendable {
    /// `processAudio`/`updateSensitivity` called before `initialize()` succeeded.
    case notInitialized
    /// The engine was shut down; create a new instance.
    case shutDown
    /// Native library, model or keyword file is missing or unusable.
    case engineUnavailable(String)
    /// A required credential was not provided.
    case credentialMissing(CredentialKey)
    /// The credential store could not be read (a locked Keychain, access the user declined …), so whether a
    /// credential exists is unknown. Not the same as ``credentialMissing(_:)``: the user may have saved one.
    case credentialUnreadable(CredentialKey, detail: String)
    /// The provider rejected the credential (invalid, revoked or disabled).
    case credentialRejected(CredentialKey, detail: String)
    /// The engine's licence/activation check did not complete and the engine cannot say why — a rejected
    /// key and a missing network connection look the same to many licensed engines. The runtime tells
    /// them apart: if the Mac was offline at any point during the attempt this is reported as
    /// ``networkUnavailable(_:)`` and retried automatically; otherwise it stays as it is (a manual retry).
    case licenceCheckFailed(CredentialKey, detail: String)
    /// The plan's activation or usage limit was reached, or the licence was refused.
    case licenceLimit(String)
    /// The engine needed the network (for example licence validation) and could not reach it.
    case networkUnavailable(String)
    /// Invalid parameters (keyword, sensitivity, device string …).
    case invalidConfiguration(String)
    /// A frame did not match the engine's declared requirements.
    case invalidFrame(expected: Int, actual: Int)
    /// A frame could not be processed.
    case processingFailed(String)
    /// The change (for example a new sensitivity) cannot be applied in place; build a new engine.
    case requiresReinitialization
    /// Anything else.
    case internalFailure(String)

    public var recovery: Recovery {
        switch self {
        case .networkUnavailable:
            return .retryAutomatically
        case .credentialMissing(let key), .credentialRejected(let key, _):
            return .needsUserAction(.provideCredential(key))
        case .licenceLimit:
            return .needsUserAction(.reviewLicence)
        case .engineUnavailable:
            return .needsUserAction(.installEngineFiles)
        case .notInitialized, .shutDown, .invalidConfiguration, .invalidFrame, .processingFailed,
             .requiresReinitialization, .internalFailure,
             // Retrying on a timer would re-prompt a user who just declined; they retry when they have unlocked it.
             .credentialUnreadable,
             // The key may be perfectly good (the licence server could be down or slow), so retrying by hand is a
             // legitimate thing to offer — unlike a key the provider definitely rejected.
             .licenceCheckFailed:
            return .manualRetryOnly
        }
    }

    /// True when the failure is about the engine's credentials or licence (so the UI should
    /// offer to edit them).
    public var isCredentialProblem: Bool {
        switch self {
        case .credentialMissing, .credentialRejected, .licenceCheckFailed, .licenceLimit: true
        default: false
        }
    }
}

extension WakeWordError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notInitialized: "The wake-word engine is not initialised."
        case .shutDown: "The wake-word engine has been shut down."
        case .engineUnavailable(let detail): "The wake-word engine is unavailable: \(detail)"
        case .credentialMissing(let key): "No \(key.name) has been entered yet."
        case .credentialUnreadable(let key, let detail): "Jarvis couldn’t read the \(key.name) from the Keychain: \(detail)"
        case .credentialRejected(_, let detail): "The credential was rejected: \(detail)"
        case .licenceCheckFailed(_, let detail): "The licence check did not complete (\(detail))."
        case .licenceLimit(let detail): "The licence does not allow this: \(detail)"
        case .networkUnavailable(let detail): "The engine could not reach its licence server: \(detail)"
        case .invalidConfiguration(let detail): "Invalid wake-word configuration: \(detail)"
        case .invalidFrame(let expected, let actual):
            "Audio frame has \(actual) samples but the engine expects \(expected)."
        case .processingFailed(let detail): "Audio processing failed: \(detail)"
        case .requiresReinitialization: "The engine must be re-created to apply this change."
        case .internalFailure(let detail): "Internal wake-word error: \(detail)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .credentialMissing, .credentialRejected:
            "Open Settings ▸ Engine and enter a valid key."
        case .credentialUnreadable:
            "Unlock the Keychain (or allow access when macOS asks), then choose Try Again."
        case .licenceCheckFailed:
            "Check your internet connection and the key in Settings ▸ Engine."
        case .licenceLimit:
            "Check the plan and device limits of your account with the engine's provider."
        case .networkUnavailable:
            "Connect to the internet; Jarvis will retry automatically."
        case .engineUnavailable:
            "Reinstall the app (or add the engine’s files) or choose another engine."
        default:
            nil
        }
    }
}
