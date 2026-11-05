// Adapted from Apple-Integrations/App/AppEnvironment.swift (same author).
import Foundation
import FridayCore
import FridayIPC
import Observation

/// Starts and stops the local control channel (`fridayctl` and other local programs) according to the user's setting.
@MainActor
@Observable
final class IPCController {
    private(set) var isRunning = false
    private(set) var lastError: String?
    let socketPath: String

    private let engine: ActionEngine
    private let integrations: [any AppIntegration]
    private let appVersion: String
    private let assistantExtension: AssistantIPCExtension?
    private var server: IPCServer?

    init(engine: ActionEngine, integrations: [any AppIntegration], appVersion: String, assistantExtension: AssistantIPCExtension? = nil, socketURL: URL = JarvisPaths.socketFile()) {
        self.engine = engine
        self.integrations = integrations
        self.appVersion = appVersion
        self.assistantExtension = assistantExtension
        self.socketPath = socketURL.path
    }

    func apply(enabled: Bool) {
        if enabled { start() } else { stop() }
    }

    func start() {
        guard server == nil else { return }
        let integrations = self.integrations
        let assistantExtension = self.assistantExtension
        let statusProvider: @Sendable () async -> JSONValue = {
            var status: JSONObject = await Self.statusJSON(integrations).objectValue ?? [:]
            if let assistantExtension { status["voice"] = await assistantExtension.voiceStatus() }
            return .object(status)
        }
        var extensionHandler: EngineIPCHandler.Extension? = nil
        if let assistantExtension {
            extensionHandler = { request, connectionID in await assistantExtension.handle(request, connectionID: connectionID) }
        }
        let handler = EngineIPCHandler(engine: engine, appVersion: appVersion, statusProvider: statusProvider, extensionHandler: extensionHandler)
        let candidate = IPCServer(socketURL: URL(fileURLWithPath: socketPath), handler: handler)
        do {
            try candidate.start()
            server = candidate
            isRunning = true
            lastError = nil
        } catch IPCError.alreadyRunning {
            lastError = "Another copy of Friday is already listening on the control channel."
            isRunning = false
        } catch {
            lastError = "Could not open the control channel: \(error)"
            isRunning = false
        }
    }

    func stop() {
        server?.stop()
        server = nil
        isRunning = false
    }

    /// JSON description of every integration's state, returned for IPC `status` requests.
    static func statusJSON(_ integrations: [any AppIntegration]) async -> JSONValue {
        var entries: [JSONValue] = []
        for integration in integrations {
            let status = await integration.status()
            var object: JSONObject = [
                "id": .string(integration.id.rawValue), "name": .string(integration.displayName.en), "state": .string(status.state.rawValue),
            ]
            if let detail = status.detail { object["detail"] = .string(detail.en) }
            object["permissions"] = .array(status.permissions.map { entry in
                let state: String
                switch entry.state {
                case .authorized: state = "authorized"
                case .notDetermined: state = "not_determined"
                case .denied: state = "denied"
                case .restricted: state = "restricted"
                case .unavailable: state = "unavailable"
                }
                return .object(["id": .string(entry.requirement.id), "state": .string(state)])
            })
            entries.append(.object(object))
        }
        return .object(["integrations": .array(entries)])
    }
}
