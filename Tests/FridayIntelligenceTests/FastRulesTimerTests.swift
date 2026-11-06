import Foundation
import Testing
import FridayCore
@testable import FridayIntelligence

@Suite struct FastRulesTimerTests {
    private let tools: [ToolDescriptor] = [
        ToolDescriptor(name: "jarvis_timers.create", integration: "jarvis_timers", title: "Start", summary: "Start", parameters: [.integer("duration_seconds", "s", required: true, min: 1, max: 604_800), .string("label", "l")], safety: .modifying),
        ToolDescriptor(name: "jarvis_timers.cancel", integration: "jarvis_timers", title: "Cancel", summary: "Cancel", parameters: [.string("id", "i"), .string("label", "l")], safety: .modifying),
        ToolDescriptor(name: "friday.current_time", integration: "friday", title: "Time", summary: "Now", safety: .readOnly),
    ]

    @Test(arguments: [
        ("pon un temporizador para 10 minutos", 600), ("set a timer for 25 minutes", 1500), ("temporizador de 90 segundos", 90),
        ("timer for forty five minutes", 2700), ("temporizador de cuarenta y cinco minutos", 2700), ("timer for twenty-five minutes", 1500),
        ("timer for ten minutes", 600), ("pon un temporizador de veinticinco minutos", 1500), ("set a timer for an hour and a half", 5400),
        ("ponme un temporizador para media hora", 1800),
    ])
    func timerCreationsParseTheDuration(text: String, seconds: Int) {
        let plan = FastRules.plan(for: text, language: .es, tools: tools)
        #expect(plan?.steps.first?.tool.rawValue == "jarvis_timers.create", Comment(rawValue: "no creation for \(text): \(String(describing: plan))"))
        #expect(plan?.steps.first?.arguments["duration_seconds"]?.intValue == seconds, Comment(rawValue: text))
    }

    @Test(arguments: ["cancel the timer", "stop the timer", "para el temporizador", "detén el temporizador", "quita el temporizador", "cancela el temporizador de la pasta", "cancel my pasta timer"])
    func timerCancelsCarryNoGuessedLabel(text: String) {
        let plan = FastRules.plan(for: text, language: .es, tools: tools)
        #expect(plan?.steps.first?.tool.rawValue == "jarvis_timers.cancel", Comment(rawValue: "no cancel for \(text): \(String(describing: plan))"))
        #expect(plan?.steps.first?.arguments["label"] == nil, Comment(rawValue: text))
    }

    @Test(arguments: ["pausa el temporizador", "pause the timer", "how much time is left on the timer", "cuánto queda del temporizador", "extend the timer by 5 minutes", "set a timer"])
    func otherTimerControlsAreLeftToTheModel(text: String) {
        #expect(FastRules.plan(for: text, language: .en, tools: tools) == nil, Comment(rawValue: text))
    }

    @Test(arguments: ["set a timer for 10 minutes and remind me to call mom", "pon un temporizador de 5 minutos y luego avísame", "what time is it and open Notes", "cancel the timer and then play some jazz"])
    func compoundCommandsNeverTakeTheFastPath(text: String) {
        #expect(FastRules.plan(for: text, language: .en, tools: tools) == nil, Comment(rawValue: text))
    }

    @Test(arguments: ["what time is it", "What time is it?", "qué hora es", "¿Qué hora es?", "hey friday what time is it please", "dime la hora", "what's the date", "qué día es hoy", "Friday, what day is it?"])
    func wholeUtteranceTimeQuestionsAreAnswered(text: String) {
        #expect(FastRules.plan(for: text, language: .en, tools: tools)?.steps.first?.tool.rawValue == "friday.current_time", Comment(rawValue: text))
    }

    @Test(arguments: ["¿qué hora es la reunión?", "qué día es la boda", "qué fecha es el examen", "cambia la hora", "pon la alarma a la hora", "what time is the meeting", "what day is the wedding", "qué hora es en Tokio"])
    func questionsAboutSomethingElseAreNotTheTime(text: String) {
        #expect(FastRules.plan(for: text, language: .es, tools: tools) == nil, Comment(rawValue: text))
    }
}

@Suite struct FastRulesInstalledAppTests {
    private let tools: [ToolDescriptor] = [
        ToolDescriptor(name: "system.open_app", integration: "system", title: "Open app", summary: "Open", parameters: [.string("application", "n", required: true)], safety: .modifying),
        ToolDescriptor(name: "system.close_app", integration: "system", title: "Close app", summary: "Close", parameters: [.string("application", "n", required: true)], safety: .modifying),
    ]
    private let installed = ["spotify": "Spotify", "safari": "Safari", "notes": "Notes", "finder": "Finder", "whatsapp": "WhatsApp"]

    @Test(arguments: [("open Spotify", "Spotify"), ("abre spotify", "Spotify"), ("open whatsapp", "WhatsApp"), ("launch Safari", "Safari"), ("abre Notas", "Notes")])
    func installedAppsAreOpened(text: String, expected: String) {
        let plan = FastRules.plan(for: text, language: .en, tools: tools, installedApps: installed)
        #expect(plan?.steps.first?.arguments["application"]?.stringValue == expected, Comment(rawValue: text))
    }

    @Test(arguments: ["open youtube", "open gmail", "open google", "start recording", "start timer", "close window", "cierra todo", "open twitter", "abre Chrome", "open the door"])
    func websitesActionsAndMissingAppsAreLeftToTheModel(text: String) {
        #expect(FastRules.plan(for: text, language: .en, tools: tools, installedApps: installed) == nil, Comment(rawValue: text))
    }

    @Test func scanningListsApplicationBundles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("friday-apps-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Google Chrome.app"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Notes.txt"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let apps = InstalledApplications(roots: [root.path, "/nonexistent/dir"]).names()
        #expect(apps == ["google chrome": "Google Chrome"])
    }
}
