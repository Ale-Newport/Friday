import Foundation

/// Identifies one secret an engine needs (for example Picovoice's AccessKey). Engines declare
/// the credentials they need via `EngineDescriptor.credentials`; the UI renders generic input
/// fields for them, so no engine-specific settings code lives outside the engine's module.
public struct CredentialKey: Hashable, Sendable, CustomStringConvertible {
    public let engineID: String
    public let name: String

    public init(engineID: String, name: String) {
        self.engineID = engineID
        self.name = name
    }

    public var description: String { "\(engineID).\(name)" }
}

/// A credential an engine needs, with the text the UI shows to explain it.
public struct CredentialRequirement: Identifiable, Hashable, Sendable {
    public var id: CredentialKey { key }
    public let key: CredentialKey
    public let title: String
    public let explanation: String
    public let helpURL: URL?

    public init(key: CredentialKey, title: String, explanation: String, helpURL: URL? = nil) {
        self.key = key
        self.title = title
        self.explanation = explanation
        self.helpURL = helpURL
    }
}

/// Read access to stored secrets. Engine factories receive this; they never see the store's
/// backing technology (Keychain in the app, in-memory in tests).
public protocol CredentialReading: Sendable {
    func secret(for key: CredentialKey) -> String?

    /// Why `secret(for:)` could not give the user's real answer — the store was unreadable (a locked
    /// Keychain, access the user declined …). `nil` means the answer, including "nothing stored", is genuine.
    /// Lets callers say "couldn’t read your key" instead of wrongly telling someone who saved one to enter it.
    func accessProblem(for key: CredentialKey) -> String?
}

extension CredentialReading {
    public func accessProblem(for key: CredentialKey) -> String? { nil }

    /// The stored secret, or the error an engine should report when there isn't a usable one: an unreadable
    /// store is `.credentialUnreadable`, a genuinely absent or empty secret is `.credentialMissing`.
    /// Engine factories should read their credentials through this so the two cases are never confused.
    public func requireSecret(for key: CredentialKey) throws(WakeWordError) -> String {
        if let secret = secret(for: key), !secret.isEmpty { return secret }
        if let problem = accessProblem(for: key) { throw .credentialUnreadable(key, detail: problem) }
        throw .credentialMissing(key)
    }
}

/// Read/write access to stored secrets.
public protocol CredentialStoring: CredentialReading {
    /// Stores `value`, or removes the secret when `value` is `nil` or empty.
    func setSecret(_ value: String?, for key: CredentialKey) throws
}

/// A credential store that keeps secrets in memory. For tests and tools; never persists.
public final class InMemoryCredentialStore: CredentialStoring, @unchecked Sendable {
    private let storage: Protected<[CredentialKey: String]>

    public init(_ initial: [CredentialKey: String] = [:]) {
        storage = Protected(initial)
    }

    public func secret(for key: CredentialKey) -> String? {
        storage.withLock { $0[key] }
    }

    public func setSecret(_ value: String?, for key: CredentialKey) throws {
        storage.withLock { state in
            if let value, !value.isEmpty {
                state[key] = value
            } else {
                state.removeValue(forKey: key)
            }
        }
    }
}

/// Removes secrets from text before it is displayed or logged. Native libraries sometimes echo
/// the key back in error messages (Picovoice's activation errors do), so every message that
/// originates outside this process is passed through here first.
public enum SecretRedactor {
    public static let mask = "••••"

    public static func redact(_ text: String, secrets: [String]) -> String {
        var result = text
        for secret in secrets where secret.count >= 4 {
            result = result.replacingOccurrences(of: secret, with: mask)
        }
        return result
    }
}
