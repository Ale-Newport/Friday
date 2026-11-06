import Foundation
import FridayCore
import FridaySidecar
@testable import FridayBrowser

/// A scripted sidecar: answers the REST calls the integration makes and lets a test push events, end the event
/// socket (a drop) or make polling fail, without any network.
actor FakeSidecar: SidecarTransport {
    struct Post: Sendable { let path: String; let body: JSONValue? }

    let taskID = "task-1"
    var task: JSONValue = ["status": "running", "steps": [], "current": ["title": "Working…", "url": "https://example.com"]]
    var pollFailuresLeft = 0
    var pollAlwaysFails = false
    var pollNotFound = false
    private(set) var posts: [Post] = []
    private(set) var subscriptions = 0
    private(set) var polls = 0
    private var continuations: [AsyncThrowingStream<JSONValue, any Error>.Continuation] = []
    private var seq = 0

    nonisolated func events() -> AsyncThrowingStream<JSONValue, any Error> {
        let (stream, continuation) = AsyncThrowingStream<JSONValue, any Error>.makeStream()
        Task { await self.register(continuation) }
        return stream
    }

    private func register(_ continuation: AsyncThrowingStream<JSONValue, any Error>.Continuation) {
        continuations.append(continuation)
        subscriptions += 1
    }

    func get(_ path: String, timeout: TimeInterval) async throws -> JSONValue {
        if path == "health" { return ["status": "ready"] }
        if path.hasPrefix("api/tasks/") {
            polls += 1
            if pollNotFound { throw SidecarError.http(status: 404, code: "not_found", message: "Task not found.") }
            if pollAlwaysFails { throw URLError(.cannotConnectToHost) }
            if pollFailuresLeft > 0 { pollFailuresLeft -= 1; throw URLError(.cannotConnectToHost) }
            return task
        }
        if path.hasPrefix("api/conversations/") { return ["messages": []] }
        if path == "api/status" { return ["chrome": ["state": "connected", "mode": "managed", "installed": true], "laya": ["state": "ready"], "llm": ["model": "m", "reachable": true]] }
        return .null
    }

    func post(_ path: String, _ body: JSONValue?, timeout: TimeInterval) async throws -> JSONValue {
        posts.append(Post(path: path, body: body))
        if path == "api/conversations" { return ["id": "conv-1"] }
        if path.hasSuffix("/messages") { return ["task": ["id": .string(taskID)]] }
        if path.hasSuffix("/cancel") { task = ["status": "cancelled", "steps": []]; return task }
        return ["ok": true]
    }

    func put(_ path: String, _ body: JSONValue, timeout: TimeInterval) async throws -> JSONValue { .null }

    // Test controls -----------------------------------------------------------------------------------------

    func setTask(_ value: JSONValue) { task = value }
    func setPollFailures(_ count: Int) { pollFailuresLeft = count }
    func setPollAlwaysFails(_ value: Bool) { pollAlwaysFails = value }
    func setPollNotFound(_ value: Bool) { pollNotFound = value }

    func emit(_ type: String, _ data: JSONValue, taskID: String? = nil) {
        seq += 1
        let event: JSONValue = ["seq": .int(seq), "ts": "", "type": .string(type), "task_id": .string(taskID ?? self.taskID), "data": data]
        for continuation in continuations { continuation.yield(event) }
    }

    /// Ends every open event socket, as the server does after its idle timeout or when it restarts.
    func dropSockets() {
        for continuation in continuations { continuation.finish() }
        continuations = []
    }

    func failSockets() {
        for continuation in continuations { continuation.finish(throwing: URLError(.networkConnectionLost)) }
        continuations = []
    }

    func waitForSubscribers(_ count: Int, timeout: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while subscriptions < count, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return subscriptions >= count
    }

    func waitForPost(suffix: String, count: Int = 1, timeout: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while posts.filter({ $0.path.hasSuffix(suffix) }).count < count, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return posts.filter { $0.path.hasSuffix(suffix) }.count >= count
    }

    func waitForPolls(_ count: Int, timeout: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while polls < count, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return polls >= count
    }
}

/// Records what the user was asked and answers with fixed replies.
final class RecordingInteraction: BrowserInteractionHandling, @unchecked Sendable {
    private let lock = NSLock()
    private var _approvals: [BrowserApproval] = []
    private var _waits: [(kind: String, message: String)] = []
    private var _progress: [BrowserProgress] = []
    var approveAnswer = true
    var waitAnswer = true
    /// When set, prompts block until the task is over (simulates a user who never answers).
    var neverAnswers = false

    var approvals: [BrowserApproval] { lock.withLock { _approvals } }
    var waits: [(kind: String, message: String)] { lock.withLock { _waits } }
    var progress: [BrowserProgress] { lock.withLock { _progress } }

    func approve(_ approval: BrowserApproval) async -> Bool {
        lock.withLock { _approvals.append(approval) }
        if neverAnswers { try? await Task.sleep(for: .seconds(60)) }
        return approveAnswer
    }

    func progress(_ progress: BrowserProgress) { lock.withLock { _progress.append(progress) } }

    func waitForUser(taskID: String, kind: String, message: String, url: String?) async -> Bool {
        lock.withLock { _waits.append((kind, message)) }
        if neverAnswers { try? await Task.sleep(for: .seconds(60)) }
        return waitAnswer
    }

    func waitForPrompts(approvals: Int = 0, waits: Int = 0, timeout: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while (self.approvals.count < approvals || self.waits.count < waits), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return self.approvals.count >= approvals && self.waits.count >= waits
    }
}

enum TestSupport {
    static func context(_ language: Language = .en) -> ExecutionContext {
        ExecutionContext(language: language, now: Date(), calendar: .current, settings: JarvisSettings(), source: .test)
    }

    static func integration(_ sidecar: FakeSidecar, interaction: RecordingInteraction, pollInterval: Duration = .milliseconds(100), maxPollFailures: Int = 6) -> WebAgentIntegration {
        let integration = WebAgentIntegration()
        integration.pollInterval = pollInterval
        integration.maxPollFailures = maxPollFailures
        integration.setTransport(sidecar)
        integration.setInteractionHandler(interaction)
        return integration
    }

    static func webTask(_ integration: WebAgentIntegration, goal: String = "open example.com") throws -> ValidatedToolCall {
        try ToolRegistry(integrations: [integration]).validate(ToolCall(tool: "web.task", arguments: ["goal": .string(goal)]))
    }
}
