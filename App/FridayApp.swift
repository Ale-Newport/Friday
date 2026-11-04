import AppKit
import SwiftUI

@main
struct FridayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView().environment(model)
        } label: {
            MenuBarLabel().environment(model)
        }
        .menuBarExtraStyle(.window)

        Window("Friday", id: ChatWindow.id) {
            ChatView().environment(model)
        }
        .defaultSize(width: 720, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Friday") {
                Button("Listen now") { model.activateByKeyboard() }.keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Stop") { model.interrupt() }.keyboardShortcut(".", modifiers: .command)
                Button("Clear conversation") { model.clearConversation() }.keyboardShortcut("k", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView().environment(model)
        }

        Window("Friday Diagnostics", id: DiagnosticsWindow.id) {
            DiagnosticsView().environment(model)
        }
        .defaultSize(width: 760, height: 620)
    }
}

enum ChatWindow { static let id = "chat" }
enum DiagnosticsWindow { static let id = "diagnostics" }

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        guard let identifier = Bundle.main.bundleIdentifier else { return }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).filter { $0 != NSRunningApplication.current }
        if let existing = others.first {
            existing.activate()
            NSApp.terminate(nil)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        Task { @MainActor in
            await AppModel.shared.start()
            if AppModel.shared.composition.launch.showWelcome || !AppModel.shared.composition.wakeSettingsStore.hasSeenWelcome {
                AppModel.shared.composition.wakeSettingsStore.hasSeenWelcome = true
                WindowOpener.open(ChatWindow.id)
            }
            #if DEBUG
            if let delay = AppModel.shared.composition.launch.simulateAfter {
                try? await Task.sleep(for: .seconds(delay))
                AppModel.shared.activateByKeyboard()
            }
            #endif
        }
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppModel.shared.shutdownImmediately()
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Opens a SwiftUI `Window` scene by id from AppKit code paths.
@MainActor
enum WindowOpener {
    static func open(_ id: String) {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == id || $0.identifier?.rawValue.hasPrefix(id) == true }) {
            window.makeKeyAndOrderFront(nil)
            return
        }
        // Fallback: the URL scheme SwiftUI registers for window scenes.
        if let url = URL(string: "friday://\(id)") { NSWorkspace.shared.open(url) }
    }
}
