import Foundation
import FridayCore
import Testing

@testable import FridayIntegrations

/// Bad arguments must come back as typed, bilingual validation errors that name the parameter — never as an
/// internal failure such as "Calculator.Failure error 0" — so the user learns what was wrong and the planner can
/// repair the call.
@Suite struct ValidationErrorTests {
    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("friday-tests-" + UUID().uuidString)
    }

    private func conditionsRegistry() -> ToolRegistry {
        let integration = ConditionsIntegration(
            store: ConditionJobStore(url: temporaryFile()), enabled: { true }, notificationsAuthorized: { true })
        return ToolRegistry(integrations: [integration])
    }

    private func conditionsContext(language: Language = .en) -> ExecutionContext {
        var settings = JarvisSettings()
        settings.capabilities.backgroundConditionsEnabled = true
        return executionContext(language: language, settings: settings)
    }

    private func rainCheck(at checkAt: String) -> JSONObject {
        ["location": "London", "place_id": 1, "forecast_date": "2026-10-25", "check_at": .string(checkAt), "title": "Umbrella"]
    }

    @Test func checkAtInThePastIsAnInvalidArgumentOnCheckAt() async throws {
        // "now" in the shared test context is 2026-10-17T12:08Z.
        let error = await #expect(throws: JarvisError.self) {
            try await conditionsRegistry().run(
                "conditions.schedule_rain", rainCheck(at: "2026-10-10T07:00:00Z"), context: conditionsContext())
        }
        guard case .invalidArgument(let parameter, let text) = try #require(error) else {
            Issue.record("expected invalidArgument, got \(String(describing: error))")
            return
        }
        #expect(parameter == "check_at")
        #expect(text.en.contains("check_at") && text.en.contains("past"))
        #expect(text.es.contains("check_at") && text.es.contains("pasado"))
        #expect(error?.code == "invalid_argument")
    }

    @Test func checkAtMoreThanSevenDaysAheadIsAnInvalidArgument() async throws {
        let error = await #expect(throws: JarvisError.self) {
            try await conditionsRegistry().run(
                "conditions.schedule_rain", rainCheck(at: "2026-11-30T07:00:00Z"), context: conditionsContext(language: .es))
        }
        guard case .invalidArgument(let parameter, let text) = try #require(error) else {
            Issue.record("expected invalidArgument, got \(String(describing: error))")
            return
        }
        #expect(parameter == "check_at")
        #expect(text.en.contains("7 days"))
        #expect(text.es.contains("7 días"))
        #expect(error?.message(in: .es).contains("check_at") == true)
    }

    @Test func checkTimeAcceptsAFutureTimeWithinAWeek() throws {
        let context = conditionsContext()
        let at = try ConditionsIntegration.checkTime("2026-10-20T07:00:00Z", context: context)
        #expect(at > context.now)
        #expect(throws: JarvisError.self) { try ConditionsIntegration.checkTime(nil, context: context) }
        #expect(throws: JarvisError.self) { try ConditionsIntegration.checkTime("tomorrow morning", context: context) }
    }

    private func remindersRegistry() -> ToolRegistry {
        ToolRegistry(integrations: [RemindersIntegration(store: InMemoryReminderStore.standard())])
    }

    @Test func unknownWeekdayCodeIsAValidationErrorNamingTheParameter() async throws {
        let error = await #expect(throws: JarvisError.self) {
            try await remindersRegistry().run(
                .remindersCreate,
                ["title": "Stretch", "due": "2026-10-27T10:00:00Z", "recurrence": "weekly", "repeat_weekdays": ["mo"]])
        }
        guard case .invalidArgument(let parameter, let text) = try #require(error) else {
            Issue.record("expected invalidArgument, got \(String(describing: error))")
            return
        }
        #expect(parameter == "repeat_weekdays")
        #expect(text.en.contains("'mo'") && text.en.contains("mon, tue"))
        #expect(text.es.contains("«mo»"))
    }

    @Test func fullWeekdayNamesInEitherLanguageAreAccepted() async throws {
        let created = try await remindersRegistry().run(
            .remindersCreate,
            [
                "title": "Stretch", "due": "2026-10-27T10:00:00Z", "recurrence": "weekly",
                "repeat_weekdays": ["Monday", "miércoles", "fri"],
            ])
        let days = created.output?.data?["recurrence_details"]?["iso_weekdays"]?.arrayValue?.compactMap(\.intValue)
        #expect(days == [1, 3, 5])
        #expect(RecurrenceSpecification.weekday(named: "SÁBADO") == 6)
        #expect(RecurrenceSpecification.weekday(named: "sun") == 7)
        #expect(RecurrenceSpecification.weekday(named: "someday") == nil)
    }

    @Test func repeatUntilAndRepeatCountTogetherAreRejectedAsAValidationError() async throws {
        let error = await #expect(throws: JarvisError.self) {
            try await remindersRegistry().run(
                .remindersCreate,
                [
                    "title": "Stretch", "due": "2026-10-27T10:00:00Z", "recurrence": "daily",
                    "repeat_until": "2026-12-01T10:00:00Z", "repeat_count": 5,
                ])
        }
        guard case .invalidArgument(let parameter, let text) = try #require(error) else {
            Issue.record("expected invalidArgument, got \(String(describing: error))")
            return
        }
        #expect(parameter == "repeat_until")
        #expect(text.en.contains("not both"))
        #expect(text.es.contains("no ambos"))
    }

    @Test func weekdaysWithANonWeeklyRecurrenceAreRejected() async throws {
        let error = await #expect(throws: JarvisError.self) {
            try await remindersRegistry().run(
                .remindersCreate,
                ["title": "Stretch", "due": "2026-10-27T10:00:00Z", "recurrence": "daily", "repeat_weekdays": ["mon"]])
        }
        guard case .invalidArgument(let parameter, let text) = try #require(error) else {
            Issue.record("expected invalidArgument, got \(String(describing: error))")
            return
        }
        #expect(parameter == "repeat_weekdays")
        #expect(text.en.contains("weekly") && text.en.contains("daily"))
    }

    @Test func stopwatchLapBeforeStartIsAValidationErrorNotAnInternalFailure() async throws {
        let registry = ToolRegistry(integrations: [StopwatchIntegration(store: StopwatchStore(url: temporaryFile()))])
        let error = await #expect(throws: JarvisError.self) {
            try await registry.run("stopwatch.control", ["operation": "lap"])
        }
        guard case .invalidArgument(let parameter, let text) = try #require(error) else {
            Issue.record("expected invalidArgument, got \(String(describing: error))")
            return
        }
        #expect(parameter == "operation")
        #expect(text.en.contains("Start the stopwatch"))
        #expect(text.es.contains("Inicia el cronómetro"))
    }

    @Test func stopwatchDisplayNameIsBrandedFridayInBothLanguages() {
        let name = StopwatchIntegration().displayName
        #expect(name.en == "Friday stopwatch")
        #expect(name.es == "Cronómetro de Friday")
    }

    // MARK: browser.read_tab error mapping

    @Test func onlyAJavaScriptRefusalBecomesTheSetupMessage() {
        func classify(_ kind: AppleScriptFailure.Kind, _ message: String, reading: Bool = true) -> JarvisError? {
            BrowserIntegration.classify(
                AppleScriptFailure(kind: kind, code: nil, message: message), reading: reading, browser: "Google Chrome",
                language: .en)
        }
        #expect(classify(.timeout, "did not finish") == nil, "a timeout keeps its own meaning")
        #expect(classify(.notAuthorized, "Not authorized") == nil, "automation consent is a permission error")
        #expect(classify(.custom, "NOT_FOUND|window")?.code == "tab_not_found")
        #expect(classify(.custom, "CHANGED|navigation")?.code == "page_changed")
        let refused = classify(.scriptError, "Executing JavaScript through AppleScript is turned off.")
        #expect(refused?.code == "setup_required")
        if case .setupRequired(let instructions, let text) = refused {
            #expect(instructions.steps.joined().contains("Allow JavaScript from Apple Events"))
            #expect(text.es.contains("Google Chrome"))
        } else {
            Issue.record("expected setupRequired, got \(String(describing: refused))")
        }
        #expect(classify(.scriptError, "Executing JavaScript is turned off", reading: false) == nil, "tab listing never runs JavaScript")
        #expect(classify(.scriptError, "some other error") == nil)
    }

    @Test func browserTimeoutsAndMissingTabsAreReportedAsSuchNotAsAJavaScriptSetupProblem() async throws {
        let scripts = FakeScripts()
        scripts.on(BrowserScripts.chromeRead, failsWith: AppleScriptFailure(kind: .timeout, code: -1712, message: "timed out"))
        let registry = ToolRegistry(integrations: [BrowserIntegration(scripts: scripts, access: FakeAutomation())])
        let timeout = await #expect(throws: JarvisError.self) {
            try await registry.run("browser.read_tab", ["browser": "chrome"])
        }
        #expect(timeout?.code == "app_timeout")

        scripts.on(BrowserScripts.chromeRead, failsWith: AppleScriptFailure(kind: .custom, code: 9001, message: "NOT_FOUND|window"))
        let missing = await #expect(throws: JarvisError.self) {
            try await registry.run("browser.read_tab", ["browser": "chrome"])
        }
        #expect(missing?.code == "tab_not_found")
        #expect(missing?.message(in: .es).contains("Google Chrome") == true)

        scripts.on(
            BrowserScripts.chromeRead,
            failsWith: AppleScriptFailure(kind: .scriptError, code: nil, message: "Executing JavaScript through AppleScript is turned off."))
        let refused = await #expect(throws: JarvisError.self) {
            try await registry.run("browser.read_tab", ["browser": "chrome"])
        }
        #expect(refused?.code == "setup_required")
    }

    // MARK: mail.read / mail.attach failure codes

    @Test func unexpectedMailOutputIsATypedFailureNotADecodingError() async throws {
        let scripts = FakeScripts()
        scripts.on(MailScripts.read, returns: "garbage")
        let registry = ToolRegistry(integrations: [MailIntegration(scripts: scripts, access: FakeAutomation())])
        let error = await #expect(throws: JarvisError.self) {
            try await registry.run("mail.read", ["id": 7])
        }
        #expect(error?.code == "invalid_mail_output")
        #expect(error?.message(in: .es).contains("Mail") == true)
    }
}
