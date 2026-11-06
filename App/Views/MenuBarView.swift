import FridayAssistant
import SwiftUI

struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        let active = model.voiceActive
        let listening = model.wake.state.isListening
        Image(systemName: active ? "waveform.circle.fill" : (listening ? "waveform.circle" : "waveform.slash"))
            .symbolRenderingMode(.hierarchical)
            .accessibilityLabel("Friday")
            // The label exists from launch, so this is where "first run" can open a window: a menu-bar-only app
            // otherwise shows nothing but a small icon the first time it starts.
            .task {
                if model.consumeFirstRunSetup() {
                    openWindow(id: ChatWindow.id)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
    }
}

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                FridayOrb(animated: model.voiceActive, phase: model.assistant.phase).frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Friday").font(.headline)
                    Text(model.wakeStatusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { model.voice.wakeWordEnabled }, set: { model.setWakeWordEnabled($0) })).toggleStyle(.switch).labelsHidden()
                    .help(model.t("Listen for the wake word", "Escuchar la palabra de activación"))
            }
            if !model.microphoneAuthorized {
                Button(model.t("Allow microphone access…", "Permitir acceso al micrófono…")) { model.openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") }
                    .buttonStyle(.link)
            }
            if let notice = model.notice {
                // Notices reach the person here too: a menu-bar app often has no window open to show an alert in.
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text(notice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { model.notice = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                        .accessibilityLabel(model.t("Dismiss", "Descartar"))
                }
            }
            TextField(model.t("Ask Friday…", "Pídele algo a Friday…"), text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { guard !text.isEmpty else { return }; model.submit(text); text = "" }
            if let last = model.assistant.transcript.last(where: { $0.role == .assistant && !$0.text.isEmpty }) {
                Text(last.text).font(.callout).lineLimit(4).foregroundStyle(.secondary)
            }
            if let line = model.assistant.browserStatusLine { Text(line).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
            Divider()
            HStack {
                Button { model.activateByKeyboard() } label: { Label(model.t("Listen now", "Escuchar ahora"), systemImage: "mic") }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Spacer()
                if model.voiceActive {
                    Button { model.interrupt() } label: { Label(model.t("Stop", "Parar"), systemImage: "stop.fill") }
                }
            }
            Divider()
            Button { openWindow(id: ChatWindow.id); NSApp.activate(ignoringOtherApps: true) } label: { Label(model.t("Open chat", "Abrir chat"), systemImage: "bubble.left.and.text.bubble.right") }
            Button { openWindow(id: DiagnosticsWindow.id); NSApp.activate(ignoringOtherApps: true) } label: { Label(model.t("Diagnostics", "Diagnóstico"), systemImage: "waveform.path.ecg") }
            Button { openSettings(); NSApp.activate(ignoringOtherApps: true) } label: { Label(model.t("Settings…", "Ajustes…"), systemImage: "gearshape") }
                .keyboardShortcut(",", modifiers: .command)
            Divider()
            Button(model.t("Quit Friday", "Salir de Friday")) { model.quit() }.keyboardShortcut("q", modifiers: .command)
        }
        .buttonStyle(.plain)
        .padding(14)
        .frame(width: 320)
    }
}
