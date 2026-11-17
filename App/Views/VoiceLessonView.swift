import SwiftUI
import WakeWordCore
import WakeWordKit

enum VoiceLessonWindow { static let id = "voice-lesson" }

/// "Train «Jarvis»": record the name in several ways, then let the tuner learn how you say it.
struct VoiceLessonView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let lesson = model.voiceLesson {
                VoiceLessonContent(lesson: lesson)
            } else if let reason = model.voiceLessonUnavailable {
                ContentUnavailableView(model.t("Can't train", "No se puede entrenar"), systemImage: "waveform.slash", description: Text(reason))
            } else {
                ProgressView().controlSize(.large)
            }
        }
        .frame(minWidth: 560, minHeight: 560)
        .padding(24)
        .task { if model.voiceLesson == nil { model.prepareVoiceLesson() } }
        .onDisappear { model.endVoiceLesson() }
    }
}

private struct VoiceLessonContent: View {
    @Environment(AppModel.self) private var model
    let lesson: VoiceLessonModel

    var body: some View {
        let state = lesson.state
        VStack(alignment: .leading, spacing: 16) {
            header(state)
            Divider()
            switch state.phase {
            case _ where !lesson.hasStarted:
                intro
            case .idle, .starting, .calibrating:
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.t("Listening to the room… stay quiet for a moment.", "Escuchando la habitación… quédate en silencio un momento.")).font(.title3)
                    ProgressView(value: state.calibration)
                    meter(state.level)
                }
            case .recording:
                recording(state)
            case .readyToLearn:
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.t("All recorded.", "Todo grabado.")).font(.title2.bold())
                    Text(model.t("Friday will now learn how you say it. It also checks every recording with people talking, music and fan noise in the background, and makes sure ordinary speech does not wake it. This takes a few minutes.",
                                 "Ahora Friday aprenderá cómo lo dices. También prueba cada grabación con gente hablando, música y ruido de fondo, y comprueba que el habla normal no lo active. Tarda unos minutos."))
                    Button(model.t("Learn my voice", "Aprender mi voz")) { lesson.learn() }.buttonStyle(.borderedProminent)
                }
            case .learning:
                VStack(alignment: .leading, spacing: 8) {
                    Text(state.learning?.message ?? model.t("Learning…", "Aprendiendo…")).font(.title3)
                    ProgressView(value: state.learning?.fraction ?? 0)
                }
            case .finished:
                result(state)
            case .installing:
                ProgressView(model.t("Installing…", "Instalando…"))
            case .installed:
                Label(model.t("Installed. Friday now listens for the way you call it.", "Instalado. Friday ya escucha tu forma de llamarlo."), systemImage: "checkmark.seal.fill")
                    .font(.title3).foregroundStyle(.green)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                Button(model.t("Start again", "Empezar de nuevo")) { model.prepareVoiceLesson() }
            case .cancelled:
                intro
            }
            if let notice = state.notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
            Spacer()
        }
    }

    private func header(_ state: VoiceLessonState) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(model.t("Train “Jarvis”", "Entrenar «Jarvis»")).font(.largeTitle.bold())
                if lesson.hasStarted, state.stepCount > 0, state.phase == .recording {
                    Text(model.t("Step \(state.stepIndex + 1) of \(state.stepCount)", "Paso \(state.stepIndex + 1) de \(state.stepCount)")).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: "waveform.badge.mic").font(.system(size: 34)).foregroundStyle(.tint)
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.t("About four minutes. You'll say “Jarvis” plainly, with different intonations (loud, quiet, asking, drawn out), the way you really call it, any variants you listed in Settings (“Jarbis”, “Yarvis”…), a few requests, and then read a short text.",
                         "Unos cuatro minutos. Dirás «Jarvis» tal cual, con distintas entonaciones (fuerte, bajito, preguntando, alargado), como lo llamas de verdad, las variantes que hayas añadido en Ajustes («Jarbis», «Yarvis»…), algunas peticiones y luego leerás un texto corto."))
            if !model.voice.wakeWordVariants.isEmpty {
                Text(model.t("Your variants: ", "Tus variantes: ") + model.voice.wakeWordVariants.joined(separator: ", ")).font(.callout).foregroundStyle(.secondary)
            }
            Text(model.t("Recordings stay in memory and are discarded when the lesson ends; only a short list of sounds is saved.",
                         "Las grabaciones se quedan en memoria y se descartan al terminar; solo se guarda una lista corta de sonidos."))
                .font(.caption).foregroundStyle(.secondary)
            Button(model.t("Start", "Empezar")) { lesson.start() }.buttonStyle(.borderedProminent).controlSize(.large)
        }
    }

    private func recording(_ state: VoiceLessonState) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let step = lesson.step {
                Text(step.title).font(.title2.bold())
                Text(step.instruction).foregroundStyle(.secondary)
            }
            Text(state.prompt)
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 18)
                .background(RoundedRectangle(cornerRadius: 14).fill(.quaternary))
                .contentTransition(.opacity)
                .animation(.easeInOut, value: state.acceptedCount)
            if state.targetSeconds > 0 {
                ProgressView(value: min(1, state.speechSeconds / state.targetSeconds)) {
                    Text(String(format: "%.0f / %.0f s", state.speechSeconds, state.targetSeconds)).monospacedDigit()
                }
            } else {
                ProgressView(value: Double(state.heard), total: Double(max(1, state.required))) {
                    Text("\(state.heard) / \(state.required)").monospacedDigit()
                }
            }
            meter(state.level)
            if let hint = state.hint { Label(hint.message, systemImage: "lightbulb").foregroundStyle(.orange) }
            HStack {
                Button(model.t("Redo this step", "Repetir este paso")) { lesson.redoStep() }
                Spacer()
                Button(model.t("Next", "Siguiente")) { lesson.nextStep() }.disabled(!state.canFinishStep)
            }
        }
    }

    private func result(_ state: VoiceLessonState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let report = state.report {
                Text(report.isImprovement ? model.t("Found a better fit for your voice.", "He encontrado un ajuste mejor para tu voz.") : model.t("No improvement this time.", "Esta vez no hay mejora.")).font(.title2.bold())
                if report.heldBack > 0 {
                    Text(model.t("Recordings it had not seen (including noisy copies): heard \(report.heardBefore) of \(report.heldBack) before, \(report.heardAfter) of \(report.heldBack) now.",
                                 "Grabaciones que no había visto (incluidas copias con ruido): antes oía \(report.heardBefore) de \(report.heldBack), ahora \(report.heardAfter) de \(report.heldBack)."))
                }
                if report.isImprovement {
                    Button(model.t("Use it", "Usarlo")) { lesson.install() }.buttonStyle(.borderedProminent)
                } else {
                    Text(model.t("Try again closer to the microphone, or raise the sensitivity a little.", "Prueba otra vez más cerca del micrófono, o sube un poco la sensibilidad.")).foregroundStyle(.secondary)
                }
            }
            Button(model.t("Start again", "Empezar de nuevo")) { model.prepareVoiceLesson() }
        }
    }

    private func meter(_ level: Float) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(level > 0.85 ? Color.red : Color.accentColor).frame(width: geometry.size.width * CGFloat(min(1, max(0, level))))
            }
        }
        .frame(height: 8)
        .animation(.linear(duration: 0.1), value: level)
    }
}
