import AppKit
import Foundation
import FridayAssistant
import FridayBrowser
import FridayComputer
import FridayCore
import FridayIntelligence
import FridaySidecar
import FridaySpeech
import Observation
import SwiftUI
import WakeWordCore
import WakeWordKit

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
    var notice: String?
    var signInInProgress = false
    private(set) var latencyHistory: [LatencyReport] = []

    private var started = false
    private var tasks: [Task<Void, Never>] = []
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
        let loadedWake = composition.wakeSettingsStore.load(defaultEngineID: composition.wakeRegistry.defaultEngineID ?? "")
        wakeSettings = loadedWake
        wake = .initial(settings: loadedWake, microphone: composition.permission.status())
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
    }

    private func receive(_ snapshot: AssistantSnapshot) {
        let previous = assistant
        assistant = snapshot
        if let latency = snapshot.lastLatency, latency != previous.lastLatency {
            latencyHistory.append(latency)
            if latencyHistory.count > 50 { latencyHistory.removeFirst() }
        }
        hud?.update(for: snapshot)
    }

    func shutdownImmediately() {
        tasks.forEach { $0.cancel() }
        hud?.hideImmediately()
        composition.shutdownImmediately()
    }

    // MARK: Commands

    func submit(_ raw: String? = nil) {
        let text = (raw ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if raw == nil { input = "" }
        let assistant = composition.assistant
        Task { await assistant.submit(text, source: .app, session: "chat") }
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
            guard let token = prompt.token else { return }
            Task { await assistant.resolve(token: token, decision: approve == true ? .confirm : .cancel, label: approve == true ? t("Confirm", "Confirmar") : t("Cancel", "Cancelar")) }
        case .clarification:
            guard let token = prompt.token else { return }
            if let index { Task { await assistant.resolve(token: token, decision: .choose(index), label: prompt.options[index]) } } else { Task { await assistant.resolve(token: token, decision: .cancel, label: t("Cancel", "Cancelar")) } }
        }
    }

    /// Hotkey / menu: start listening right now, as if the wake word had been heard.
    func activateByKeyboard() {
        let runtime = composition.wakeRuntime
        Task { await runtime.simulateWakeWord() }
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

    func updateIntelligence(_ change: (inout IntelligenceSettings) -> Void) {
        intelligence = composition.fridaySettings.updateIntelligence(change)
        Task { await composition.providers.clearCache(); await refreshProviders(); await composition.applyLLMSessionToSidecar() }
    }

    func intelligenceBinding<Value>(_ keyPath: WritableKeyPath<IntelligenceSettings, Value>) -> Binding<Value> {
        Binding(get: { self.intelligence[keyPath: keyPath] }, set: { value in self.updateIntelligence { $0[keyPath: keyPath] = value } })
    }

    func updateEngineSettings(_ change: (inout JarvisSettings) -> Void) {
        var copy = engineSettings
        change(&copy)
        engineSettings = copy.sanitized()
        composition.engineSettings.save(engineSettings)
        composition.ipc.apply(enabled: engineSettings.ipcEnabled)
    }

    func engineBinding<Value>(_ keyPath: WritableKeyPath<JarvisSettings, Value>) -> Binding<Value> {
        Binding(get: { self.engineSettings[keyPath: keyPath] }, set: { value in self.updateEngineSettings { $0[keyPath: keyPath] = value } })
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

    func connectChrome(mode: String) {
        let assistant = composition.assistant
        Task { await assistant.submit("web.connect", source: .app, session: "chat", speak: false) }
        _ = mode
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

    func retryWakeWord() {
        let runtime = composition.wakeRuntime
        Task { await runtime.microphonePermissionMayHaveChanged(); await runtime.retry() }
    }

    func quit() { NSApp.terminate(nil) }
}
