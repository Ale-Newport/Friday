import AppKit
import Foundation
import Security
import Testing
import WakeWordKit
@testable import WakeWordCore
@testable import FridayPlatform

// MARK: - Keychain

enum KeychainProbe {
    /// Whether this process can use the user's Keychain right now (it cannot on a locked or headless
    /// machine). Tests that need it are skipped, not failed, when it is unavailable.
    static let isUsable: Bool = {
        let service = "com.alejandro.jarvis.tests.probe.\(UUID().uuidString)"
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: "probe",
            kSecValueData: Data("x".utf8),
        ]
        let added = SecItemAdd(query as CFDictionary, nil) == errSecSuccess
        if added { SecItemDelete(query as CFDictionary) }
        return added
    }()
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["FRIDAY_SKIP_DESKTOP_TESTS"] == nil && KeychainProbe.isUsable, "the Keychain is not available to this process (or FRIDAY_SKIP_DESKTOP_TESTS is set)"))
struct KeychainCredentialStoreTests {
    static let key = CredentialKey(engineID: "test-engine", name: "AccessKey")

    @Test func savesReadsUpdatesAndDeletesASecret() throws {
        let service = "com.alejandro.jarvis.tests.\(UUID().uuidString)"
        let store = KeychainCredentialStore(service: service)
        defer { try? store.setSecret(nil, for: Self.key) }

        #expect(store.secret(for: Self.key) == nil)
        try store.setSecret("first-secret-value", for: Self.key)
        #expect(store.secret(for: Self.key) == "first-secret-value")

        // A different instance has no cache, so this really reads the Keychain.
        #expect(KeychainCredentialStore(service: service).secret(for: Self.key) == "first-secret-value")

        try store.setSecret("second-secret-value", for: Self.key)
        #expect(KeychainCredentialStore(service: service).secret(for: Self.key) == "second-secret-value")

        try store.setSecret(nil, for: Self.key)
        #expect(store.secret(for: Self.key) == nil)
        #expect(KeychainCredentialStore(service: service).secret(for: Self.key) == nil)
    }

    @Test func whitespaceIsTrimmedAndEmptyMeansRemove() throws {
        let store = KeychainCredentialStore(service: "com.alejandro.jarvis.tests.\(UUID().uuidString)")
        defer { try? store.setSecret(nil, for: Self.key) }
        try store.setSecret("  padded-key \n", for: Self.key)
        #expect(store.secret(for: Self.key) == "padded-key")
        try store.setSecret("   ", for: Self.key)
        #expect(store.secret(for: Self.key) == nil)
    }

    @Test func servicesAreIsolatedFromEachOther() throws {
        let a = KeychainCredentialStore(service: "com.alejandro.jarvis.tests.\(UUID().uuidString)")
        let b = KeychainCredentialStore(service: "com.alejandro.jarvis.tests.\(UUID().uuidString)")
        defer { try? a.setSecret(nil, for: Self.key); try? b.setSecret(nil, for: Self.key) }
        try a.setSecret("only-in-a", for: Self.key)
        #expect(b.secret(for: Self.key) == nil)
    }
}

/// A Keychain that can be scripted to fail, to stall mid-read, or to answer from memory.
final class FakeKeychain: KeychainBackend, @unchecked Sendable {
    private struct State {
        var items: [String: Data] = [:]
        var scripted: [KeychainReadResult] = []
        var reads = 0
        var writes = 0
        var writeStatus: OSStatus = errSecSuccess
        var holdNextRead = false
    }
    private let state = Protected(State())
    private let held = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    var reads: Int { state.withLock { $0.reads } }
    var writes: Int { state.withLock { $0.writes } }
    func stored(_ account: String) -> String? { state.withLock { $0.items[account] }.flatMap { String(data: $0, encoding: .utf8) } }
    func seed(_ value: String, account: String) { state.withLock { $0.items[account] = Data(value.utf8) } }
    func seedRaw(_ data: Data, account: String) { state.withLock { $0.items[account] = data } }
    func script(_ results: [KeychainReadResult]) { state.withLock { $0.scripted = results } }
    func failWrites(with status: OSStatus) { state.withLock { $0.writeStatus = status } }
    /// The next read fetches its answer and then waits until `releaseHeldRead()`.
    func holdNextRead() { state.withLock { $0.holdNextRead = true } }
    func waitUntilReadIsHeld() { held.wait() }
    func releaseHeldRead() { release.signal() }

    func read(service: String, account: String) -> KeychainReadResult {
        let (result, hold) = state.withLock { state -> (KeychainReadResult, Bool) in
            state.reads += 1
            let hold = state.holdNextRead
            state.holdNextRead = false
            if !state.scripted.isEmpty { return (state.scripted.removeFirst(), hold) }
            return (state.items[account].map { .found($0) } ?? .notFound, hold)
        }
        if hold { held.signal(); release.wait() }
        return result
    }

    func write(_ data: Data, service: String, account: String, label: String) -> OSStatus {
        let status = state.withLock { state -> OSStatus in
            state.writes += 1
            guard state.writeStatus == errSecSuccess else { return state.writeStatus }
            state.items[account] = data
            return errSecSuccess
        }
        // The item is committed but the caller has not heard yet: exactly the window in which a concurrent save
        // could slip in and leave the caller's cache disagreeing with what the Keychain now holds.
        usleep(UInt32.random(in: 0...200))
        return status
    }

    func delete(service: String, account: String) -> OSStatus {
        state.withLock { state in
            guard state.writeStatus == errSecSuccess else { return state.writeStatus }
            state.items[account] = nil
            return errSecSuccess
        }
    }
}

struct KeychainCredentialStoreLogicTests {
    static let key = CredentialKey(engineID: "test-engine", name: "AccessKey")
    static var account: String { key.description }

    @Test func aFailedReadIsReportedAndRetriedNeverRememberedAsNoKey() {
        let keychain = FakeKeychain()
        keychain.seed("the-saved-key-value", account: Self.account)
        keychain.script([.failed(errSecInteractionNotAllowed)])   // locked, or the user declined the prompt
        let store = KeychainCredentialStore(service: "svc", backend: keychain)

        #expect(store.secret(for: Self.key) == nil)
        #expect(store.accessProblem(for: Self.key) != nil, "so the UI can say \"can’t read\" instead of \"not set\"")

        #expect(store.secret(for: Self.key) == "the-saved-key-value", "the next read asks the Keychain again and succeeds")
        #expect(store.accessProblem(for: Self.key) == nil)
        #expect(keychain.reads == 2)
        #expect(store.secret(for: Self.key) == "the-saved-key-value")
        #expect(keychain.reads == 2, "an answer, once given, is remembered")
    }

    @Test func aGenuinelyAbsentKeyIsRememberedWithoutAProblem() {
        let keychain = FakeKeychain()
        let store = KeychainCredentialStore(service: "svc", backend: keychain)
        #expect(store.secret(for: Self.key) == nil)
        #expect(store.accessProblem(for: Self.key) == nil)
        #expect(store.secret(for: Self.key) == nil)
        #expect(keychain.reads == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func aReadThatOverlapsASaveNeverOverwritesTheNewerValue() throws {
        let keychain = FakeKeychain()
        keychain.seed("old-secret-value", account: Self.account)
        let store = KeychainCredentialStore(service: "svc", backend: keychain)
        keychain.holdNextRead()

        let readerResult = Protected<String?>(nil)
        let readerDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            readerResult.withLock { $0 = store.secret(for: Self.key) }
            readerDone.signal()
        }
        keychain.waitUntilReadIsHeld()                 // the reader holds the OLD value, uncached
        try store.setSecret("new-secret-value", for: Self.key)
        keychain.releaseHeldRead()
        readerDone.wait()

        #expect(readerResult.get() == "new-secret-value", "the reader notices a save finished while it was reading")
        #expect(store.secret(for: Self.key) == "new-secret-value")
        #expect(KeychainCredentialStore(service: "svc", backend: keychain).secret(for: Self.key) == "new-secret-value")
    }

    @Test func aFailedSaveThrowsAndKeepsTheKeyThatWasThere() throws {
        let keychain = FakeKeychain()
        let store = KeychainCredentialStore(service: "svc", backend: keychain)
        try store.setSecret("original-key-value", for: Self.key)

        keychain.failWrites(with: errSecAuthFailed)
        #expect(throws: KeychainCredentialStore.StoreError.keychain(errSecAuthFailed)) {
            try store.setSecret("replacement-value", for: Self.key)
        }
        #expect(throws: KeychainCredentialStore.StoreError.keychain(errSecAuthFailed)) { try store.setSecret(nil, for: Self.key) }
        #expect(store.secret(for: Self.key) == "original-key-value", "a save that did not happen must not look as if it did")
        #expect(KeychainCredentialStore.StoreError.keychain(errSecAuthFailed).errorDescription?.contains("Keychain") == true)
    }

    @Test func aStoredValueThatIsNotTextIsReportedNotUsed() {
        let keychain = FakeKeychain()
        keychain.seedRaw(Data([0xFF, 0xFE, 0xFD]), account: Self.account)
        let store = KeychainCredentialStore(service: "svc", backend: keychain)
        #expect(store.secret(for: Self.key) == nil)
        #expect(store.accessProblem(for: Self.key)?.contains("not valid text") == true)
    }

    @Test func savingClearsAnEarlierAccessProblem() throws {
        let keychain = FakeKeychain()
        keychain.script([.failed(errSecAuthFailed)])
        let store = KeychainCredentialStore(service: "svc", backend: keychain)
        #expect(store.secret(for: Self.key) == nil && store.accessProblem(for: Self.key) != nil)
        try store.setSecret("fresh-key-value", for: Self.key)
        #expect(store.accessProblem(for: Self.key) == nil)
        #expect(store.secret(for: Self.key) == "fresh-key-value")
    }
}

// MARK: - System events

struct WorkspaceSystemEventsTests {
    @Test func mapsSystemNotificationsToEventsInOrder() async throws {
        let workspace = NotificationCenter(), application = NotificationCenter()
        let source = WorkspaceSystemEvents(workspaceCenter: workspace, applicationCenter: application)
        var iterator = source.events().makeAsyncIterator()

        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        workspace.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        application.post(name: NSApplication.didBecomeActiveNotification, object: nil)

        var received: [SystemEvent] = []
        for _ in 0..<5 { if let event = await iterator.next() { received.append(event) } }
        #expect(received == [.willSleep, .didWake, .userSessionDidResignActive, .userSessionDidBecomeActive, .applicationDidBecomeActive])
    }

    @Test func unrelatedNotificationsAreIgnored() async throws {
        let workspace = NotificationCenter()
        let source = WorkspaceSystemEvents(workspaceCenter: workspace, applicationCenter: NotificationCenter())
        var iterator = source.events().makeAsyncIterator()
        workspace.post(name: Notification.Name("something.else"), object: nil)
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(await iterator.next() == .willSleep)
    }

    @Test func stopsObservingWhenReleased() {
        let center = NotificationCenter()
        var source: WorkspaceSystemEvents? = WorkspaceSystemEvents(workspaceCenter: center, applicationCenter: NotificationCenter())
        let stream = source!.events()
        source = nil
        // Posting after release must be harmless (the observers were removed).
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        _ = stream
    }
}

// MARK: - Network

struct NetworkMonitorTests {
    @Test func theRealMonitorReportsReachabilityAndIsSafeToAbandon() async {
        let monitor = NWPathNetworkMonitor()
        _ = monitor.isOnline                       // optimistic until the system reports a path
        let task = Task { for await _ in monitor.changes() {} }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        _ = await task.value
    }
}

// MARK: - Login item

struct LoginItemTests {
    @Test func readingTheRealStatusIsSafe() {
        // We never register from a test (that would change the machine's login items); just make sure
        // the system call works and yields one of the documented states.
        let status = MainAppLoginItem().status
        #expect([.enabled, .notRegistered, .requiresApproval, .unavailable].contains(status))
    }
}

// MARK: - Process-wide measurements

/// Tests that read whole-process counters (CPU, memory), or deliberately load every core, must not overlap one
/// another: a stress test running next to a "this loop uses about one core" measurement would change its answer.
/// (Suites run in parallel by default; everything nested here runs one test at a time.)
@Suite(.serialized)
enum ProcessWide {
    @Suite struct KeychainStress {
        static let key = CredentialKey(engineID: "test-engine", name: "AccessKey")

        @Test func concurrentSavesLeaveTheCacheAndTheKeychainAgreeing() {
            let keychain = FakeKeychain()
            let store = KeychainCredentialStore(service: "svc", backend: keychain)
            // Many short bursts, each checked: whatever the Keychain ended up holding is what the app must believe.
            // (One long burst would only look at the very last pair of saves; this looks at twenty-five.)
            for round in 0..<25 {
                DispatchQueue.concurrentPerform(iterations: 64) { index in
                    try? store.setSecret("secret-\(round)-\(index)", for: Self.key)
                }
                let remembered = store.secret(for: Self.key)
                #expect(remembered != nil)
                #expect(remembered == keychain.stored(Self.key.description), "round \(round): the app believes something the Keychain does not hold")
            }
        }
    }

    @Suite struct ResourceSamplerTests {
        /// Burns this thread's *CPU time*, not wall time: on a busy machine (a build, a browser test run) a thread may run for
        /// only part of any wall-clock interval, and a wall-clock loop would then register less CPU than it was meant to.
        static func burnCPU(milliseconds: Int) {
            func threadCPUSeconds() -> Double {
                var time = timespec()
                clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
                return Double(time.tv_sec) + Double(time.tv_nsec) / 1e9
            }
            let target = threadCPUSeconds() + Double(milliseconds) / 1_000
            let giveUp = ContinuousClock.now + .seconds(30)
            var value = 0.0
            while threadCPUSeconds() < target, ContinuousClock.now < giveUp { for i in 0..<10_000 { value += sin(Double(i)) } }
            precondition(value.isFinite)
        }

        @Test func readsRealCountersForTheCurrentProcess() throws {
            let sample = try #require(ResourceSampler.sample())
            #expect(sample.pid == getpid())
            #expect(sample.footprintBytes > 1_000_000, "a running process has a measurable memory footprint")
            #expect(sample.peakFootprintBytes >= sample.footprintBytes / 2)
            #expect(sample.cpuSeconds > 0)
            #expect(sample.cycles > 0 && sample.instructions > 0)
        }

        @Test func cpuTimeAndEnergyGrowWhenTheProcessWorks() throws {
            let before = try #require(ResourceSampler.sample())
            Self.burnCPU(milliseconds: 150)
            let after = try #require(ResourceSampler.sample())
            let usage = try #require(ResourceSampler.usage(from: before, to: after))

            #expect(after.cpuSeconds > before.cpuSeconds)
            #expect(after.energyJoules >= before.energyJoules)
            // The loop's own 150 ms must show up (other threads in the process may add to it, so there is no upper bound
            // on the busy time), and the percentage must be exactly that CPU time over the elapsed time.
            let busySeconds = after.cpuSeconds - before.cpuSeconds
            #expect(busySeconds >= 0.1, "a 150 ms busy loop should register at least 100 ms of CPU time, got \(busySeconds)")
            #expect(abs(usage.cpuPercent - 100 * busySeconds / usage.intervalSeconds) < 1, "cpuPercent is CPU time over elapsed time, got \(usage.cpuPercent)%")
            #expect(usage.intervalSeconds >= 0.14)
            #expect(usage.instructionsPerSecond > 1e6)
            if let power = usage.averagePowerMilliwatts { #expect(power > 0) }
        }

        @Test func anIdleProcessIsMeasuredAsNearlyIdle() async throws {
            let meter = ResourceMeter()
            try await Task.sleep(for: .milliseconds(300))
            let usage = try #require(meter.measure())
            #expect(usage.cpuPercent < 25, "sleeping should cost almost nothing, got \(usage.cpuPercent)%")
        }

        @Test func otherProcessesOfTheSameUserCanBeSampledAndMissingOnesCannot() {
            #expect(ResourceSampler.sample(pid: getppid()) != nil)
            #expect(ResourceSampler.sample(pid: 999_999) == nil)
        }

        @Test func usageNeedsTwoSamplesOfTheSameProcessSomeTimeApart() throws {
            let sample = try #require(ResourceSampler.sample())
            #expect(ResourceSampler.usage(from: sample, to: sample) == nil)
            var other = sample
            other.pid = sample.pid + 1
            other.takenAt = sample.takenAt.advanced(bySeconds: 1)
            #expect(ResourceSampler.usage(from: sample, to: other) == nil)
        }
    }
}

struct AppDirectoriesTests {
    @Test func layoutIsStableAndCreatesOnlyWhatIsAskedFor() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("dirs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let directories = AppDirectories(base: base)
        #expect(directories.applicationSupport.lastPathComponent == "Friday")
        #expect(directories.userModels.path.hasSuffix("Friday/Models"))
        #expect(directories.accuracyResults.lastPathComponent == "accuracy-results.json")
        #expect(!FileManager.default.fileExists(atPath: directories.userModels.path))
        directories.ensureUserModelsExists()
        #expect(FileManager.default.fileExists(atPath: directories.userModels.path))
    }
}
