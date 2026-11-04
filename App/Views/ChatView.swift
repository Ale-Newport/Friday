import AppKit
import FridayAssistant
import FridayCore
import SwiftUI

struct ChatView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                FridayOrb(animated: model.assistant.phase.isBusy, phase: model.assistant.phase).frame(width: 22, height: 22)
                Text(statusLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if let provider = model.providers.first(where: { $0.enabled && $0.configured }) {
                    Label(provider.selectedModel ?? provider.displayName, systemImage: provider.isRemote ? "cloud" : "desktopcomputer").font(.caption).foregroundStyle(.secondary)
                } else {
                    Label(model.t("No model connected", "Sin modelo conectado"), systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if model.assistant.transcript.isEmpty { WelcomeView() }
                        ForEach(model.assistant.transcript) { item in TranscriptRow(item: item).id(item.id) }
                        if let pending = model.assistant.pending { PendingPromptView(prompt: pending) }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(20)
                }
                .onChange(of: model.assistant.revision) { _, _ in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                TextField(model.t("Ask Friday anything, or tell it what to do…", "Pregunta o pídele algo a Friday…"), text: $model.input, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...6).padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
                    .focused($focused)
                    .onSubmit { model.submit() }
                Button { model.activateByKeyboard() } label: { Image(systemName: "mic.fill") }.help(model.t("Listen (⌘⇧L)", "Escuchar (⌘⇧L)"))
                if model.assistant.phase.isBusy {
                    Button { model.interrupt() } label: { Image(systemName: "stop.fill") }.help(model.t("Stop (⌘.)", "Parar (⌘.)"))
                } else {
                    Button { model.submit() } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }.disabled(model.input.trimmingCharacters(in: .whitespaces).isEmpty).keyboardShortcut(.return, modifiers: .command)
                }
            }
            .buttonStyle(.borderless)
            .padding(12)
        }
        .toolbar {
            ToolbarItemGroup {
                Button { model.clearConversation() } label: { Label(model.t("Clear", "Limpiar"), systemImage: "trash") }.disabled(model.assistant.transcript.isEmpty)
            }
        }
        .navigationTitle("Friday")
        .onAppear { focused = true }
        .onChange(of: model.focusRequest) { _, _ in focused = true }
        .alert(model.t("Friday", "Friday"), isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("OK") { model.notice = nil }
        } message: { Text(model.notice ?? "") }
    }

    private var statusLine: String {
        switch model.assistant.phase {
        case .idle: return model.wakeStatusText
        case .listening(let partial): return partial.isEmpty ? model.t("Listening…", "Escuchando…") : partial
        case .thinking: return model.t("Thinking…", "Pensando…")
        case .acting(let step): return step
        case .speaking: return model.t("Speaking…", "Hablando…")
        case .waiting(let q): return q
        case .error(let e): return e
        }
    }
}

struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.t("Say “\(model.voice.wakeWord)” or type.", "Di «\(model.voice.wakeWord)» o escribe.")).font(.title3.weight(.semibold))
            Text(model.t("Try:", "Prueba:")).foregroundStyle(.secondary)
            ForEach([
                model.t("Play my study playlist", "Pon mi lista de estudio"),
                model.t("Add oat milk to my groceries list", "Añade leche de avena a mi lista de la compra"),
                model.t("What's the weather tomorrow?", "¿Qué tiempo hará mañana?"),
                model.t("Find the cheapest direct flight from London to Barcelona next Friday and save the best one in a note", "Busca el vuelo directo más barato de Londres a Barcelona el viernes que viene y guarda el mejor en una nota"),
                model.t("What is on my screen?", "¿Qué hay en mi pantalla?"),
            ], id: \.self) { example in
                Button { model.submit(example) } label: { Text("“\(example)”").foregroundStyle(.primary) }.buttonStyle(.link)
            }
        }
        .padding(.vertical, 20)
    }
}

struct TranscriptRow: View {
    @Environment(AppModel.self) private var model
    let item: TranscriptItem

    var body: some View {
        switch item.role {
        case .user:
            HStack { Spacer(minLength: 80); Text(item.text).padding(10).background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.18))).textSelection(.enabled) }
        case .assistant:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(.secondary).padding(.top, 2)
                VStack(alignment: .leading, spacing: 6) {
                    if item.text.isEmpty && item.isStreaming { ProgressView().controlSize(.small) } else {
                        Text(LocalizedStringKey(item.text)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    if let response = item.response { ResultBadges(response: response) }
                }
                Spacer(minLength: 40)
            }
        case .step:
            Text(item.text).font(.caption).foregroundStyle(.secondary).padding(.leading, 26)
        case .system:
            Text(item.text).font(.caption).foregroundStyle(.tertiary)
        }
    }
}

struct ResultBadges: View {
    let response: EngineResponse
    var body: some View {
        HStack(spacing: 6) {
            ForEach(response.results) { result in
                Label(result.tool.rawValue, systemImage: result.success ? "checkmark.circle" : "exclamationmark.circle")
                    .font(.caption2).foregroundStyle(result.success ? .green : .orange)
                    .help(result.message + (result.verification.isVerified ? " (verified)" : ""))
            }
            Text("\(response.durationMs) ms").font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

struct PendingPromptView: View {
    @Environment(AppModel.self) private var model
    let prompt: PendingPrompt
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(prompt.question).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                switch prompt.kind {
                case .clarification where !prompt.options.isEmpty:
                    ForEach(Array(prompt.options.enumerated()), id: \.offset) { index, option in
                        Button(option) { model.answer(prompt, index: index, approve: nil) }
                    }
                    Button(model.t("Cancel", "Cancelar")) { model.answer(prompt, index: nil, approve: false) }
                case .browserManual:
                    Button(model.t("Done", "Listo")) { model.answer(prompt, index: nil, approve: true) }.buttonStyle(.borderedProminent)
                    Button(model.t("Cancel", "Cancelar")) { model.answer(prompt, index: nil, approve: false) }
                default:
                    Button(model.t("Confirm", "Confirmar")) { model.answer(prompt, index: nil, approve: true) }.buttonStyle(.borderedProminent)
                    Button(model.t("Cancel", "Cancelar")) { model.answer(prompt, index: nil, approve: false) }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.yellow.opacity(0.12)))
    }
}
