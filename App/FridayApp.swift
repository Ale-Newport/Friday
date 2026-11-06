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
    private var terminating = false

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
            let model = AppModel.shared
            if model.composition.launch.probeEngines {
                print(model.composition.engineProbeReport())
                exit(0)
            }
            // The first-run chat window is opened by `MenuBarLabel` (the one view that exists from launch): a window
            // scene can only be opened from SwiftUI's environment, and the app registers no URL scheme to do it from here.
            await model.start()
            #if DEBUG
            if let delay = model.composition.launch.simulateAfter {
                try? await Task.sleep(for: .seconds(delay))
                model.activateByKeyboard()
            }
            #endif
        }
    }

    /// Closes the microphone and the control channel at once; the sidecar is a child process that must get its
    /// shutdown request and its SIGTERM before the app exits, so quitting waits for `stop()` (a few seconds at most).
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = AppModel.shared
        model.shutdownImmediately()
        guard !terminating, let sidecar = model.composition.sidecar else { return .terminateNow }
        terminating = true
        Task { @MainActor in
            await sidecar.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
