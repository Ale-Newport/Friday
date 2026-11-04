import Foundation

// What an engine may offer beyond listening: learning how *this* person says the word. The application records the person
// (see ``VoiceCapture``), hands the recordings over, and shows what the engine reports; what is learned, and how it is kept, is the
// engine's own business. An engine that cannot do this simply has no ``VoiceTrainer`` (``EngineDescriptor/voiceTrainer`` is nil).

/// What a person said while teaching the app their voice: 16 kHz mono clips (within ±1), kept in memory only and thrown away by the
/// caller once the lesson is over.
public struct VoiceRecordings: Sendable {
    public struct Utterance: Sendable {
        public var samples: [Float]
        /// Which part of the lesson it came from ("jarvis", "hey-jarvis", "commands"). Some utterances are held back to check what was
        /// learned, spread over these.
        public var source: String

        public init(samples: [Float], source: String) {
            self.samples = samples
            self.source = source
        }
    }

    public static let sampleRate = VoiceCapture.sampleRate

    /// The word said once each, the way the person really says it.
    public var utterances: [Utterance]
    /// Stretches of ordinary talk without the word (each a few seconds to a minute): what must not wake the assistant.
    public var ordinaryTalk: [[Float]]

    public init(utterances: [Utterance] = [], ordinaryTalk: [[Float]] = []) {
        self.utterances = utterances
        self.ordinaryTalk = ordinaryTalk
    }
}

/// How far a lesson's analysis has got, for a progress bar.
public struct VoiceTrainingProgress: Sendable, Equatable {
    /// What is happening now, in words for the person ("Trying ways of saying it…").
    public var message: String
    /// 0…1, never going back.
    public var fraction: Double

    public init(message: String, fraction: Double) {
        self.message = message
        self.fraction = min(1, max(0, fraction.isFinite ? fraction : 0))
    }
}

/// What came of analysing a lesson.
public struct VoiceTrainingReport: Sendable, Equatable {
    public enum Verdict: Sendable, Equatable {
        /// What was learned does better on phrases it was not taught with, and stays quiet on what must not wake it.
        case improved
        /// Nothing found that does better (or no way to tell): keep the engine as it is.
        case notImproved(reason: String)
        /// Too little to learn from or to check against.
        case notEnoughSpeech(reason: String)
    }

    public var verdict: Verdict
    /// Phrases kept back from the learning to check it, and how many of them the engine understood before and after.
    public var heldBack: Int
    public var heardBefore: Int
    public var heardAfter: Int
    /// The same over every phrase of the lesson, those learned from included.
    public var total: Int
    public var totalHeardBefore: Int
    public var totalHeardAfter: Int
    /// How many look-alike words and stretches of ordinary speech the new settings were checked against, and how many of them
    /// wrongly woke it.
    public var silenceChecks: Int
    public var falseAlarms: Int
    /// For a log or a bug report; not for the person.
    public var notes: [String]
    /// What ``VoiceTrainer/install`` needs, opaque to everyone else.
    public var payload: Data

    public init(
        verdict: Verdict, heldBack: Int = 0, heardBefore: Int = 0, heardAfter: Int = 0, total: Int = 0, totalHeardBefore: Int = 0,
        totalHeardAfter: Int = 0, silenceChecks: Int = 0, falseAlarms: Int = 0, notes: [String] = [], payload: Data = Data()
    ) {
        self.verdict = verdict
        self.heldBack = heldBack
        self.heardBefore = heardBefore
        self.heardAfter = heardAfter
        self.total = total
        self.totalHeardBefore = totalHeardBefore
        self.totalHeardAfter = totalHeardAfter
        self.silenceChecks = silenceChecks
        self.falseAlarms = falseAlarms
        self.notes = notes
        self.payload = payload
    }

    public var isImprovement: Bool { verdict == .improved }
}

public enum VoiceTrainingError: Error, Equatable, Sendable {
    /// The engine cannot learn right now (its files are missing…), with a reason for the person.
    case unavailable(String)
    case cancelled
    case failed(String)
}

extension VoiceTrainingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason), .failed(let reason): reason
        case .cancelled: "Cancelled."
        }
    }
}

/// What the engine has learned about this person so far.
public struct VoiceProfile: Sendable, Equatable {
    /// One line for the person ("3 ways of saying it, learned on 17 October").
    public var summary: String
    public var learnedAt: Date?

    public init(summary: String, learnedAt: Date? = nil) {
        self.summary = summary
        self.learnedAt = learnedAt
    }
}

/// What installing or removing a profile did to what was there before.
public struct VoiceProfileChange: Sendable, Equatable {
    /// Where the previous profile was kept, if there was one (so that nothing the person had is ever lost).
    public var keptPrevious: String?

    public init(keptPrevious: String? = nil) {
        self.keptPrevious = keptPrevious
    }
}

/// An engine's ability to learn a person's voice. A set of closures, like ``EngineDescriptor`` itself, so that the application
/// never sees the engine behind it.
public struct VoiceTrainer: Sendable {
    /// Analyses `recordings` (minutes of work: it reports its progress and stops when its task is cancelled) and says what it found.
    /// It changes nothing the engine uses; ``install`` does that.
    public let learn: @Sendable (_ recordings: VoiceRecordings, _ environment: EngineEnvironment, _ progress: @escaping @Sendable (VoiceTrainingProgress) -> Void) async throws -> VoiceTrainingReport
    /// Keeps what ``learn`` found so that the engine uses it the next time it is built. The profile that was there is kept, not
    /// overwritten.
    public let install: @Sendable (_ report: VoiceTrainingReport) throws -> VoiceProfileChange
    /// Undoes an ``install``, given what it returned: the profile that was in force before it is in force again (or, if there was none, the
    /// engine's own settings are). The profile being given up is kept aside, not deleted.
    public let revert: @Sendable (_ change: VoiceProfileChange) throws -> Void
    /// What is installed now, if anything.
    public let currentProfile: @Sendable () -> VoiceProfile?
    /// Goes back to the engine's own settings. The profile is kept aside, not deleted. Nil when there was none.
    public let removeProfile: @Sendable () throws -> VoiceProfileChange?

    public init(
        learn: @escaping @Sendable (VoiceRecordings, EngineEnvironment, @escaping @Sendable (VoiceTrainingProgress) -> Void) async throws -> VoiceTrainingReport,
        install: @escaping @Sendable (VoiceTrainingReport) throws -> VoiceProfileChange,
        revert: @escaping @Sendable (VoiceProfileChange) throws -> Void,
        currentProfile: @escaping @Sendable () -> VoiceProfile?,
        removeProfile: @escaping @Sendable () throws -> VoiceProfileChange?
    ) {
        self.learn = learn
        self.install = install
        self.revert = revert
        self.currentProfile = currentProfile
        self.removeProfile = removeProfile
    }
}
