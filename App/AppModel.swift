import AppKit
import Foundation
import FridayAssistant
import FridayBrowser
import FridayComputer
import FridayCore
import FridayIntelligence
import FridayMemory
import FridaySidecar
import FridaySpeech
import Observation
import SwiftUI
import WakeWordCore
import WakeWordKit

/// One latency report as the Diagnostics table shows it: identity by row, not by value, so two identical
/// measurements are two rows.
struct LatencyEntry: Identifiable {
    let id = UUID()
    let report: LatencyReport
}

/// State for every window: the assistant transcript and phase, the wake-word runtime, settings, providers.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel(composition: AppComposition())

    let composition: AppComposition

    // Assistant
    private(set) var assistant = AssistantSnapshot()
    var input = ""
    var focusRequest = 0

    // Wake word
    private(set) var wake: RuntimeSnapshot
    private(set) var wakeSettings: RuntimeSettings
    /// The "Train «Jarvis»" lesson while its window is open, why it cannot run, and the installed voice profile.
    var voiceLesson: VoiceLessonModel?
    var voiceLessonUnavailable: String?
    var voiceProfile: VoiceProfile?

    // Settings
    private(set) var voice: VoiceSettings
    private(set) var intelligence: IntelligenceSettings
    private(set) var engineSettings: JarvisSettings
    private(set) var hotkey: HotKeyCombo
    private(set) var hotkeyEnabled: Bool
    var hotkeyError: String?
    private(set) var launchAtLogin = false

    // Status
    private(set) var providers: [ProviderStatus] = []
    private(set) var chatGPT: ChatGPTCredentials?
    private(set) var sidecarState: SidecarProcess.State = .stopped
    private(set) var webStatus: WebAgentStatus?
    private(set) var integrationStatuses: [IntegrationID: IntegrationStatus] = [:]
    private(set) var voices: [TTSVoice] = []
    private(set) var ttsEngines: [(id: String, name: String, availability: FridaySpeech.EngineAvailability)] = []
    private(set) var recognizers: [(id: String, name: String, availability: FridaySpeech.EngineAvailability)] = []
    /// Local model servers found by the last probe (Settings ▸ Intelligence shows them); nil before the first probe.
    private(set) var localServers: [LocalModelDiscovery.Server]?
    private(set) var discoveringLocalServers = false
    var notice: String?
    var signInInProgress = false
    private(set) var latencyHistory: [LatencyEntry] = []

    private var started = false
    private var tasks: [Task<Void, Never>] = []
    private var intelligenceRefresh: Task<Void, Never>?
    @ObservationIgnored private var hud: AssistantHUDController?
    @ObservationIgnored private var observerID: UUID?

    init(composition: AppComposition) {
        self.composition = composition
        voice = composition.fridaySettings.voiceSettings
        intelligence = composition.fridaySettings.intelligenceSettings
        engineSettings = composition.engineSettings.snapshot()
        let defaults = composition.defaults
        hotkey = (defaults.data(forKey: "friday.hotkey").flatMap { try? JSONDecoder().decode(HotKeyCombo.self, from: $0) }) ?? .default
        hotkeyEnabled = defaults.object(forKey: "friday.hotkey.enabled") as? Bool ?? true
        // The runtime runs the fixed-up settings (a missing engine replaced, the session length raised), so edits start
        // from those: the first slider change must not re-apply a stale stored engine id.
        wakeSettings = composition.initialWakeSettings
        wake = .initial(settings: composition.initialWakeSettings, microphone: composition.permission.status())
    }

    static var systemLanguage: Language { AppComposition.systemLanguage }
    var language: Language { engineSettings.languagePreference.fixedLanguage ?? Self.systemLanguage }
    func t(_ english: String, _ spanish: String) -> String { language == .es ? spanish : english }

    // MARK: Start

    func start() async {
        guard !started else { return }
        started = true
        hud = AssistantHUDController(model: self)
        observerID = await composition.assistant.observe { [weak self] snapshot in
            Task { @MainActor in self?.receive(snapshot) }
        }
        let snapshots = await composition.wakeRuntime.snapshots()
        tasks.append(Task { [weak self] in
            for await snapshot in snapshots { self?.wake = snapshot }
        })
        if let sidecar = composition.sidecar {
            _ = await sidecar.observe { [weak self] state in Task { @MainActor in self?.sidecarState = state } }
        }
        launchAtLogin = composition.loginItem.status == .enabled
        applyHotkey()
        await composition.startServices()
        await refreshProviders()
        await refreshVoiceEngines()
        refreshIntegrationStatuses()
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                await self?.refreshWebStatus()
            }
        })
        tasks.append(Task { [weak self] in await self?.discoverLocalServers(announce: false) })
    }

    private func receive(_ snapshot: AssistantSnapshot) {
        // Snapshots cross to the main actor in independent tasks; an older one that lands late must not undo a newer one.
        guard snapshot.revision > assistant.revision else { return }
        let previous = assistant
        assistant = snapshot
        if let latency = snapshot.lastLatency, latency != previous.lastLatency {
            latencyHistory.append(LatencyEntry(report: latency))
            if latencyHistory.count > 50 { latencyHistory.removeFirst() }
        }
        hud?.update(for: snapshot)
    }

    /// Closes the microphone, the engine and the control channel synchronously, for quit paths that cannot wait.
    /// The sidecar is stopped by the delegate, which waits for it.
    func shutdownImmediately() {
        tasks.forEach { $0.cancel() }
        hud?.hideImmediately()
        composition.shutdownImmediately()
    }

    /// True exactly once per installation (or on every launch with `--show-welcome`): the menu-bar label opens the
    /// chat window then, because a menu-bar-only app otherwise shows nothing but a small icon the first time it starts.
    func consumeFirstRunSetup() -> Bool {
        let forced = composition.launch.showWelcome
        guard forced || !composition.wakeSettingsStore.hasSeenWelcome else { return false }
        if !forced { composition.wakeSettingsStore.hasSeenWelcome = true }
        return true
    }

    // MARK: Commands

    func submit(_ raw: String? = nil) {
        let text = (raw ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if raw == nil { input = "" }
        let assistant = composition.assistant
        Task { await assistant.submit(text, source: .app, session: "chat") }
    }

    /// Runs one tool directly (Settings buttons): no model is involved and the result shows in the chat transcript.
    @discardableResult
    func execute(_ tool: ToolName, arguments: JSONObject = [:]) async -> EngineResponse {
        await composition.assistant.execute(ToolCall(tool: tool, arguments: arguments), source: .app, session: "chat", speak: false)
    }

    func interrupt() {
        let assistant = composition.assistant
        Task { await assistant.interrupt() }
    }

    func clearConversation() {
        let assistant = composition.assistant
        Task { await assistant.clearConversation() }
    }

    func answer(_ prompt: PendingPrompt, index: Int?, approve: Bool?) {
        let assistant = composition.assistant
        switch prompt.kind {
        case .browserApproval:
            Task { await assistant.answerBrowserApproval(approve ?? false) }
        case .browserManual:
            Task { await assistant.answerManual(approve ?? false) }
        case .confirmation:
            guard let token = prompt.token else { Task { await assistant.interrupt() }; return }
            Task { await assistant.resolve(token: token, decision: approve == true ? .confirm : .cancel, label: approve == true ? t("Confirm", "Confirmar") : t("Cancel", "Cancelar")) }
        case .clarification:
            // A question without a token cannot be answered through the engine; dismissing it is all the buttons can do.
            guard let token = prompt.token else { Task { await assistant.interrupt() }; return }
            if let index, prompt.options.indices.contains(index) {
                Task { await assistant.resolve(token: token, decision: .choose(index), label: prompt.options[index]) }
            } else {
                Task { await assistant.resolve(token: token, decision: .cancel, label: t("Cancel", "Cancelar")) }
            }
        }
    }

    /// Hotkey, menu item, microphone button: start listening right now, whatever the wake-word detector is doing
    /// (off, paused, failed). When it cannot work, say why.
    func activateByKeyboard() {
        let runtime = composition.wakeRuntime
        Task {
            let outcome = await runtime.activateManually()
            if case .failed(let failure) = outcome { notice = manualActivationMessage(failure) }
        }
    }

    func manualActivationMessage(_ failure: ManualActivationFailure) -> String {
        switch failure {
        case .microphone(.restricted):
            return t("Friday can't listen: microphone access is restricted on this Mac.", "Friday no puede escuchar: el acceso al micrófono está restringido en este Mac.")
        case .microphone:
            return t("Friday can't listen: microphone access is off. Allow it in System Settings ▸ Privacy & Security ▸ Microphone.",
                     "Friday no puede escuchar: el acceso al micrófono está desactivado. Permítelo en Ajustes del Sistema ▸ Privacidad y seguridad ▸ Micrófono.")
        case .noInputDevice:
            return t("Friday can't listen: no microphone is connected.", "Friday no puede escuchar: no hay ningún micrófono conectado.")
        case .paused(.systemSleep):
            return t("Friday can't listen while the Mac is going to sleep.", "Friday no puede escuchar mientras el Mac entra en reposo.")
        case .paused(.userSessionInactive):
            return t("Friday can't listen while another user's session is active.", "Friday no puede escuchar mientras la sesión de otro usuario está activa.")
        case .paused:
            return t("Friday can't listen right now.", "Friday no puede escuchar ahora mismo.")
        case .detector(let detector):
            return t("Friday can't listen right now: ", "Friday no puede escuchar ahora mismo: ") + detector.message
        case .notRunning:
            return t("Friday's listener is not running. Try again in a moment.", "El sistema de escucha de Friday no está en marcha. Inténtalo de nuevo en un momento.")
        }
    }

    func toggleWakeWord() { setWakeWordEnabled(!voice.wakeWordEnabled) }

    func setWakeWordEnabled(_ enabled: Bool) {
        updateVoice { $0.wakeWordEnabled = enabled }
        updateWake { $0.isEnabled = enabled }
    }

    // MARK: Settings

    func updateVoice(_ change: (inout VoiceSettings) -> Void) {
        voice = composition.fridaySettings.updateVoice(change)
    }

    func voiceBinding<Value>(_ keyPath: WritableKeyPath<VoiceSettings, Value>) -> Binding<Value> {
        Binding(get: { self.voice[keyPath: keyPath] }, set: { value in self.updateVoice { $0[keyPath: keyPath] = value } })
    }

    /// Saves at once; the provider cache, the status list and the sidecar's planning session follow after a short
    /// pause, so typing an endpoint character by character does not re-read the Keychain and hit the sidecar per key.
    func updateIntelligence(_ change: (inout IntelligenceSettings) -> Void) {
        let before = intelligence
        intelligence = composition.fridaySettings.updateIntelligence(change)
        guard intelligence != before else { return }
        intelligenceRefresh?.cancel()
        intelligenceRefresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            await self.composition.providers.clearCache()
            await self.refreshProviders()
            await self.composition.applyLLMSessionToSidecar()
        }
    }

    func intelligenceBinding<Value>(_ keyPath: WritableKeyPath<IntelligenceSettings, Value>) -> Binding<Value> {
        Binding(get: { self.intelligence[keyPath: keyPath] }, set: { value in self.updateIntelligence { $0[keyPath: keyPath] = value } })
    }

    func updateEngineSettings(_ change: (inout JarvisSettings) -> Void) {
        let wasListening = engineSettings.ipcEnabled
        var copy = engineSettings
        change(&copy)
        engineSettings = copy.sanitized()
        composition.engineSettings.save(engineSettings)
        composition.ipc.apply(enabled: engineSettings.ipcEnabled)
        // Turning the control channel on must not look successful when the socket could not be opened.
        if engineSettings.ipcEnabled, !wasListening, !composition.ipc.isRunning, let error = composition.ipc.lastError {
            notice = t("The local control channel could not be opened: ", "No se pudo abrir el canal de control local: ") + error
        }
    }

    func engineBinding<Value>(_ keyPath: WritableKeyPath<JarvisSettings, Value>) -> Binding<Value> {
        Binding(get: { self.engineSettings[keyPath: keyPath] }, set: { value in self.updateEngineSettings { $0[keyPath: keyPath] = value } })
    }

    /// What Settings says under the control-channel toggle.
    var ipcStatusText: String {
        let ipc = composition.ipc
        if ipc.isRunning { return t("Listening at ", "Escuchando en ") + ipc.socketPath }
        if let error = ipc.lastError { return error }
        return t("Off", "Desactivado")
    }

    func updateWake(_ change: (inout RuntimeSettings) -> Void) {
        var new = wakeSettings
        change(&new)
        new.sensitivity = min(1, max(0, new.sensitivity))
        guard new != wakeSettings else { return }
        wakeSettings = new
        composition.wakeSettingsStore.save(new)
        var applied = new
        applied.maxSessionDuration = max(applied.maxSessionDuration, 600)
        let runtime = composition.wakeRuntime
        Task { await runtime.apply(applied) }
    }

    func wakeBinding<Value>(_ keyPath: WritableKeyPath<RuntimeSettings, Value>) -> Binding<Value> {
        Binding(get: { self.wakeSettings[keyPath: keyPath] }, set: { value in self.updateWake { $0[keyPath: keyPath] = value } })
    }

    func setHotkey(_ combo: HotKeyCombo) {
        hotkey = combo
        composition.defaults.set(try? JSONEncoder().encode(combo), forKey: "friday.hotkey")
        applyHotkey()
    }

    func setHotkeyEnabled(_ enabled: Bool) {
        hotkeyEnabled = enabled
        composition.defaults.set(enabled, forKey: "friday.hotkey.enabled")
        applyHotkey()
    }

    private func applyHotkey() {
        if hotkeyEnabled {
            let ok = GlobalHotKey.shared.register(hotkey) { [weak self] in self?.activateByKeyboard() }
            hotkeyError = ok ? nil : GlobalHotKey.shared.lastError
        } else {
            GlobalHotKey.shared.unregister()
            hotkeyError = nil
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try composition.loginItem.setEnabled(enabled)
            launchAtLogin = composition.loginItem.status == .enabled
        } catch {
            notice = error.localizedDescription
        }
    }

    // MARK: Providers

    func refreshProviders() async {
        providers = await composition.providers.statuses()
        chatGPT = await composition.auth.credentials()
    }

    func refreshModels(_ providerID: String) async {
        do {
            _ = try await composition.providers.models(for: providerID, forceRefresh: true)
        } catch {
            notice = ProviderErrorText.message(for: error, language: language)
        }
        await refreshProviders()
    }

    /// Set once the launch-time probe has configured a server: afterwards a provider the person switched off stays off.
    static let localDiscoveryConfiguredKey = "friday.localModels.autoConfigured"

    /// Looks for Ollama and LM Studio on this Mac. A server that answers while the compatible provider is not set up
    /// (no model chosen, endpoint untouched or ours) is enabled with its first chat model; a provider the person
    /// configured is never changed, and the launch-time probe configures one only once per installation. `announce`
    /// reports the outcome even when nothing changed (the Settings button); at launch only a change is told.
    func discoverLocalServers(announce: Bool) async {
        guard !discoveringLocalServers else { return }
        discoveringLocalServers = true
        defer { discoveringLocalServers = false }
        let found = await LocalModelDiscovery().probe()
        localServers = found
        let current = intelligence
        guard let server = found.first(where: { !$0.models.isEmpty }) ?? found.first else {
            if announce {
                notice = t("No local model server answered. Ollama listens at \(LocalModelDiscovery.ollamaRoot) and LM Studio at \(LocalModelDiscovery.lmStudioRoot) when they are running.",
                           "Ningún servidor de modelos local respondió. Ollama escucha en \(LocalModelDiscovery.ollamaRoot) y LM Studio en \(LocalModelDiscovery.lmStudioRoot) cuando están en marcha.")
            }
            return
        }
        let defaultEndpoint = IntelligenceSettings().compatibleEndpoint
        let endpointIsOurs = current.compatibleEndpoint.trimmingCharacters(in: .whitespaces).isEmpty
            || Self.sameServer(current.compatibleEndpoint, server.endpoint)
            || (!current.compatibleEnabled && Self.sameServer(current.compatibleEndpoint, defaultEndpoint))
        let mayConfigure = announce || !composition.defaults.bool(forKey: Self.localDiscoveryConfiguredKey)
        let unconfigured = current.compatibleModel.isEmpty && endpointIsOurs
        if unconfigured, mayConfigure, let model = server.models.first {
            updateIntelligence { settings in
                settings.compatibleEnabled = true
                settings.compatibleEndpoint = server.endpoint
                settings.compatibleModel = model
            }
            composition.defaults.set(true, forKey: Self.localDiscoveryConfiguredKey)
            notice = t("Found \(server.displayName) at \(server.endpoint) with \(server.models.count) models. Friday will use “\(model)” as its local model; change it in Settings ▸ Intelligence.",
                       "Encontrado \(server.displayName) en \(server.endpoint) con \(server.models.count) modelos. Friday usará «\(model)» como modelo local; cámbialo en Ajustes ▸ Inteligencia.")
        } else if announce {
            notice = localServersSummary
        }
    }

    /// One line per server found, for Settings ▸ Intelligence.
    var localServersSummary: String {
        guard let localServers else { return "" }
        if localServers.isEmpty { return t("No local model server found.", "No se encontró ningún servidor de modelos local.") }
        return localServers.map { server in
            let models = server.models.isEmpty
                ? t("no chat models", "sin modelos de chat")
                : (server.models.count == 1 ? server.models[0] : t("\(server.models.count) models", "\(server.models.count) modelos"))
            return "\(server.displayName)\(server.version.map { " \($0)" } ?? "") — \(server.endpoint) (\(models))"
        }.joined(separator: "\n")
    }

    static func sameServer(_ a: String, _ b: String) -> Bool {
        func key(_ text: String) -> String? {
            guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), let host = url.host?.lowercased() else { return nil }
            let normalizedHost = host == "localhost" || host == "::1" || host == "[::1]" ? "127.0.0.1" : host
            return "\(normalizedHost):\(url.port ?? (url.scheme == "https" ? 443 : 80))"
        }
        guard let left = key(a), let right = key(b) else { return false }
        return left == right
    }

    func signInWithChatGPT() {
        guard !signInInProgress else { return }
        signInInProgress = true
        let auth = composition.auth
        Task {
            defer { signInInProgress = false }
            do {
                let credentials = try await auth.signIn(openBrowser: { url in
                    Task { @MainActor in NSWorkspace.shared.open(url) }
                }, language: language)
                chatGPT = credentials
                if !credentials.planUsageGranted {
                    notice = t("Signed in, but ChatGPT plan usage was not granted. Sign in again and allow it, or use an API key.", "Sesión iniciada, pero no se concedió el uso del plan de ChatGPT. Vuelve a iniciar sesión y permítelo, o usa una clave de API.")
                }
                await composition.providers.clearCache()
                await refreshProviders()
                await composition.applyLLMSessionToSidecar()
            } catch {
                notice = ProviderErrorText.message(for: error, language: language)
            }
        }
    }

    func signOutChatGPT() {
        let auth = composition.auth
        Task {
            let confirmed = await auth.signOut()
            if !confirmed { notice = t("Signed out locally; remote revocation could not be confirmed. You can also disconnect Friday in ChatGPT settings.", "Sesión cerrada localmente; no se pudo confirmar la revocación remota. También puedes desconectar Friday en los ajustes de ChatGPT.") }
            chatGPT = nil
            await composition.providers.clearCache()
            await refreshProviders()
            await composition.applyLLMSessionToSidecar()
        }
    }

    func setOpenAIKey(_ key: String) {
        do {
            if key.isEmpty { try composition.secrets.removeSecret(for: OpenAIKeyProvider.keychainAccount) } else { try composition.secrets.set(key, for: OpenAIKeyProvider.keychainAccount) }
            Task { await composition.providers.clearCache(); await refreshProviders() }
        } catch {
            notice = "Keychain: \(error)"
        }
    }

    func setCompatibleKey(_ key: String) {
        let account = CompatibleProviderKeyAccount.account(for: intelligence.compatibleEndpoint)
        do {
            if key.isEmpty { try composition.secrets.removeSecret(for: account) } else { try composition.secrets.set(key, for: account) }
            Task { await composition.providers.clearCache(); await refreshProviders(); await composition.applyLLMSessionToSidecar() }
        } catch {
            notice = "Keychain: \(error)"
        }
    }

    // MARK: Sidecar / browser

    func startSidecar() { composition.startSidecar() }

    func stopSidecar() {
        guard let sidecar = composition.sidecar else { return }
        composition.web.setClient(nil)
        Task { await sidecar.stop(); await composition.router.setClient(nil) }
    }

    func refreshWebStatus() async {
        webStatus = await composition.web.agentStatus()
    }

    /// Runs the `web.connect` tool directly (`managed`: Friday's own Chrome profile; `existing`: attach to the running
    /// Chrome). The Browser tab shows the outcome through the refreshed agent status; the chat keeps the full result.
    func connectChrome(mode: String = "managed") {
        Task {
            let response = await execute("web.connect", arguments: ["mode": .string(mode)])
            await refreshWebStatus()
            if !response.success { notice = response.message }
        }
    }

    // MARK: Memory

    /// Lists what Friday remembers, in the chat, through the `memory.list` tool.
    func showMemory() {
        Task { await execute("memory.list", arguments: ["limit": .int(100)]) }
    }

    /// Deletes every memory after a confirmation, directly in the store, and reports what was removed. Returns false
    /// when the person cancelled.
    @discardableResult
    func forgetAllMemory() async -> Bool {
        guard let store = composition.memoryStore else { return false }
        let alert = NSAlert()
        alert.messageText = t("Forget everything Friday remembers?", "¿Olvidar todo lo que Friday recuerda?")
        alert.informativeText = t("Preferences, entities, knowledge and routines are deleted. Conversation history is kept; clear it separately. This cannot be undone.",
                                  "Se borran preferencias, entidades, conocimientos y rutinas. El historial de conversaciones se conserva; bórralo aparte. No se puede deshacer.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: t("Forget everything", "Olvidar todo"))
        alert.addButton(withTitle: t("Cancel", "Cancelar"))
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        do {
            let removed = try await store.forgetAll()
            let left = try await store.count()
            guard left == 0 else {
                notice = t("Some memories could not be deleted (\(left) left).", "No se pudieron borrar algunas memorias (quedan \(left)).")
                return false
            }
            notice = t("Forgotten \(removed) memories.", "Olvidadas \(removed) memorias.")
            return true
        } catch {
            notice = t("Could not delete the memory: ", "No se pudo borrar la memoria: ") + error.localizedDescription
            return false
        }
    }

    // MARK: Voice engines

    func refreshVoiceEngines() async {
        ttsEngines = await composition.output.availableEngines()
        recognizers = await composition.listener.availableRecognizers()
        voices = await composition.output.voices(engineID: voice.ttsEngineID)
    }

    func previewVoice(language: Language) {
        let output = composition.output
        Task { await output.speak(language == .es ? "Hola, soy Friday. ¿En qué puedo ayudarte?" : "Hi, I'm Friday. How can I help?", language: language) }
    }

    // MARK: Integrations and permissions

    func refreshIntegrationStatuses() {
        let integrations = composition.integrations
        Task {
            var statuses: [IntegrationID: IntegrationStatus] = [:]
            for integration in integrations { statuses[integration.id] = await integration.status() }
            integrationStatuses = statuses
        }
    }

    func requestPermission(for integration: any AppIntegration) {
        Task {
            if let tool = integration.tools.first { _ = await integration.requestAuthorization(for: tool) }
            refreshIntegrationStatuses()
        }
    }

    func openSystemSettings(_ url: String) {
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }

    // MARK: Wake word helpers

    var wakeStatusText: String {
        switch wake.state {
        case .initializing: return t("Starting…", "Iniciando…")
        case .listening: return t("Listening for “\(voice.wakeWord)”", "Escuchando «\(voice.wakeWord)»")
        case .verifying, .wakeWordVerified: return t("Heard you…", "Te he oído…")
        case .activated, .commandSession: return t("Active", "Activo")
        case .paused(let reason):
            switch reason {
            case .userDisabled: return t("Wake word off", "Palabra de activación desactivada")
            case .systemSleep: return t("Paused (sleep)", "En pausa (reposo)")
            case .userSessionInactive: return t("Paused (other user)", "En pausa (otro usuario)")
            case .noInputDevice: return t("No microphone", "Sin micrófono")
            }
        case .error(let failure): return failure.message
        }
    }

    var microphoneAuthorized: Bool { wake.microphone == .authorized }

    /// Friday is in a voice interaction: from the wake word (or a press) until the session ends, including the
    /// follow-up window and the moments between phases. The HUD, the menu bar and the chat window show it as active.
    var voiceActive: Bool { assistant.inVoiceSession || assistant.phase.isBusy }

    func retryWakeWord() {
        let runtime = composition.wakeRuntime
        Task { await runtime.microphonePermissionMayHaveChanged(); await runtime.retry() }
    }

    func quit() { NSApp.terminate(nil) }
}
