import Observation
import SwiftUI
import WakeWordCore
import WakeWordKit

/// "Train «Jarvis»": follows a ``VoiceLesson`` (record the name, intonations, the person's own variants, ordinary talk;
/// then the tuner — which also hears every recording over babble, music and noise — proposes a profile to install).
@MainActor
@Observable
final class VoiceLessonModel {
    private(set) var state: VoiceLessonState
    let script: VoiceLessonScript
    private(set) var hasStarted = false
    private let lesson: VoiceLesson
    private var follower: Task<Void, Never>?

    init(lesson: VoiceLesson, script: VoiceLessonScript) {
        self.lesson = lesson
        self.script = script
        self.state = VoiceLessonState(stepCount: script.steps.count)
        follower = Task { [weak self] in
            for await update in await lesson.stateUpdates() {
                guard let self else { return }
                self.state = update
            }
        }
    }

    var step: VoiceLessonScript.Step? { script.steps.indices.contains(state.stepIndex) ? script.steps[state.stepIndex] : nil }

    var hasWorkToKeep: Bool {
        guard hasStarted else { return false }
        switch state.phase {
        case .starting, .calibrating, .recording, .readyToLearn, .learning, .installing: return true
        case .finished: return state.report?.isImprovement == true
        default: return false
        }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        Task { await lesson.begin() }
    }
    func redoStep() { Task { await lesson.redoStep() } }
    func nextStep() { Task { await lesson.finishStep() } }
    func learn() { Task { await lesson.startLearning() } }
    func install() { Task { await lesson.install() } }
    func close() {
        let lesson = lesson
        Task { [follower] in
            await lesson.cancel()
            follower?.cancel()
        }
    }
}

extension AppModel {
    /// A fresh lesson for the window (the one there, if any, is let go of). Nil when the engine cannot learn.
    func prepareVoiceLesson() {
        voiceLesson?.close()
        voiceLesson = nil
        guard let trainer = composition.voiceTrainer(engineID: wakeSettings.engineID) else {
            voiceLessonUnavailable = t("The wake-word engine in use cannot learn a voice (choose the free engine).", "El motor de activación en uso no puede aprender una voz (elige el motor gratuito).")
            return
        }
        voiceLessonUnavailable = nil
        let script = VoiceLessonScript.friday(spanish: language == .es, variants: voice.wakeWordVariants)
        let composition = composition
        let lesson = VoiceLesson(
            script: script, runtime: composition.wakeRuntime, trainer: trainer,
            environment: { [weak self] in
                await MainActor.run { composition.wakeEnvironment(sensitivity: self?.wakeSettings.sensitivity ?? 0.5) }
            },
            profileDidChange: { [weak self] in Task { @MainActor in self?.refreshVoiceProfile() } })
        voiceLesson = VoiceLessonModel(lesson: lesson, script: script)
    }

    func prepareVoiceLessonUnlessOneIsUnderWay() {
        if voiceLesson?.hasWorkToKeep != true { prepareVoiceLesson() }
    }

    func endVoiceLesson() {
        voiceLesson?.close()
        voiceLesson = nil
        refreshVoiceProfile()
    }

    func refreshVoiceProfile() {
        voiceProfile = composition.voiceTrainer(engineID: wakeSettings.engineID)?.currentProfile()
    }

    func removeVoiceProfile() {
        guard let trainer = composition.voiceTrainer(engineID: wakeSettings.engineID) else { return }
        _ = try? trainer.removeProfile()
        refreshVoiceProfile()
        let runtime = composition.wakeRuntime
        Task { _ = await runtime.reloadEngine() }
    }
}
