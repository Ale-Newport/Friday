import AppKit
import FridayAssistant
import FridayComputer
import FridayCore
import FridayIntelligence
import FridaySpeech
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label(model.t("General", "General"), systemImage: "gearshape") }
            VoiceSettingsView().tabItem { Label(model.t("Voice", "Voz"), systemImage: "waveform") }
            IntelligenceSettingsView().tabItem { Label(model.t("Intelligence", "Inteligencia"), systemImage: "brain") }
            BrowserSettings().tabItem { Label(model.t("Browser", "Navegador"), systemImage: "globe") }
            IntegrationsSettings().tabItem { Label(model.t("Integrations", "Integraciones"), systemImage: "square.grid.2x2") }
            PermissionsSettings().tabItem { Label(model.t("Permissions", "Permisos"), systemImage: "lock.shield") }
            PrivacySettings().tabItem { Label(model.t("Privacy & Memory", "Privacidad y memoria"), systemImage: "hand.raised") }
        }
        .frame(width: 640, height: 560)
        .alert("Friday", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) { Button("OK") { model.notice = nil } } message: { Text(model.notice ?? "") }
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var recording = false
    var body: some View {
        Form {
            Section(model.t("Activation", "Activación")) {
                Toggle(model.t("Listen for “\(model.voice.wakeWord)”", "Escuchar «\(model.voice.wakeWord)»"), isOn: Binding(get: { model.voice.wakeWordEnabled }, set: { model.setWakeWordEnabled($0) }))
                TextField(model.t("Wake word (requires a matching detector model; “Jarvis” is built in)", "Palabra de activación (requiere un modelo; «Jarvis» viene incluido)"), text: model.voiceBinding(\.wakeWord))
                HStack {
                    Text(model.t("Keyboard shortcut", "Atajo de teclado"))
                    Spacer()
                    HotKeyRecorder(combo: model.hotkey, recording: $recording) { model.setHotkey($0) }
                    Toggle("", isOn: Binding(get: { model.hotkeyEnabled }, set: { model.setHotkeyEnabled($0) })).labelsHidden()
                }
                if let error = model.hotkeyError { Text(error).font(.caption).foregroundStyle(.red) }
                Toggle(model.t("Open at login", "Abrir al iniciar sesión"), isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            }
            Section(model.t("Language", "Idioma")) {
                Picker(model.t("Reply language", "Idioma de respuesta"), selection: model.engineBinding(\.languagePreference)) {
                    Text(model.t("Automatic (match what I say)", "Automático (según lo que diga)")).tag(LanguagePreference.automatic)
                    Text("English").tag(LanguagePreference.english)
                    Text("Español").tag(LanguagePreference.spanish)
                }
            }
            Section(model.t("Wake-word detection", "Detección de la palabra")) {
                HStack {
                    Text(model.t("Sensitivity", "Sensibilidad"))
                    Slider(value: Binding(get: { Double(model.wakeSettings.sensitivity) }, set: { value in model.updateWake { s in s.sensitivity = Float(value) } }), in: 0...1)
                }
                Text(model.t("Raise it for accents or distance; lower it if TV or conversation triggers Friday. Spanish speech can trigger the free detector (“ya había”); mid sensitivity is the measured sweet spot.", "Súbela para acentos o distancia; bájala si la tele o una conversación activan a Friday. El habla en español puede activar el detector gratuito («ya había»); el punto medio es el óptimo medido."))
                    .font(.caption).foregroundStyle(.secondary)
                Text(model.wakeStatusText).font(.caption)
                if case .error = model.wake.state { Button(model.t("Retry", "Reintentar")) { model.retryWakeWord() } }
            }
            Section(model.t("Local control channel", "Canal de control local")) {
                Toggle(model.t("Allow `fridayctl` and other local programs to send commands", "Permitir que `fridayctl` y otros programas locales envíen comandos"), isOn: model.engineBinding(\.ipcEnabled))
            }
        }
        .formStyle(.grouped)
    }
}

struct HotKeyRecorder: View {
    var combo: HotKeyCombo
    @Binding var recording: Bool
    var onChange: (HotKeyCombo) -> Void
    @State private var monitor: Any?

    var body: some View {
        Button(recording ? "…" : combo.display) {
            recording.toggle()
            if recording {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    if let new = HotKeyCombo.from(event: event) { onChange(new) }
                    recording = false
                    if let monitor { NSEvent.removeMonitor(monitor) }
                    monitor = nil
                    return nil
                }
            } else if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
        .buttonStyle(.bordered).frame(minWidth: 90)
    }
}

struct VoiceSettingsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Form {
            Section(model.t("Listening", "Escucha")) {
                Picker(model.t("Speech recognition", "Reconocimiento de voz"), selection: model.voiceBinding(\.recognizerID)) {
                    ForEach(model.recognizers, id: \.id) { engine in Text(engine.name + (engine.availability.isAvailable ? "" : " (unavailable)")).tag(engine.id) }
                }
                Picker(model.t("Spoken language", "Idioma hablado"), selection: model.voiceBinding(\.spokenLanguage)) {
                    Text(model.t("Spanish and English (automatic)", "Español e inglés (automático)")).tag(LanguagePreference.automatic)
                    Text("English").tag(LanguagePreference.english)
                    Text("Español").tag(LanguagePreference.spanish)
                }
                Toggle(model.t("Keep listening for follow-ups after answering", "Seguir escuchando tras responder"), isOn: model.voiceBinding(\.conversationMode))
                HStack { Text(model.t("Follow-up window", "Ventana para continuar")); Slider(value: model.voiceBinding(\.conversationTimeoutSeconds), in: 2...30, step: 1); Text("\(Int(model.voice.conversationTimeoutSeconds)) s").monospacedDigit() }
                HStack { Text(model.t("End of sentence after", "Fin de frase tras")); Slider(value: model.voiceBinding(\.endpointSilenceSeconds), in: 0.4...2, step: 0.1); Text(String(format: "%.1f s", model.voice.endpointSilenceSeconds)).monospacedDigit() }
                Picker(model.t("When activated", "Al activarse"), selection: model.voiceBinding(\.acknowledgementStyle)) {
                    Text(model.t("Chime", "Tono")).tag(VoiceSettings.Acknowledgement.chime)
                    Text(model.t("Say “Yes?”", "Decir «¿Sí?»")).tag(VoiceSettings.Acknowledgement.spoken)
                    Text(model.t("Silent", "Silencio")).tag(VoiceSettings.Acknowledgement.silent)
                }
                Toggle(model.t("Let me interrupt Friday while it speaks", "Permitirme interrumpir a Friday mientras habla"), isOn: model.voiceBinding(\.bargeInEnabled))
            }
            Section(model.t("Speaking", "Habla")) {
                Toggle(model.t("Speak answers to voice requests", "Responder en voz alta a las peticiones por voz"), isOn: model.voiceBinding(\.speakResponses))
                Toggle(model.t("Also speak answers to typed requests", "Responder en voz alta también a lo escrito"), isOn: model.voiceBinding(\.speakTypedResponses))
                Picker(model.t("Voice engine", "Motor de voz"), selection: model.voiceBinding(\.ttsEngineID)) {
                    ForEach(model.ttsEngines, id: \.id) { engine in Text(engine.name + (engine.availability.isAvailable ? "" : " — " + describe(engine.availability))).tag(engine.id) }
                }
                .onChange(of: model.voice.ttsEngineID) { _, _ in Task { await model.refreshVoiceEngines() } }
                Picker(model.t("English voice", "Voz en inglés"), selection: Binding(get: { model.voice.englishVoiceID ?? "" }, set: { value in model.updateVoice { s in s.englishVoiceID = value.isEmpty ? nil : value } })) {
                    Text(model.t("Default", "Por defecto")).tag("")
                    ForEach(model.voices.filter { $0.baseLanguage == .en }) { Text($0.name).tag($0.id) }
                }
                Picker(model.t("Spanish voice", "Voz en español"), selection: Binding(get: { model.voice.spanishVoiceID ?? "" }, set: { value in model.updateVoice { s in s.spanishVoiceID = value.isEmpty ? nil : value } })) {
                    Text(model.t("Default", "Por defecto")).tag("")
                    ForEach(model.voices.filter { $0.baseLanguage == .es }) { Text($0.name).tag($0.id) }
                }
                HStack { Text(model.t("Rate", "Velocidad")); Slider(value: Binding(get: { Double(model.voice.speakingRate) }, set: { value in model.updateVoice { s in s.speakingRate = Float(value) } }), in: 0.6...1.6, step: 0.05) }
                HStack { Text(model.t("Volume", "Volumen")); Slider(value: Binding(get: { Double(model.voice.speakingVolume) }, set: { value in model.updateVoice { s in s.speakingVolume = Float(value) } }), in: 0...1) }
                HStack {
                    Button(model.t("Preview English", "Probar inglés")) { model.previewVoice(language: .en) }
                    Button(model.t("Preview Spanish", "Probar español")) { model.previewVoice(language: .es) }
                }
            }
            Section(model.t("Vocabulary", "Vocabulario")) {
                TextField(model.t("Names, apps and words to recognise better (comma-separated)", "Nombres, apps y palabras a reconocer mejor (separadas por comas)"), text: Binding(get: { model.voice.customVocabulary.joined(separator: ", ") }, set: { text in model.updateVoice { $0.customVocabulary = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } } }))
            }
        }
        .formStyle(.grouped)
        .task { await model.refreshVoiceEngines() }
    }

    func describe(_ availability: FridaySpeech.EngineAvailability) -> String {
        switch availability {
        case .available: return ""
        case .needsSetup(let m), .unavailable(let m): return m
        }
    }
}

struct IntelligenceSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var apiKey = ""
    @State private var compatibleKey = ""
    var body: some View {
        Form {
            Section("ChatGPT") {
                if let account = model.chatGPT {
                    LabeledContent(model.t("Signed in as", "Sesión iniciada como"), value: account.email ?? account.subject)
                    LabeledContent(model.t("Plan usage", "Uso del plan"), value: account.planUsageGranted ? model.t("Granted", "Concedido") : model.t("Not granted", "No concedido"))
                    HStack {
                        Button(model.t("Sign out", "Cerrar sesión")) { model.signOutChatGPT() }
                        Button(model.t("Refresh models", "Actualizar modelos")) { Task { await model.refreshModels("chatgpt") } }
                    }
                } else {
                    Text(model.t("Use your ChatGPT plan through the official “Sign in with ChatGPT” flow. Your browser opens; Friday receives a token and stores it in the Keychain. Your ChatGPT conversations are not shared.", "Usa tu plan de ChatGPT con el flujo oficial «Iniciar sesión con ChatGPT». Se abre el navegador; Friday recibe un token y lo guarda en el llavero. Tus conversaciones de ChatGPT no se comparten."))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(model.signInInProgress ? model.t("Waiting for the browser…", "Esperando al navegador…") : model.t("Continue with ChatGPT", "Continuar con ChatGPT")) { model.signInWithChatGPT() }.disabled(model.signInInProgress).buttonStyle(.borderedProminent)
                }
                Toggle(model.t("Use ChatGPT when available", "Usar ChatGPT cuando esté disponible"), isOn: model.intelligenceBinding(\.chatGPTEnabled))
                modelPicker(provider: "chatgpt", title: model.t("Model for planning", "Modelo para planificar"), binding: model.intelligenceBinding(\.chatGPTModel))
                modelPicker(provider: "chatgpt", title: model.t("Fast model", "Modelo rápido"), binding: model.intelligenceBinding(\.chatGPTFastModel))
            }
            Section(model.t("OpenAI API key (metered)", "Clave de API de OpenAI (de pago)")) {
                Toggle(model.t("Use an API key", "Usar una clave de API"), isOn: model.intelligenceBinding(\.openAIKeyEnabled))
                SecureField(model.t("sk-… (stored in the Keychain)", "sk-… (se guarda en el llavero)"), text: $apiKey).onSubmit { model.setOpenAIKey(apiKey); apiKey = "" }
                HStack {
                    Button(model.t("Save key", "Guardar clave")) { model.setOpenAIKey(apiKey); apiKey = "" }.disabled(apiKey.isEmpty)
                    Button(model.t("Remove key", "Quitar clave")) { model.setOpenAIKey("") }
                    Button(model.t("Refresh models", "Actualizar modelos")) { Task { await model.refreshModels("openai") } }
                }
                modelPicker(provider: "openai", title: model.t("Model", "Modelo"), binding: model.intelligenceBinding(\.openAIModel))
                Toggle(model.t("Allow falling back to a paid provider when the free ones fail", "Permitir recurrir a un proveedor de pago si fallan los gratuitos"), isOn: model.intelligenceBinding(\.allowPaidFallback))
            }
            Section(model.t("Local or compatible server (Ollama, LM Studio…)", "Servidor local o compatible (Ollama, LM Studio…)")) {
                Toggle(model.t("Use a compatible server", "Usar un servidor compatible"), isOn: model.intelligenceBinding(\.compatibleEnabled))
                TextField(model.t("Endpoint", "Dirección"), text: model.intelligenceBinding(\.compatibleEndpoint))
                HStack {
                    TextField(model.t("Model name", "Nombre del modelo"), text: model.intelligenceBinding(\.compatibleModel))
                    Button(model.t("Detect", "Detectar")) { Task { await model.refreshModels("compatible") } }
                }
                modelPicker(provider: "compatible", title: model.t("Detected models", "Modelos detectados"), binding: Binding(get: { model.intelligence.compatibleModel.isEmpty ? nil : model.intelligence.compatibleModel }, set: { value in model.updateIntelligence { s in s.compatibleModel = value ?? "" } }))
                SecureField(model.t("API key (optional)", "Clave de API (opcional)"), text: $compatibleKey).onSubmit { model.setCompatibleKey(compatibleKey); compatibleKey = "" }
                Toggle(model.t("Server supports function calling", "El servidor admite llamadas a funciones"), isOn: model.intelligenceBinding(\.compatibleSupportsTools))
            }
            Section(model.t("Apple on-device model", "Modelo de Apple en el dispositivo")) {
                Toggle(model.t("Use Apple's on-device model as the free offline fallback", "Usar el modelo de Apple en el dispositivo como respaldo gratuito sin conexión"), isOn: model.intelligenceBinding(\.appleOnDeviceEnabled))
                if let status = model.providers.first(where: { $0.id == "apple" }) { Text(status.detail).font(.caption).foregroundStyle(.secondary) }
            }
            Section(model.t("Routing", "Enrutado")) {
                Toggle(model.t("Fast path for obvious commands (no model call)", "Vía rápida para comandos obvios (sin modelo)"), isOn: model.intelligenceBinding(\.fastPathEnabled))
                Toggle(model.t("Laya intent routing through the sidecar", "Enrutado de intención con Laya en el proceso auxiliar"), isOn: model.intelligenceBinding(\.layaRoutingEnabled))
                Toggle(model.t("Share screen context (frontmost app, selection) with the model when relevant", "Compartir el contexto de pantalla (app activa, selección) con el modelo cuando sea relevante"), isOn: model.intelligenceBinding(\.shareScreenContext))
                Stepper(model.t("Max tool rounds per request: \(model.intelligence.maxToolRounds)", "Máx. de rondas de herramientas por petición: \(model.intelligence.maxToolRounds)"), value: model.intelligenceBinding(\.maxToolRounds), in: 1...24)
            }
            Section(model.t("Provider status", "Estado de proveedores")) {
                ForEach(model.providers) { status in
                    HStack {
                        Image(systemName: status.enabled && status.configured ? "checkmark.circle.fill" : "circle").foregroundStyle(status.enabled && status.configured ? .green : .secondary)
                        VStack(alignment: .leading) {
                            Text(status.displayName)
                            Text(status.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let selected = status.selectedModel { Text(selected).font(.caption).monospaced() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await model.refreshProviders() }
    }

    @ViewBuilder
    func modelPicker(provider: String, title: String, binding: Binding<String?>) -> some View {
        let models = model.providers.first(where: { $0.id == provider })?.models ?? []
        Picker(title, selection: Binding(get: { binding.wrappedValue ?? "" }, set: { binding.wrappedValue = $0.isEmpty ? nil : $0 })) {
            Text(model.t("Automatic", "Automático")).tag("")
            ForEach(models) { Text($0.displayName).tag($0.id) }
        }
    }
}

struct BrowserSettings: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Form {
            Section(model.t("Browser agent", "Agente de navegación")) {
                LabeledContent(model.t("Sidecar", "Proceso auxiliar"), value: sidecarText)
                HStack {
                    Button(model.t("Start", "Iniciar")) { model.startSidecar() }
                    Button(model.t("Stop", "Detener")) { model.stopSidecar() }
                    Button(model.t("Refresh", "Actualizar")) { Task { await model.refreshWebStatus() } }
                }
                if let status = model.webStatus {
                    LabeledContent("Chrome", value: "\(status.chromeState) (\(status.chromeMode))" + (status.chromeInstalled ? "" : model.t(" — not installed", " — no instalado")))
                    LabeledContent("Laya", value: status.layaState)
                    LabeledContent(model.t("Planning model", "Modelo de planificación"), value: status.llmModel.isEmpty ? "—" : status.llmModel + (status.llmReachable ? "" : " (unreachable)"))
                    if let error = status.error { Text(error).foregroundStyle(.red).font(.caption) }
                }
                Button(model.t("Connect Chrome (Friday profile)", "Conectar Chrome (perfil de Friday)")) { model.submit("web.connect") }
                Text(model.t("Friday drives Google Chrome through the DevTools Protocol with its own automation profile, so your normal windows stay untouched. Logins persist in that profile. Purchases, sends and deletions pause for your approval; CAPTCHAs and sign-ins are left to you.", "Friday maneja Google Chrome mediante el protocolo DevTools con su propio perfil de automatización; tus ventanas normales no se tocan. Las sesiones iniciadas se conservan en ese perfil. Compras, envíos y borrados esperan tu aprobación; los CAPTCHA e inicios de sesión te los deja a ti."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await model.refreshWebStatus() }
    }

    var sidecarText: String {
        switch model.sidecarState {
        case .stopped: return model.t("Stopped", "Detenido")
        case .starting: return model.t("Starting…", "Iniciando…")
        case .running(let endpoint): return model.t("Running (port \(endpoint.baseURL.port ?? 0), v\(endpoint.version))", "En marcha (puerto \(endpoint.baseURL.port ?? 0), v\(endpoint.version))")
        case .failed(let reason): return model.t("Failed: \(reason)", "Falló: \(reason)")
        }
    }
}

struct IntegrationsSettings: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        List {
            ForEach(model.composition.integrations, id: \.id) { integration in
                let status = model.integrationStatuses[integration.id]
                HStack {
                    Image(systemName: integration.symbolName).frame(width: 22)
                    VStack(alignment: .leading) {
                        Text(integration.displayName.resolved(model.language))
                        Text(status.map { stateText($0) } ?? "…").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(integration.tools.count) " + model.t("tools", "herramientas")).font(.caption).foregroundStyle(.tertiary)
                    if let status, status.state == .needsPermission || status.state == .denied {
                        Button(model.t("Allow…", "Permitir…")) { model.requestPermission(for: integration) }
                    }
                }
            }
        }
        .task { model.refreshIntegrationStatuses() }
    }

    func stateText(_ status: IntegrationStatus) -> String {
        let detail = status.detail?.resolved(model.language)
        switch status.state {
        case .ready: return model.t("Ready", "Listo")
        case .needsPermission: return model.t("Needs permission", "Necesita permiso")
        case .denied: return model.t("Permission denied", "Permiso denegado")
        case .restricted: return model.t("Restricted", "Restringido")
        case .needsSetup: return detail ?? model.t("Needs setup", "Necesita configuración")
        case .unavailable: return detail ?? model.t("Unavailable", "No disponible")
        }
    }
}

struct PermissionsSettings: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Form {
            Section(model.t("macOS permissions", "Permisos de macOS")) {
                permissionRow(model.t("Microphone", "Micrófono"), granted: model.microphoneAuthorized, why: model.t("Wake word and voice commands.", "Palabra de activación y comandos de voz."), url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
                permissionRow(model.t("Speech recognition", "Reconocimiento de voz"), granted: nil, why: model.t("On-device transcription of what you say.", "Transcripción en el dispositivo de lo que dices."), url: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
                permissionRow(model.t("Accessibility", "Accesibilidad"), granted: ComputerPermissions.accessibilityStatus() == .granted, why: model.t("Reading on-screen elements, clicking, typing and arranging windows on request.", "Leer elementos en pantalla, pulsar, escribir y organizar ventanas cuando lo pidas."), url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility", request: { ComputerPermissions.requestAccessibility() })
                permissionRow(model.t("Screen Recording", "Grabación de pantalla"), granted: ComputerPermissions.screenRecordingStatus() == .granted, why: model.t("Screenshots only when you ask about your screen.", "Capturas solo cuando preguntas por tu pantalla."), url: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture", request: { ComputerPermissions.requestScreenRecording() })
                permissionRow(model.t("Automation (Apple Events)", "Automatización (Apple Events)"), granted: nil, why: model.t("Music, Notes, Mail, Messages, browsers, System Events. Each app is asked once.", "Música, Notas, Mail, Mensajes, navegadores, System Events. Cada app se pide una vez."), url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
                permissionRow(model.t("Reminders, Calendar, Contacts", "Recordatorios, Calendario, Contactos"), granted: nil, why: model.t("Asked the first time a request needs them (see Integrations).", "Se piden la primera vez que una petición los necesita (ver Integraciones)."), url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")
            }
            Section {
                Text(model.t("Friday asks for each permission only when a request needs it and explains why first. You can revoke any of them in System Settings; Friday keeps working with whatever you allow.", "Friday pide cada permiso solo cuando una petición lo necesita y explica antes por qué. Puedes revocarlos en Ajustes del Sistema; Friday sigue funcionando con lo que permitas.")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    func permissionRow(_ title: String, granted: Bool?, why: String, url: String, request: (() -> Void)? = nil) -> some View {
        HStack {
            Image(systemName: granted == true ? "checkmark.circle.fill" : (granted == false ? "xmark.circle" : "questionmark.circle")).foregroundStyle(granted == true ? .green : .secondary)
            VStack(alignment: .leading) { Text(title); Text(why).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            if let request, granted != true { Button(model.t("Request", "Solicitar")) { request() } }
            Button(model.t("Open Settings", "Abrir Ajustes")) { model.openSystemSettings(url) }
        }
    }
}

struct PrivacySettings: View {
    @Environment(AppModel.self) private var model
    @State private var memoryEnabled = true
    @State private var memoryCounts: [String: Int] = [:]
    var body: some View {
        Form {
            Section(model.t("Memory", "Memoria")) {
                Toggle(model.t("Remember preferences, entities and knowledge I tell Friday", "Recordar preferencias, entidades y datos que le cuente a Friday"), isOn: $memoryEnabled)
                    .onChange(of: memoryEnabled) { _, value in Task { try? await model.composition.memoryStore?.setEnabled(value); await refresh() } }
                ForEach(memoryCounts.sorted(by: { $0.key < $1.key }), id: \.key) { kind, count in LabeledContent(kind, value: "\(count)") }
                HStack {
                    Button(model.t("Show memory…", "Ver memoria…")) { model.submit("memory.list") }
                    Button(model.t("Export…", "Exportar…")) { exportMemory() }
                    Button(model.t("Forget everything", "Olvidar todo")) { model.submit(model.t("forget all my memory", "olvida toda mi memoria")) }
                }
            }
            Section(model.t("Conversation", "Conversación")) {
                Toggle(model.t("Keep context between requests", "Mantener el contexto entre peticiones"), isOn: model.engineBinding(\.rememberSession))
                Toggle(model.t("Save command history", "Guardar el historial de comandos"), isOn: model.engineBinding(\.saveHistory))
                Toggle(model.t("Save full conversations in history", "Guardar conversaciones completas"), isOn: model.engineBinding(\.saveConversations))
                Button(model.t("Clear conversation history", "Borrar el historial de conversaciones")) { Task { _ = try? await model.composition.memoryStore?.clearAllConversations(); await model.composition.history.clear() } }
            }
            Section(model.t("What leaves this Mac", "Qué sale de este Mac")) {
                Text(model.t("Wake-word detection, speech recognition (Apple), voice synthesis (Kokoro/Apple), intent routing (Laya) and all Apple-app actions run locally. Only the text of your requests, relevant tool results and page text the browser agent reads go to the language model you connected (ChatGPT, OpenAI, or none when you use a local model).", "La detección de la palabra, el reconocimiento de voz (Apple), la síntesis (Kokoro/Apple), el enrutado (Laya) y todas las acciones en apps de Apple se ejecutan en local. Solo el texto de tus peticiones, los resultados relevantes de herramientas y el texto de páginas que lee el agente de navegación van al modelo que conectes (ChatGPT, OpenAI, o ninguno con un modelo local)."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await refresh() }
    }

    func refresh() async {
        guard let store = model.composition.memoryStore else { return }
        memoryEnabled = await store.isEnabled
        var counts: [String: Int] = [:]
        for kind in ["preference", "entity", "knowledge", "workflow"] { counts[kind] = (try? await store.count(kind: .init(rawValue: kind)!)) ?? 0 }
        memoryCounts = counts
    }

    func exportMemory() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "friday-memory.json"
        guard panel.runModal() == .OK, let url = panel.url, let store = model.composition.memoryStore else { return }
        Task { if let data = try? await store.export() { try? data.write(to: url) } }
    }
}
