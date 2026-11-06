import AppKit
import Foundation
import FridayAudio
import FridayAssistant
import FridayBrowser
import FridayComputer
import FridayCore
import FridayIPC
import FridayIntegrations
import FridayIntelligence
import FridayInterpreter
import FridayMemory
import FridayPlatform
import FridaySidecar
import FridaySpeech
import PorcupineBackend
import SherpaOnnxBackend
import SherpaOnnxSpeech
import WakeWordCore
import WakeWordKit

/// The composition root: the one place that knows which engines, providers, integrations and processes exist,
/// and wires them into the assistant. Everything else is engine-, provider- and tool-agnostic.
@MainActor
final class AppComposition {
    // Settings
    let defaults = UserDefaults.standard
    // The key is shared with the rain-check launch agent, which reads these settings from its own process.
    let engineSettings = UserDefaultsSettingsStore(key: ConditionService.settingsKey)
    let fridaySettings = FridaySettingsStore()
    let wakeSettingsStore: SettingsStore

    // Wake word (from the Speech project)
    let directories: AppDirectories
    let wakeRegistry: WakeWordEngineRegistry
    let resources: EngineResourceLocator
    let credentials: KeychainCredentialStore
    let capture: any AudioCaptureSource
    /// The microphone wrapper that lets `fridayctl --voice` play recordings into the pipeline (nil in synthetic mode).
    let injectable: InjectableCaptureSource?
    let devices: any AudioDeviceProviding
    let permission: any MicrophonePermissionProviding
    let loginItem: any LoginItemManaging
    let launch: LaunchOptions
    let wakeRuntime: WakeWordRuntime

    // Intelligence
    let secrets = KeychainSecretStore(service: "com.alejandro.friday")
    let auth: ChatGPTAuthService
    let providers: ProviderRegistry
    let router = IntentRouter()
    let planner: FridayPlanner

    // Memory and tools
    let memoryStore: MemoryStore?
    let scheduleStore: FileScheduleStore
    private(set) var scheduler: CommandScheduler?
    let meta = FridayMetaIntegration()
    let web = WebAgentIntegration()
    let computer = ComputerIntegration()
    let integrations: [any AppIntegration]
    let registry: ToolRegistry
    let history = HistoryStore()
    let engine: ActionEngine
    let ipc: IPCController

    // Speech
    let recorder = MicrophoneRecorder(seconds: 30)
    let speechResources: SherpaOnnxSpeechResources
    let kokoro: KokoroTextToSpeech
    let output: SpeechOutput
    let listener: VoiceListener

    // Sidecar (browser agent + Laya)
    let sidecar: SidecarProcess?

    let assistant: Assistant

    init(arguments: [String] = CommandLine.arguments) {
        launch = LaunchOptions(arguments)
        directories = AppDirectories(appName: "Friday")
        directories.ensureUserModelsExists()
        let bundle = Bundle.main
        resources = EngineResourceLocator(
            searchDirectories: [bundle.resourceURL?.appendingPathComponent("Engines"), directories.userModels].compactMap { $0 },
            libraryDirectories: [bundle.privateFrameworksURL].compactMap { $0 })
        wakeRegistry = WakeWordEngineRegistry([
            SherpaOnnxBackend.descriptor(profileDirectory: directories.userModels, referenceSpeechCache: directories.referenceSpeech),
            PorcupineBackend.descriptor,
            MockWakeWordEngine.descriptor(),
        ])
        if launch.syntheticAudio {
            let synthetic = SyntheticAudioSource(sampleRate: 48_000)
            synthetic.setSignal(.whiteNoise(amplitude: 0.002))
            capture = SyntheticRealTimeSource(synthetic)
            injectable = nil
            permission = AlwaysAuthorizedPermission()
        } else {
            let microphone = InjectableCaptureSource(wrapping: AVAudioEngineCaptureSource())
            capture = microphone
            injectable = microphone
            permission = SystemMicrophonePermission()
        }
        devices = CoreAudioDeviceCatalog()
        credentials = KeychainCredentialStore(service: bundle.bundleIdentifier ?? "com.alejandro.friday")
        loginItem = MainAppLoginItem()
        wakeSettingsStore = SettingsStore(defaults: defaults)

        // Intelligence
        let settingsStore = fridaySettings
        auth = ChatGPTAuthService(secrets: secrets, defaults: .standard, appName: "Friday")
        providers = ProviderRegistry(auth: auth, secrets: secrets) { settingsStore.intelligenceSettings }

        // Memory
        let memoryURL = JarvisPaths.applicationSupportDirectory().appendingPathComponent("memory.sqlite")
        JarvisPaths.ensurePrivateDirectory(JarvisPaths.applicationSupportDirectory())
        memoryStore = try? MemoryStore(databaseURL: memoryURL)
        scheduleStore = FileScheduleStore(url: JarvisPaths.applicationSupportDirectory().appendingPathComponent("schedule.json"))

        // Tools: everything from Apple-Integrations plus Friday's new integrations.
        var all: [any AppIntegration] = IntegrationCatalog.makeDefault()
        all.append(meta)
        all.append(web)
        all.append(computer)
        if let memoryStore { all.append(MemoryIntegration(store: memoryStore)) }
        all.append(ScheduleIntegration(store: scheduleStore))
        integrations = all
        registry = ToolRegistry(integrations: all)
        meta.setCatalog(registry.descriptors)

        let memoryAdapter: any PlannerMemory = memoryStore.map { PlannerMemoryAdapter(store: $0) } ?? NoPlannerMemory()
        planner = FridayPlanner(
            providers: providers, router: router, memory: memoryAdapter, context: ScreenContextProvider(computer: computer),
            settings: { settingsStore.intelligenceSettings })
        engine = ActionEngine(registry: registry, interpreter: planner, settings: engineSettings, history: history, fallbackLanguage: Self.systemLanguage)

        // Speech
        speechResources = SherpaOnnxSpeechResources.locate(bundle: bundle) ?? SherpaOnnxSpeechResources.developmentDefault(repositoryRoot: Self.repositoryRoot)
        kokoro = KokoroTextToSpeech(resources: speechResources)
        output = SpeechOutput(engines: [kokoro, AppleTextToSpeech()]) { settingsStore.voiceSettings }
        let speechResources = self.speechResources
        listener = VoiceListener(
            recorder: recorder, recognizers: [AppleSpeechRecognizer()],
            detector: {
                let silence = Float(settingsStore.voiceSettings.endpointSilenceSeconds)
                let silero = SileroVoiceActivityDetector(configuration: .init(resources: speechResources, minSilenceDuration: silence))
                if silero.availability().isAvailable { return silero }
                return EnergyVoiceActivityDetector(minimumSilence: Double(silence))
            },
            settings: { settingsStore.voiceSettings })

        // Sidecar
        let dataDirectory = JarvisPaths.applicationSupportDirectory().appendingPathComponent("sidecar", isDirectory: true)
        if let launchMode = SidecarLaunchConfiguration.locate(bundle: bundle, repositoryRoot: Self.repositoryRoot) {
            sidecar = SidecarProcess(configuration: SidecarLaunchConfiguration(
                launch: launchMode, dataDirectory: dataDirectory,
                downloadsDirectory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/Friday")))
        } else {
            sidecar = nil
        }

        let memoryStore = self.memoryStore
        assistant = Assistant(
            engine: engine, registry: registry, planner: planner, listener: listener, output: output, web: web,
            settings: { settingsStore.voiceSettings },
            onTurn: { user, reply, language in
                guard let memoryStore else { return }
                try? await memoryStore.appendTurn(session: "friday", role: "user", text: user, language: language?.rawValue, toolSummary: nil)
                try? await memoryStore.appendTurn(session: "friday", role: "assistant", text: reply, language: language?.rawValue, toolSummary: nil)
            })
        web.setInteractionHandler(assistant)

        // Wake word runtime: the assistant is its activation handler; the recorder is its audio tap.
        var loaded = wakeSettingsStore.load(defaultEngineID: wakeRegistry.defaultEngineID ?? "")
        if let override = launch.engineOverride, wakeRegistry[override] != nil { loaded.engineID = override; loaded.developerMode = true }
        if wakeRegistry[loaded.engineID] == nil { loaded.engineID = wakeRegistry.defaultEngineID ?? loaded.engineID }
        loaded.maxSessionDuration = max(loaded.maxSessionDuration, 600)  // conversations and browser tasks take a while
        loaded.isEnabled = settingsStore.voiceSettings.wakeWordEnabled
        wakeRuntime = WakeWordRuntime(
            settings: loaded,
            dependencies: RuntimeDependencies(
                registry: wakeRegistry, credentials: credentials, resources: resources, capture: capture, devices: devices,
                permission: permission, systemEvents: WorkspaceSystemEvents(), network: NWPathNetworkMonitor(),
                assistant: AssistantActivationBridge(assistant: assistant)))
        let recorder = self.recorder
        wakeRuntime.setAudioTap { samples, rate in recorder.tap(samples, sampleRate: rate) }

        // Control channel (fridayctl): engine requests plus the assistant-level ones.
        ipc = IPCController(
            engine: engine, integrations: all, appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1",
            assistantExtension: AssistantIPCExtension(assistant: assistant, output: output, injectable: injectable, wakeRuntime: wakeRuntime))
    }

    static var systemLanguage: Language {
        for identifier in Locale.preferredLanguages { if let language = Language(hint: identifier) { return language } }
        return .en
    }

    /// The checkout this binary was built from (development only; the packaged app ships everything inside).
    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    // MARK: Lifecycle

    func startServices() async {
        ipc.apply(enabled: engineSettings.snapshot().ipcEnabled)
        await wakeRuntime.start()
        let assistant = self.assistant
        let scheduler = CommandScheduler(store: scheduleStore) { item in
            await assistant.submit(item.command, source: "schedule", session: "schedule", speak: true)
        }
        self.scheduler = scheduler
        await scheduler.start()
        // The sidecar's planning session uses Friday's model credentials; ChatGPT access tokens last an hour.
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20 * 60))
                await self?.applyLLMSessionToSidecar()
            }
        }
        Task.detached(priority: .utility) { [output, listener] in
            await output.warmUp()
            await listener.warmUp()
        }
        startSidecar()
    }

    func startSidecar() {
        guard let sidecar else { return }
        Task { [weak self] in
            do {
                let endpoint = try await sidecar.start()
                let client = SidecarClient(endpoint: endpoint)
                self?.web.setClient(client)
                await self?.router.setClient(client)
                await self?.applyLLMSessionToSidecar()
                _ = try? await client.loadLaya()
            } catch {
                JarvisLog.app.error("sidecar start failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Points the browser planner at the same model Friday uses (ChatGPT plan token or API key), through the
    /// sidecar's in-memory session so the key is never persisted there.
    func applyLLMSessionToSidecar() async {
        guard let sidecar, let endpoint = await sidecar.endpoint else { return }
        let client = SidecarClient(endpoint: endpoint)
        if let resolved = await providers.resolve(.planning) {
            switch resolved.providerID {
            case "chatgpt":
                if let token = try? await auth.validAccessToken() {
                    _ = try? await client.put("api/llm/session", ["base_url": "https://api.openai.com/v1", "model": .string(resolved.model), "api": "responses", "api_key": .string(token)])
                    return
                }
            case "openai":
                if let key = try? secrets.secret(for: OpenAIKeyProvider.keychainAccount) {
                    _ = try? await client.put("api/llm/session", ["base_url": "https://api.openai.com/v1", "model": .string(resolved.model), "api": "responses", "api_key": .string(key)])
                    return
                }
            case "compatible":
                let settings = fridaySettings.intelligenceSettings
                _ = try? await client.put("api/llm/session", ["base_url": .string(settings.compatibleEndpoint), "model": .string(resolved.model), "api": "chat"])
                return
            default: break
            }
        }
        _ = try? await client.delete("api/llm/session")
    }

    func shutdownImmediately() {
        wakeRuntime.shutdownImmediately()
        sidecar?.terminateImmediately()
        ipc.stop()
    }
}

// MARK: - Adapters

/// Memory for the planner: relevant facts and saved routines.
struct PlannerMemoryAdapter: PlannerMemory {
    let store: MemoryStore
    func relevantFacts(for text: String, limit: Int) async -> [String] {
        let items = (try? await store.recall(query: text, kinds: [.preference, .entity, .knowledge], limit: limit)) ?? []
        return items.map { item in (item.key.map { "\($0): " } ?? "") + item.content }
    }
    func routineSteps(matching text: String) async -> (name: String, steps: [ToolCall])? {
        guard let routine = try? await store.findRoutine(matching: text) else { return nil }
        try? await store.markRoutineRun(id: routine.id)
        return (routine.name, routine.steps)
    }
}

/// Screen context for reference resolution ("summarize this"): frontmost app, window title, selection.
struct ScreenContextProvider: ContextProviding {
    let computer: ComputerIntegration
    func currentContext() async -> RequestContext {
        var context = RequestContext()
        if let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != Bundle.main.bundleIdentifier {
            context.frontmostApp = app.localizedName
        }
        if let info = try? await computer.accessibility.focusedWindow() { context.frontmostWindowTitle = info.title }
        if ComputerPermissions.accessibilityStatus() == .granted, let selection = try? await computer.accessibility.selectedText(), !selection.isEmpty {
            context.selectedText = String(selection.prefix(4000))
        }
        return context
    }
}

// Development switches, as in the wake-word project.
struct LaunchOptions {
    var syntheticAudio = false
    var engineOverride: String?
    var probeEngines = false
    var showWelcome = false
    var simulateAfter: Double?
    var noSidecar = false

    init(_ arguments: [String]) {
        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--synthetic-audio": syntheticAudio = true
            case "--probe-engines": probeEngines = true
            case "--show-welcome": showWelcome = true
            case "--no-sidecar": noSidecar = true
            case "--engine": engineOverride = iterator.next()
            case "--simulate-after": simulateAfter = iterator.next().flatMap(Double.init)
            default: break
            }
        }
    }
}

struct AlwaysAuthorizedPermission: MicrophonePermissionProviding {
    func status() -> MicrophoneAuthorization { .authorized }
    func request() async -> MicrophoneAuthorization { .authorized }
}

final class SyntheticRealTimeSource: AudioCaptureSource, @unchecked Sendable {
    private let source: SyntheticAudioSource
    init(_ source: SyntheticAudioSource) { self.source = source }
    var isRunning: Bool { source.isRunning }
    func events() -> AsyncStream<AudioCaptureEvent> { source.events() }
    func stop() { source.stop() }
    @discardableResult
    func start(input: AudioInputSelection, handler: @escaping AudioChunkHandler) throws(AudioCaptureError) -> AudioCaptureInfo {
        let info = try source.start(input: input, handler: handler)
        source.beginRealTimeGeneration(chunkDuration: 0.1)
        return info
    }
}
