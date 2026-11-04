import Foundation
import Security
import WakeWordKit
import os

/// What the Keychain said about one item.
public enum KeychainReadResult: Equatable, Sendable {
    case found(Data)
    case notFound
    /// The Keychain could not answer (locked, access declined, interaction not allowed …).
    case failed(OSStatus)
}

/// The three Keychain operations the credential store needs. The real one talks to Security.framework;
/// tests substitute a fake to exercise failures that cannot be produced on demand.
public protocol KeychainBackend: Sendable {
    func read(service: String, account: String) -> KeychainReadResult
    /// Adds the item, or replaces its value if it exists.
    func write(_ data: Data, service: String, account: String, label: String) -> OSStatus
    /// Removing an absent item is success.
    func delete(service: String, account: String) -> OSStatus
}

/// Generic-password items in the user's login Keychain.
public struct SecurityKeychain: KeychainBackend {
    public init() {}

    private func query(_ service: String, _ account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    public func read(service: String, account: String) -> KeychainReadResult {
        var request = query(service, account)
        request[kSecReturnData] = true
        request[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return .failed(errSecInternalError) }
            return .found(data)
        case errSecItemNotFound:
            return .notFound
        default:
            return .failed(status)
        }
    }

    public func write(_ data: Data, service: String, account: String, label: String) -> OSStatus {
        var attributes = query(service, account)
        attributes[kSecValueData] = data
        attributes[kSecAttrLabel] = label
        let added = SecItemAdd(attributes as CFDictionary, nil)
        guard added == errSecDuplicateItem else { return added }
        return SecItemUpdate(query(service, account) as CFDictionary, [kSecValueData: data] as CFDictionary)
    }

    public func delete(service: String, account: String) -> OSStatus {
        let status = SecItemDelete(query(service, account) as CFDictionary)
        return status == errSecItemNotFound ? errSecSuccess : status
    }
}

/// Stores secrets (such as the Picovoice AccessKey) in the macOS Keychain as generic passwords.
///
/// * The secret never touches `UserDefaults`, files, logs or the process environment.
/// * **Answers are cached for the life of the process, failures are not.** The Keychain may ask the user to
///   approve access after the app is rebuilt with a different ad-hoc signature, and the runtime asks for the
///   key every time it (re)builds an engine — one prompt per launch is enough once it has been answered. But a
///   read that *failed* (the Keychain was locked, the user declined the prompt) says nothing about whether a key
///   exists: it is reported through ``accessProblem(for:)`` and retried on the next read, never remembered as
///   "no key".
/// * A read that overlaps a save can never overwrite the newer value in the cache.
public final class KeychainCredentialStore: CredentialStoring, @unchecked Sendable {
    public enum StoreError: Error, LocalizedError, Equatable {
        case keychain(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .keychain(let status):
                "The Keychain could not save the key (\(KeychainCredentialStore.describe(status)))."
            }
        }
    }

    private struct State {
        /// `nil` = never looked up; `.some(nil)` = looked up and absent.
        var cache: [CredentialKey: String?] = [:]
        var problems: [CredentialKey: String] = [:]
        /// Incremented by every save. A read remembers the value it started under and caches its result only
        /// if no save finished meanwhile.
        var version = 0
    }

    private let service: String
    private let backend: any KeychainBackend
    private let log = Logger(subsystem: "com.alejandro.friday", category: "keychain")
    private let state = Protected(State())
    /// Serialises saves so concurrent ones cannot leave the cache and the Keychain disagreeing. Readers never
    /// take it: a read may wait on a Keychain prompt, and must not hold anything a save needs.
    private let writeLock = NSLock()

    /// - Parameters:
    ///   - service: the Keychain "service" name; use the app's bundle identifier.
    ///   - backend: the Keychain implementation; tests pass a fake.
    public init(service: String, backend: any KeychainBackend = SecurityKeychain()) {
        self.service = service
        self.backend = backend
    }

    public func secret(for key: CredentialKey) -> String? {
        let (cached, startVersion) = state.withLock { ($0.cache[key], $0.version) }
        if let cached { return cached }

        let value: String?
        var problem: String?
        switch backend.read(service: service, account: key.description) {
        case .found(let data):
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                value = text
            } else {
                value = nil
                problem = "the stored value is not valid text"
            }
        case .notFound:
            value = nil
        case .failed(let status):
            value = nil
            problem = Self.describe(status)
            log.error("keychain read failed for \(key.description, privacy: .public): OSStatus \(status)")
        }

        return state.withLock { state in
            if state.version != startVersion {
                // A save finished while we were reading: its value is newer than what we read.
                if let newer = state.cache[key] { return newer }
                return value
            }
            if let problem {
                state.problems[key] = problem   // reported, retried next time, never cached as "absent"
            } else {
                state.problems[key] = nil
                state.cache[key] = .some(value)
            }
            return value
        }
    }

    public func accessProblem(for key: CredentialKey) -> String? {
        state.withLock { $0.problems[key] }
    }

    public func setSecret(_ value: String?, for key: CredentialKey) throws {
        writeLock.lock()
        defer { writeLock.unlock() }

        let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let keep = (cleaned?.isEmpty == false) ? cleaned : nil
        let status: OSStatus
        if let keep {
            status = backend.write(Data(keep.utf8), service: service, account: key.description, label: "Jarvis — \(key.name)")
        } else {
            status = backend.delete(service: service, account: key.description)
        }
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
        state.withLock { state in
            state.version += 1
            state.cache[key] = .some(keep)
            state.problems[key] = nil
        }
    }

    static func describe(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
    }
}
