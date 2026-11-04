import Foundation
import WakeWordKit

/// Translates Picovoice's native failures into the shared ``WakeWordError`` domain, so nothing
/// above this module needs to know what a "PV_STATUS_ACTIVATION_LIMIT_REACHED" is.
enum PorcupineErrorMapping {
    /// - Parameters:
    ///   - failure: the native status and explanatory messages.
    ///   - credential: the AccessKey requirement, used to point the user at the right setting.
    ///   - secrets: values that must never appear in the result (the library echoes the key).
    static func map(_ failure: NativeFailure, credential: CredentialKey, secrets: [String]) -> WakeWordError {
        let detail = describe(failure, secrets: secrets)
        let lowered = (failure.messages + [failure.statusName]).joined(separator: " ").lowercased()
        let looksLikeNetwork = ["network", "resolve", "connect", "timed out", "timeout", "offline", "socket", "internet"]
            .contains { lowered.contains($0) }

        switch failure.status {
        case .success:
            return .internalFailure("success reported as failure")
        case .invalidArgument:
            return lowered.contains("accesskey") || lowered.contains("access_key") || lowered.contains("access key")
                ? .credentialRejected(credential, detail: detail)
                : .invalidConfiguration(detail)
        case .activationError, .keyError:
            if looksLikeNetwork { return .networkUnavailable(detail) }
            // An explicit verdict from the licence server ("expired", "revoked" …) is a rejected key. A bare
            // "activation failed" is not: being offline produces the same thing, so say so honestly and let
            // the runtime decide from connectivity instead of blaming the key.
            let hasVerdict = ["expired", "revoked", "disabled", "invalid", "not valid", "suspended", "deactivated", "banned"]
                .contains { lowered.contains($0) }
            return hasVerdict ? .credentialRejected(credential, detail: detail) : .licenceCheckFailed(credential, detail: detail)
        case .activationRefused:
            return .credentialRejected(credential, detail: detail)   // the server answered, and the answer was no
        case .activationLimitReached, .activationThrottled:
            return .licenceLimit(detail)
        case .ioError:
            return looksLikeNetwork ? .networkUnavailable(detail) : .engineUnavailable(detail)
        case .outOfMemory:
            return .internalFailure("out of memory (\(detail))")
        case .stopIteration, .invalidState, .runtimeError, .unknown:
            return .internalFailure(detail)
        }
    }

    /// One-line, secret-free description: "STATUS_NAME: message; message".
    static func describe(_ failure: NativeFailure, secrets: [String]) -> String {
        let messages = failure.messages.filter { !$0.isEmpty }
        let text = messages.isEmpty ? failure.statusName : "\(failure.statusName): \(messages.joined(separator: "; "))"
        return SecretRedactor.redact(text, secrets: secrets)
    }
}
