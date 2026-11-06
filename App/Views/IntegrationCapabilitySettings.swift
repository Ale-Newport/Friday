import AppKit
import Combine
import FridayCore
import FridayIntegrations
import ServiceManagement
import SwiftUI

// Settings ▸ Integrations: everything a tool needs set up before it can work, ported from Apple-Integrations'
// IntegrationSettingsView, CapabilitySettingsView and ClockSetupView. Every value is stored in the engine settings
// (`AppModel.engineSettings`, UserDefaults key `ConditionService.settingsKey`), the same snapshot the tools read, so a
// change here is what `files.*`, `workflows.*`, `research.*`, `weather.*`, `clock.*` and `conditions.*` see next.

/// Text field that saves when the user presses Return or leaves the field, so half-typed values (and spaces) are
/// never trimmed or applied while typing.
struct CommitTextField: View {
    let title: String
    let value: String
    let commit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $draft)
            .focused($focused)
            .onSubmit { commit(draft) }
            .onChange(of: focused) { _, isFocused in if !isFocused { commit(draft) } }
            .onChange(of: value) { _, new in if !focused { draft = new } }
            .onAppear { draft = value }
            .onDisappear { commit(draft) }
    }
}

/// Names the user can pick from in the Settings pickers (reminder lists, calendars, Notes folders), read through the
/// engine so the same permission checks apply as for commands. Never recorded in the history.
@MainActor
@Observable
final class IntegrationChoices {
    enum Kind: Hashable { case reminderLists, calendars, noteFolders }

    struct Choice: Hashable, Identifiable {
        var name: String
        /// Account name (Notes accounts, Reminders sources, Calendar sources).
        var group: String
        var id: String { group + "\u{1F}" + name }
    }

    struct ChoiceSet: Equatable {
        var items: [Choice] = []
        var isLoading = false
        var isLoaded = false
        /// Why the list is empty (usually: permission not granted yet).
        var problem: String?
    }

    private(set) var sets: [Kind: ChoiceSet] = [:]

    func set(_ kind: Kind) -> ChoiceSet { sets[kind] ?? ChoiceSet() }

    /// The system permission prompt only appears when `allowPrompt` is true (the user pressed a button for it);
    /// otherwise a missing permission is reported in `ChoiceSet.problem`.
    func load(_ kind: Kind, using model: AppModel, force: Bool = false, allowPrompt: Bool = false) {
        let current = set(kind)
        if current.isLoading || (current.isLoaded && !force) { return }
        sets[kind, default: ChoiceSet()].isLoading = true
        let tool: ToolName
        let key: String
        switch kind {
        case .reminderLists: (tool, key) = (.remindersListLists, "lists")
        case .calendars: (tool, key) = (.calendarListCalendars, "calendars")
        case .noteFolders: (tool, key) = (.notesListFolders, "folders")
        }
        let engine = model.composition.engine
        let registry = model.composition.registry
        let language = model.language
        Task {
            var result = ChoiceSet(isLoaded: true)
            if let descriptor = registry.descriptor(for: tool), let integration = registry.integration(for: tool) {
                var state = await integration.authorization(for: descriptor)
                if allowPrompt, case .notDetermined = state {
                    state = await integration.requestAuthorization(for: descriptor)
                }
                if !state.isAuthorized {
                    switch state {
                    case .denied, .restricted:
                        result.problem = language.pick(
                            "Access is off. Change it in System Settings ▸ Privacy & Security.",
                            "El acceso está desactivado. Cámbialo en Ajustes del Sistema ▸ Privacidad y seguridad.")
                    case .unavailable(let reason):
                        result.problem = reason.resolved(language)
                    default:
                        result.problem = language.pick(
                            "Allow access first (Permissions tab).", "Concede primero el acceso (pestaña Permisos).")
                    }
                    sets[kind] = result
                    model.refreshIntegrationStatuses()
                    return
                }
            }
            let response = await engine.execute(
                ToolCall(tool: tool), language: language, source: .app, session: "settings", recordHistory: false)
            if let first = response.results.first, first.status == .completed {
                for entry in first.data?[key]?.arrayValue ?? [] {
                    guard let name = entry["name"]?.stringValue else { continue }
                    // Calendars the user cannot write to are not useful as a default.
                    if kind == .calendars, entry["writable"]?.boolValue == false { continue }
                    result.items.append(Choice(name: name, group: entry["account"]?.stringValue ?? ""))
                }
            } else {
                result.problem = response.results.first?.message ?? response.message
            }
            sets[kind] = result
        }
    }
}

/// The sections of Settings ▸ Integrations below the status list. Placed inside the tab's `Form`.
struct IntegrationCapabilitySections: View {
    @Environment(AppModel.self) private var model
    @State private var choices = IntegrationChoices()
    @State private var workflows: [String] = []
    @State private var loadingWorkflows = false
    @State private var workflowFeedback: String?
    @State private var agentStatus: SMAppService.Status = .notRegistered
    @State private var agentRun: ConditionService.AgentStatus?
    @State private var agentFeedback: String?

    var body: some View {
        Group {
            filesSection
            workflowsSection
            searchSection
            weatherSection
            clockSection
            conditionsSection
        }
        Group {
            musicSection
            remindersSection
            calendarSection
            notesSection
            contactsSection
            timesOfDaySection
            communicationSection
        }
    }

    // MARK: Files

    private var filesSection: some View {
        Section {
            ForEach(model.engineSettings.capabilities.fileRoots, id: \.self) { path in
                HStack {
                    Text(path).font(.caption).textSelection(.enabled)
                    Spacer()
                    Button(role: .destructive) {
                        model.updateEngineSettings { $0.capabilities.fileRoots.removeAll { $0 == path } }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless).help(model.t("Remove access", "Retirar acceso"))
                }
            }
            Button(model.t("Choose an allowed folder…", "Elegir una carpeta permitida…")) { chooseFolder() }
            caption(
                model.t(
                    "Files tools can read and modify only these folders (none are allowed until you add one). Changes never overwrite an existing file. Trash and bulk operations ask for confirmation.",
                    "Las herramientas de archivos solo pueden leer y modificar estas carpetas (ninguna está permitida hasta que añadas una). Nunca sobrescriben un archivo existente. La Papelera y los cambios masivos requieren confirmación."
                ))
        } header: {
            Label(model.t("Files and Finder", "Archivos y Finder"), systemImage: "folder")
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = model.t("Allow folder", "Permitir carpeta")
        guard panel.runModal() == .OK else { return }
        let paths = panel.urls.map(\.path).filter { $0 != "/" }
        model.updateEngineSettings { $0.capabilities.fileRoots += paths }
        model.refreshIntegrationStatuses()
    }

    // MARK: Workflows (Shortcuts)

    private var workflowsSection: some View {
        Section {
            Button(
                loadingWorkflows
                    ? model.t("Loading…", "Cargando…") : model.t("Load installed Shortcuts", "Cargar Atajos instalados")
            ) { loadWorkflows() }.disabled(loadingWorkflows)
            ForEach(Array(Set(workflows + model.engineSettings.capabilities.approvedWorkflows)).sorted(), id: \.self) {
                name in
                Toggle(
                    name,
                    isOn: Binding(
                        get: { model.engineSettings.capabilities.approvedWorkflows.contains(name) },
                        set: { allowed in
                            model.updateEngineSettings { settings in
                                settings.capabilities.approvedWorkflows.removeAll { $0 == name }
                                if allowed { settings.capabilities.approvedWorkflows.append(name) }
                            }
                        }))
            }
            CommitTextField(
                title: model.t("Focus Shortcut", "Atajo para Concentración"),
                value: model.engineSettings.capabilities.focusShortcut
            ) { name in
                let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty, clean != model.engineSettings.capabilities.focusShortcut else { return }
                model.updateEngineSettings { $0.capabilities.focusShortcut = clean }
            }
            caption(
                model.t(
                    "Approve only Shortcuts you trust: Friday can run approved ones by name (workflows.run) and shows the input before each execution. Focus input is JSON with enabled, mode and until; that Shortcut must implement the requested end time.",
                    "Aprueba solo Atajos de confianza: Friday puede ejecutar los aprobados por su nombre (workflows.run) y muestra la entrada antes de cada ejecución. Concentración recibe JSON con enabled, mode y until; ese Atajo debe aplicar la hora de finalización."
                ))
            if let workflowFeedback { Text(workflowFeedback).font(.caption).foregroundStyle(.secondary) }
        } header: {
            Label(
                model.t("Workflows and third-party apps", "Flujos y apps de terceros"),
                systemImage: "point.3.connected.trianglepath.dotted")
        }
    }

    private func loadWorkflows() {
        loadingWorkflows = true
        Task {
            defer { loadingWorkflows = false }
            do {
                workflows = Array(try await ShortcutsCLIRunner().installedShortcutNames()).sorted()
                workflowFeedback =
                    workflows.isEmpty ? model.t("No Shortcuts are installed.", "No hay Atajos instalados.") : nil
            } catch {
                workflowFeedback =
                    model.t("Could not list Shortcuts: ", "No se pudieron listar los Atajos: ") + describe(error)
            }
        }
    }

    // MARK: Web search

    private var searchEndpointIsUsable: Bool {
        let endpoint = model.engineSettings.capabilities.searchEndpoint
        guard let url = URLComponents(string: endpoint), let host = url.host?.lowercased(), !host.isEmpty,
            url.user == nil, url.password == nil, url.fragment == nil, url.query == nil
        else { return false }
        return url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host))
    }

    private var searchSection: some View {
        Section {
            CommitTextField(
                title: model.t("SearXNG search URL (…/search)", "URL de búsqueda SearXNG (…/search)"),
                value: model.engineSettings.capabilities.searchEndpoint
            ) { endpoint in
                let clean = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
                guard clean != model.engineSettings.capabilities.searchEndpoint else { return }
                model.updateEngineSettings { $0.capabilities.searchEndpoint = clean }
            }
            if !model.engineSettings.capabilities.searchEndpoint.isEmpty, !searchEndpointIsUsable {
                Label(
                    model.t(
                        "This URL will be refused: use HTTPS (or HTTP on localhost) without credentials, query or fragment.",
                        "Esta URL se rechazará: usa HTTPS (o HTTP en localhost) sin credenciales, consulta ni fragmento."),
                    systemImage: "exclamationmark.triangle"
                ).font(.caption).foregroundStyle(.orange)
            }
            caption(
                model.t(
                    "Optional. A trusted SearXNG /search endpoint with the JSON format enabled gives Friday the research.search tool: queries are sent to that server and the sources come back with links. Without it, Friday cannot verify current web facts on its own (the browser agent can still search in Chrome).",
                    "Opcional. Un endpoint /search de un servidor SearXNG de confianza con el formato JSON activado da a Friday la herramienta research.search: las consultas se envían a ese servidor y las fuentes vuelven con enlaces. Sin él, Friday no puede verificar por sí mismo datos actuales de la web (el agente de navegación sí puede buscar en Chrome)."
                ))
        } header: {
            Label(model.t("Web search", "Búsqueda web"), systemImage: "magnifyingglass")
        }
    }

    // MARK: Weather

    private var weatherSection: some View {
        Section {
            CommitTextField(
                title: model.t("Default location (city)", "Ubicación predeterminada (ciudad)"),
                value: model.engineSettings.weatherLocation ?? ""
            ) { value in
                let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard clean != (model.engineSettings.weatherLocation ?? "") else { return }
                model.updateEngineSettings { $0.weatherLocation = clean.isEmpty ? nil : clean }
            }
            caption(
                model.t(
                    "Used when you ask about the weather without naming a place (“¿va a llover mañana?”). Friday never uses Location Services; forecasts come from Open-Meteo for the city you type here or say.",
                    "Se usa cuando preguntas por el tiempo sin decir dónde («is it going to rain tomorrow?»). Friday nunca usa los servicios de localización; las previsiones vienen de Open-Meteo para la ciudad que escribas aquí o digas."
                ))
        } header: {
            Label(model.t("Weather", "Tiempo"), systemImage: "cloud.sun")
        }
    }

    // MARK: Clock

    private var clockSection: some View {
        Section {
            ClockSetupView()
            DisclosureGroup(model.t("Shortcut names", "Nombres de los atajos")) {
                shortcutName(model.t("Create alarm", "Crear alarma"), \.createAlarm)
                shortcutName(model.t("List alarms", "Listar alarmas"), \.listAlarms)
                shortcutName(model.t("Turn alarm on/off", "Activar/desactivar alarma"), \.setAlarmEnabled)
                shortcutName(model.t("Delete alarm", "Eliminar alarma"), \.deleteAlarm)
                shortcutName(model.t("Start timer", "Iniciar temporizador"), \.startTimer)
                shortcutName(model.t("Cancel timer", "Cancelar temporizador"), \.cancelTimer)
                shortcutName(model.t("Get timer", "Leer temporizador"), \.getTimer)
                caption(
                    model.t(
                        "Only change these if you named your shortcuts differently.",
                        "Cámbialos solo si pusiste otros nombres a tus atajos."))
            }
        } header: {
            Label(model.t("Clock (alarms and timers)", "Reloj (alarmas y temporizadores)"), systemImage: "alarm")
        }
    }

    private func shortcutName(_ title: String, _ keyPath: WritableKeyPath<ShortcutNames, String>) -> some View {
        LabeledContent(title) {
            CommitTextField(title: title, value: model.engineSettings.shortcutNames[keyPath: keyPath]) { text in
                let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty, clean != model.engineSettings.shortcutNames[keyPath: keyPath] else { return }
                model.updateEngineSettings { $0.shortcutNames[keyPath: keyPath] = clean }
            }
            .multilineTextAlignment(.trailing)
        }
    }

    // MARK: Future conditions (the rain-check launch agent)

    private var agentStatusText: String {
        switch agentStatus {
        case .enabled:
            return model.t("Background agent enabled by macOS.", "Agente en segundo plano autorizado por macOS.")
        case .requiresApproval:
            return model.t(
                "Approve Friday in System Settings ▸ General ▸ Login Items & Extensions.",
                "Autoriza a Friday en Ajustes del Sistema ▸ General ▸ Ítems de inicio y extensiones.")
        case .notFound:
            return model.t(
                "macOS cannot find the agent: this build has no Contents/Library/LoginItems/\(ConditionService.agentName).app, or the app is not in a stable location (/Applications).",
                "macOS no encuentra el agente: esta compilación no tiene Contents/Library/LoginItems/\(ConditionService.agentName).app, o la app no está en una ubicación estable (/Aplicaciones).")
        case .notRegistered:
            return model.t("Background agent is not enabled.", "El agente en segundo plano no está activado.")
        @unknown default:
            return model.t("Background agent state unknown.", "Estado del agente desconocido.")
        }
    }

    private var agentNotificationsText: String {
        guard let agentRun else {
            return model.t(
                "The agent has not run yet. Press “Allow agent notifications…” once so macOS asks for its notification permission.",
                "El agente aún no se ha ejecutado. Pulsa una vez «Permitir notificaciones del agente…» para que macOS pida su permiso de notificaciones.")
        }
        let when = agentRun.checkedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—"
        return agentRun.notificationsAuthorized
            ? model.t("Notifications authorized (last agent run: \(when)).", "Notificaciones autorizadas (última ejecución: \(when)).")
            : model.t(
                "Notifications are not authorized (last agent run: \(when)). Allow them for “\(ConditionService.agentName)” in System Settings ▸ Notifications.",
                "Las notificaciones no están autorizadas (última ejecución: \(when)). Permítelas para «\(ConditionService.agentName)» en Ajustes del Sistema ▸ Notificaciones.")
    }

    private var conditionsSection: some View {
        Section {
            Toggle(
                model.t("Enable future weather checks", "Activar comprobaciones futuras del tiempo"),
                isOn: Binding(
                    get: { model.engineSettings.capabilities.backgroundConditionsEnabled }, set: setConditionsEnabled))
            .onAppear { refreshAgentStatus() }
            Text(agentStatusText).font(.caption).foregroundStyle(.secondary)
            Text(agentNotificationsText).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(model.t("Allow agent notifications…", "Permitir notificaciones del agente…")) {
                    authorizeAgentNotifications()
                }
                if agentStatus == .requiresApproval {
                    Button(model.t("Open Login Items", "Abrir Ítems de inicio")) {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                }
                Button(model.t("Refresh status", "Actualizar estado")) { refreshAgentStatus() }
            }
            if let agentFeedback { Text(agentFeedback).font(.caption).foregroundStyle(.red) }
            caption(
                model.t(
                    "The signed agent (\(ConditionService.agentName), embedded in Friday) checks saved rain conditions every 15 minutes even with Friday closed. It needs the app in a stable location (/Applications), macOS approval and its own notification permission. Sleep or offline periods delay checks; expired jobs do not fire. These are Friday notifications, not Clock alarms or Reminders items.",
                    "El agente firmado (\(ConditionService.agentName), incluido en Friday) comprueba las condiciones de lluvia guardadas cada 15 minutos incluso con Friday cerrado. Requiere la app en una ubicación estable (/Aplicaciones), la autorización de macOS y su propio permiso de notificaciones. La suspensión o la falta de conexión retrasan las comprobaciones; las caducadas no se ejecutan. Son notificaciones de Friday, no alarmas de Reloj ni elementos de Recordatorios."
                ))
        } header: {
            Label(model.t("Future conditions", "Condiciones futuras"), systemImage: "calendar.badge.clock")
        }
    }

    private func refreshAgentStatus() {
        agentStatus = SMAppService.agent(plistName: ConditionService.plistName).status
        agentRun = ConditionService.lastAgentStatus()
        model.refreshIntegrationStatuses()
    }

    private func setConditionsEnabled(_ enabled: Bool) {
        let service = SMAppService.agent(plistName: ConditionService.plistName)
        do {
            if enabled {
                if service.status != .enabled && service.status != .requiresApproval { try service.register() }
            } else {
                if service.status != .notRegistered && service.status != .notFound { try service.unregister() }
            }
            model.updateEngineSettings { $0.capabilities.backgroundConditionsEnabled = enabled }
            agentFeedback = nil
        } catch {
            agentFeedback =
                model.t("Could not change the background agent: ", "No se pudo cambiar el agente: ") + describe(error)
        }
        refreshAgentStatus()
    }

    private func authorizeAgentNotifications() {
        let url = ConditionService.agentURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            agentFeedback = model.t(
                "The signed agent is missing from this app build (expected at \(url.path)).",
                "Falta el agente firmado en esta compilación (se esperaba en \(url.path)).")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--authorize-notifications"]
        configuration.activates = true
        agentFeedback = nil
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            Task { @MainActor in
                if let error {
                    agentFeedback = model.t("Could not open the agent: ", "No se pudo abrir el agente: ") + describe(error)
                    return
                }
                // The agent records the answer and quits; re-read its status once the prompt has had time to settle.
                try? await Task.sleep(for: .seconds(4))
                refreshAgentStatus()
            }
        }
    }

    // MARK: Apple Music

    private var musicSection: some View {
        Section {
            Toggle(
                model.t("Play albums and artists through a queue playlist", "Reproducir álbumes y artistas mediante una lista de cola"),
                isOn: model.engineBinding(\.musicUsesQueuePlaylist))
            if model.engineSettings.musicUsesQueuePlaylist {
                CommitTextField(
                    title: model.t("Queue playlist name", "Nombre de la lista de cola"),
                    value: model.engineSettings.musicQueuePlaylistName
                ) { text in
                    let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !clean.isEmpty, clean != model.engineSettings.musicQueuePlaylistName else { return }
                    model.updateEngineSettings { $0.musicQueuePlaylistName = clean }
                }
            }
            caption(
                model.t(
                    "Apple Music's scripting interface can play playlists and single tracks. To play a whole album or artist, Friday fills this playlist with its tracks and plays it; your other playlists are never changed. Turn it off to play single tracks only.",
                    "La interfaz de scripts de Apple Music puede reproducir listas y canciones sueltas. Para reproducir un álbum o artista completo, Friday llena esta lista con sus canciones y la reproduce; tus otras listas nunca se modifican. Desactívalo para reproducir solo canciones sueltas."
                ))
        } header: {
            Label("Apple Music", systemImage: "music.note")
        }
    }

    // MARK: Reminders

    private var remindersSection: some View {
        Section {
            choicePicker(
                model.t("Default list", "Lista predeterminada"), kind: .reminderLists,
                selection: model.engineBinding(\.defaultReminderList))
            caption(
                model.t(
                    "Used when a reminder names no list. Without one, the list you set as default in Reminders is used.",
                    "Se usa cuando un recordatorio no indica lista. Sin una, se usa la lista predeterminada de Recordatorios."
                ))
        } header: {
            Label(model.t("Reminders", "Recordatorios"), systemImage: "checklist")
        }
    }

    // MARK: Calendar

    private var calendarSection: some View {
        Section {
            choicePicker(
                model.t("Default calendar", "Calendario predeterminado"), kind: .calendars,
                selection: model.engineBinding(\.defaultCalendar))
            Stepper(value: model.engineBinding(\.defaultEventDurationMinutes), in: 5...480, step: 5) {
                Text(
                    model.t(
                        "Default event length: \(model.engineSettings.defaultEventDurationMinutes) min",
                        "Duración predeterminada: \(model.engineSettings.defaultEventDurationMinutes) min"))
            }
            Picker(
                model.t("When a new event overlaps another", "Cuando un evento nuevo se solapa con otro"),
                selection: model.engineBinding(\.conflictPolicy)
            ) {
                Text(model.t("Ask me first", "Preguntarme antes")).tag(ConflictPolicy.ask)
                Text(model.t("Create it and warn me", "Crearlo y avisarme")).tag(ConflictPolicy.warn)
                Text(model.t("Create it without checking", "Crearlo sin comprobar")).tag(ConflictPolicy.ignore)
            }
        } header: {
            Label(model.t("Calendar", "Calendario"), systemImage: "calendar")
        }
    }

    // MARK: Notes

    @ViewBuilder
    private var notesSection: some View {
        let set = choices.set(.noteFolders)
        Section {
            if set.isLoaded, set.problem == nil {
                let accounts = Array(Set(set.items.map(\.group))).sorted()
                Picker(
                    model.t("Default account", "Cuenta predeterminada"), selection: model.engineBinding(\.defaultNotesAccount)
                ) {
                    Text(model.t("Notes' default", "La predeterminada de Notas")).tag(String?.none)
                    ForEach(accounts, id: \.self) { Text($0).tag(Optional($0)) }
                }
                let account = model.engineSettings.defaultNotesAccount
                let folders = Array(Set(set.items.filter { account == nil || $0.group == account }.map(\.name))).sorted()
                Picker(
                    model.t("Default folder", "Carpeta predeterminada"), selection: model.engineBinding(\.defaultNotesFolder)
                ) {
                    Text(model.t("Notes' default", "La predeterminada de Notas")).tag(String?.none)
                    ForEach(folders, id: \.self) { Text($0).tag(Optional($0)) }
                }
            } else {
                HStack {
                    Button(
                        set.isLoading
                            ? model.t("Loading…", "Cargando…") : model.t("Load accounts and folders", "Cargar cuentas y carpetas")
                    ) {
                        choices.load(.noteFolders, using: model, force: true, allowPrompt: true)
                    }
                    .disabled(set.isLoading)
                    if let problem = set.problem {
                        Text(problem).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
                if model.engineSettings.defaultNotesAccount != nil || model.engineSettings.defaultNotesFolder != nil {
                    Text(
                        [model.engineSettings.defaultNotesAccount, model.engineSettings.defaultNotesFolder].compactMap { $0 }
                            .joined(separator: " ▸ ")
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            caption(
                model.t(
                    "Loading these opens Notes in the background to read its folders.",
                    "Cargarlas abre Notas en segundo plano para leer sus carpetas."))
        } header: {
            Label(model.t("Notes", "Notas"), systemImage: "note.text")
        }
    }

    // MARK: Contacts

    private var contactsSection: some View {
        Section {
            Toggle(
                model.t("Look up people in Contacts", "Buscar personas en Contactos"),
                isOn: model.engineBinding(\.contactLookupEnabled))
            caption(
                model.t(
                    "When you mention a person (“meeting with Daniel”), Friday can match them to a contact and add their name and email to the event notes. Off by default; it asks for the Contacts permission only when enabled.",
                    "Cuando mencionas a una persona («reunión con Daniel»), Friday puede relacionarla con un contacto y añadir su nombre y correo a las notas del evento. Desactivado por defecto; solo pide el permiso de Contactos al activarlo."
                ))
        } header: {
            Label(model.t("Contacts (optional)", "Contactos (opcional)"), systemImage: "person.crop.circle")
        }
    }

    // MARK: Parts of the day

    private var timesOfDaySection: some View {
        Section {
            hourStepper(model.t("Morning", "Mañana"), \.morningHour)
            hourStepper(model.t("Afternoon", "Tarde"), \.afternoonHour)
            hourStepper(model.t("Evening", "Noche temprana"), \.eveningHour)
            hourStepper(model.t("Night", "Noche"), \.nightHour)
            caption(
                model.t(
                    "The time Friday assumes for phrases like “tomorrow morning” or “esta tarde”. It always tells you what it assumed.",
                    "La hora que Friday supone en frases como «mañana por la mañana» o «this evening». Siempre te dice lo que supuso."
                ))
        } header: {
            Label(model.t("Parts of the day", "Partes del día"), systemImage: "sun.max")
        }
    }

    private func hourStepper(_ title: String, _ keyPath: WritableKeyPath<JarvisSettings, Int>) -> some View {
        Stepper(value: model.engineBinding(keyPath), in: 0...23) {
            Text("\(title): \(String(format: "%02d:00", model.engineSettings[keyPath: keyPath]))")
        }
    }

    // MARK: Communication and browsers

    private var communicationSection: some View {
        Section {
            caption(
                model.t(
                    "Mail creates real drafts; sending requires reviewing all recipients and content. Messages drafts stay in the current Friday session. Delivery cannot be independently verified. Messages history is unavailable through its public API.",
                    "Mail crea borradores reales; para enviar debes revisar los destinatarios y el contenido. Los borradores de Mensajes permanecen en la sesión de Friday. La entrega no se puede verificar de forma independiente. La API pública de Mensajes no permite leer el historial."
                ))
            caption(
                model.t(
                    "Reading Safari and Chrome pages through Apple Events requires “Allow JavaScript from Apple Events” in the browser's Develop menu. Friday never enables this setting itself; the browser agent (Settings ▸ Browser) does not need it.",
                    "Leer páginas de Safari y Chrome mediante Apple Events requiere «Permitir JavaScript de eventos de Apple» en el menú Desarrollo del navegador. Friday no activa este ajuste por su cuenta; el agente de navegación (Ajustes ▸ Navegador) no lo necesita."
                ))
        } header: {
            Label(model.t("Communication and browsers", "Comunicación y navegadores"), systemImage: "envelope")
        }
    }

    // MARK: Helpers

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func describe(_ error: any Error) -> String {
        if let shortcuts = error as? ShortcutsError {
            switch shortcuts {
            case .toolUnavailable:
                return model.t("the Shortcuts command-line tool is not available on this Mac.", "la herramienta de línea de comandos de Atajos no está disponible en este Mac.")
            case .notInstalled(let name): return model.t("“\(name)” is not installed.", "«\(name)» no está instalado.")
            case .failed(_, let message): return message
            case .timedOut: return model.t("the Shortcuts tool did not answer in time.", "la herramienta de Atajos no respondió a tiempo.")
            }
        }
        return error.localizedDescription
    }

    /// A picker over names the system reported, with “system default” first. A saved value that is no longer in the
    /// list (renamed or deleted elsewhere) stays visible so it can be changed deliberately.
    @ViewBuilder
    private func choicePicker(_ title: String, kind: IntegrationChoices.Kind, selection: Binding<String?>) -> some View {
        let set = choices.set(kind)
        let names = Array(Set(set.items.map(\.name))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        Picker(title, selection: selection) {
            Text(model.t("System default", "Predeterminada del sistema")).tag(String?.none)
            if let current = selection.wrappedValue, !names.contains(current) {
                Text(current).tag(Optional(current))
            }
            ForEach(names, id: \.self) { Text($0).tag(Optional($0)) }
        }
        // Loaded when the picker scrolls into view; without the permission the problem row below explains and offers Retry.
        .onAppear { choices.load(kind, using: model) }
        if let problem = set.problem {
            HStack {
                Text(problem).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                Spacer()
                Button(model.t("Retry", "Reintentar")) { choices.load(kind, using: model, force: true, allowPrompt: true) }
                    .buttonStyle(.link)
            }
        }
    }
}

/// The Clock app has no scripting interface, so alarms and timers go through a few small Shortcuts the user builds
/// once. This view shows which exist, what is missing and the exact steps to build each one.
struct ClockSetupView: View {
    @Environment(AppModel.self) private var model
    @State private var expanded: Set<ClockShortcut> = []
    @State private var presence: [ClockShortcut: Bool] = [:]
    @State private var toolAvailable = true
    @State private var checking = false

    private var names: ShortcutNames { model.engineSettings.shortcutNames }
    private var missing: [ClockShortcut] { ClockShortcut.allCases.filter { presence[$0] == false } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.t("Clock shortcuts (one-time setup)", "Atajos del Reloj (configuración única)")).font(.headline)
            Text(
                model.t(
                    "macOS gives apps no direct way to create alarms or timers. Friday uses small shortcuts that call the Clock app's own Shortcuts actions. The first and fifth are enough to create alarms and timers; the others let Friday list, switch off, delete and — above all — verify them. Without them Friday keeps its own notification timers.",
                    "macOS no ofrece a las apps una forma directa de crear alarmas o temporizadores. Friday usa pequeños atajos que llaman a las acciones propias de la app Reloj. Con el primero y el quinto basta para crear alarmas y temporizadores; los demás permiten listar, desactivar, eliminar y, sobre todo, verificar. Sin ellos Friday usa sus propios temporizadores con notificación."
                )
            )
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if !toolAvailable {
                Label(
                    model.t(
                        "The Shortcuts command-line tool is not available on this Mac.",
                        "La herramienta de línea de comandos de Atajos no está disponible en este Mac."),
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.orange)
            }

            ForEach(ClockShortcut.allCases, id: \.self) { shortcut in row(shortcut) }

            HStack {
                Button(model.t("Open Shortcuts", "Abrir Atajos")) { openShortcutsApp() }
                Button(checking ? model.t("Checking…", "Comprobando…") : model.t("Check again", "Comprobar de nuevo")) {
                    refresh()
                }
                .disabled(checking)
                Button(model.t("Copy steps for missing shortcuts", "Copiar pasos de los atajos que faltan")) {
                    copyMissingSteps()
                }
                .disabled(missing.isEmpty)
            }
            Text(
                model.t(
                    "Finally, run each shortcut once from the Shortcuts app and choose “Always Allow” if macOS asks.",
                    "Por último, ejecuta cada atajo una vez desde la app Atajos y elige «Permitir siempre» si macOS lo pide."
                )
            )
            .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { refresh() }
        .onChange(of: model.engineSettings.shortcutNames) { _, _ in refresh() }
    }

    @ViewBuilder
    private func row(_ shortcut: ClockShortcut) -> some View {
        let name = shortcut.name(in: names)
        let present = presence[shortcut]
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(
                    systemName: present == true
                        ? "checkmark.circle.fill" : (present == false ? "circle.dashed" : "ellipsis.circle")
                )
                .foregroundStyle(
                    present == true ? Color.green : (shortcut.isEssentialForCreating ? Color.orange : Color.secondary))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(name).font(.system(.callout, design: .monospaced))
                        Text(
                            shortcut.isEssentialForCreating
                                ? model.t("required", "necesario") : model.t("optional", "opcional")
                        )
                        .font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                    }
                    Text(shortcut.purpose.resolved(model.language)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if present != true {
                    Button(
                        expanded.contains(shortcut)
                            ? model.t("Hide steps", "Ocultar pasos") : model.t("Show steps", "Ver pasos")
                    ) {
                        if expanded.contains(shortcut) { expanded.remove(shortcut) } else { expanded.insert(shortcut) }
                    }
                    .buttonStyle(.link)
                } else {
                    Text(model.t("Found", "Encontrado")).font(.caption).foregroundStyle(.green)
                }
            }
            if present != true, expanded.contains(shortcut) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(shortcut.steps(name: name, language: model.language).enumerated()), id: \.offset) {
                        index, step in
                        Text("\(index + 1). \(step)").font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                    Text(model.t("Input Friday sends: ", "Entrada que envía Friday: ") + shortcut.inputExample)
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(model.t("Output: ", "Salida: ") + shortcut.outputDescription.resolved(model.language))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.leading, 26)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private func refresh() {
        guard !checking else { return }
        checking = true
        let names = self.names
        Task {
            defer { checking = false }
            do {
                let installed = try await ShortcutsCLIRunner().installedShortcutNames()
                var result: [ClockShortcut: Bool] = [:]
                for shortcut in ClockShortcut.allCases { result[shortcut] = installed.contains(shortcut.name(in: names)) }
                presence = result
                toolAvailable = true
            } catch {
                presence = [:]
                toolAvailable = false
            }
        }
    }

    private func openShortcutsApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") {
            NSWorkspace.shared.open(url)
        }
    }

    private func copyMissingSteps() {
        let instructions = ClockShortcut.instructions(missing: missing, names: names, language: model.language)
        let text = ([instructions.title] + instructions.steps).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        model.notice = model.t("Steps copied.", "Pasos copiados.")
    }
}
