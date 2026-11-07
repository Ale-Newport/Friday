import AppKit
import CoreGraphics
import Foundation
import FridayCore
import Testing

@testable import FridayComputer

/// Integration tests against the real desktop. They run only when this process is trusted for Accessibility (the
/// `swift test` runner usually is not; grant it in System Settings › Privacy & Security › Accessibility to enable).
@Suite(.enabled(if: AXIsProcessTrusted(), "this process is not trusted for Accessibility; the live computer tests are skipped"), .serialized)
struct LiveAccessibilityTests {
    let integration = ComputerIntegration()

    /// The frontmost app may have no window at all (Finder on an empty desktop): that is a fact about the desktop,
    /// not a failure of the capture, so such runs skip instead of failing.
    private func frontmostTree() async throws -> UITree? {
        do {
            return try await integration.accessibility.capture(scope: .frontmostWindow, maxElements: 300)
        } catch let error as JarvisError {
            if case .notFound(let code, _) = error, code == "no_window" { return nil }
            throw error
        }
    }

    @Test func capturesTheFrontmostWindow() async throws {
        let app = try await integration.accessibility.frontmostApplication()
        #expect(app.pid > 0)
        guard let tree = try await frontmostTree() else { return }
        #expect(tree.app.pid == app.pid)
        #expect(tree.count > 0)
        let text = tree.describe(maxLines: 40)
        #expect(text.hasPrefix("App: "))
        #expect(await integration.accessibility.lastCapture()?.capturedAt == tree.capturedAt)
    }

    @Test func listsWindowsAndFocusedWindow() async throws {
        let windows = await integration.windows.windows(onScreenOnly: true)
        #expect(windows.allSatisfy { $0.id > 0 && $0.pid > 0 && !$0.appName.isEmpty })
        if let focused = try await integration.accessibility.focusedWindow() {
            #expect(focused.frame.width > 0)
        }
    }

    @Test func readsMenuBarItems() async throws {
        let items = try await integration.accessibility.menuBarItems(depth: 1)
        #expect(!items.isEmpty)
        #expect(items.contains { $0.title == "Apple" || $0.title.isEmpty == false })
    }

    @Test func executesReadOnlyToolsThroughTheRegistry() async throws {
        let registry = ToolRegistry(integrations: [integration])
        let frontmost = try await integration.execute(try registry.validate(ToolCall(tool: ComputerIntegration.frontmost)), context: executionContext())
        #expect(frontmost.output?.data?["app"]?["pid"]?.intValue ?? 0 > 0)
        guard try await frontmostTree() != nil else { return }
        let elements = try await integration.execute(try registry.validate(ToolCall(tool: ComputerIntegration.uiElements, arguments: ["max_lines": 30])), context: executionContext(language: .es))
        #expect(elements.output?.message.hasPrefix("App: ") == true)
        #expect(elements.output?.verification == .notApplicable)
    }
}

@Suite struct LiveDisplayTests {
    @Test func listsDisplaysWithoutPermissions() async {
        let displays = await WindowManager().displays()
        #expect(!displays.isEmpty)
        #expect(displays.first?.isMain == true)
        #expect(displays.first?.frame.x == 0 && displays.first?.frame.y == 0)
        for display in displays {
            #expect(display.visibleFrame.width <= display.frame.width && display.visibleFrame.height <= display.frame.height)
            #expect(display.frame.cgRect.contains(display.visibleFrame.cgRect))
        }
    }

    @Test func listsRunningAppsAndFindsThem() async {
        let integration = ComputerIntegration()
        let apps = await integration.windows.findApps("Finder")
        #expect(apps.contains { $0.bundleID == "com.apple.finder" })
        let byBundle = await integration.windows.findApps("com.apple.finder")
        #expect(byBundle.count == 1)
        let none = await integration.windows.findApps("no such application zzz")
        #expect(none.isEmpty)
    }

    @Test func frontmostNeverDescribesThisProcess() async throws {
        // The test runner is "Friday" here: whatever is reported in front must be another app.
        if let app = await Apps.frontmost() {
            #expect(app.pid != ProcessInfo.processInfo.processIdentifier)
        }
        if let other = await Apps.frontmostOtherApp() {
            #expect(other.pid != ProcessInfo.processInfo.processIdentifier)
        }
    }

    @Test func describeScreenWorksFromAccessibilityTextWithoutScreenRecording() async throws {
        // Whatever the permissions of this process, describe() must answer (never throw) and say what was missing.
        let service = ScreenCaptureService()
        let description = try await service.describe(display: 0, language: .es)
        #expect(description.language == .es)
        #expect(description.screenshotPath == nil, "nothing is saved unless asked")
        if !CGPreflightScreenCaptureAccess() {
            #expect(description.notes.contains { $0.es.contains("grabación de pantalla") })
            #expect(description.text.contains("Grabación de pantalla") || description.text.contains("grabación de pantalla"))
            #expect(description.ocrLines.isEmpty && !description.usedOCR)
        }
        if !AXIsProcessTrusted() {
            #expect(description.notes.contains { $0.en.contains("Accessibility") && $0.es.contains("Accesibilidad") })
        }
        for note in description.notes { #expect(!note.en.isEmpty && !note.es.isEmpty) }
        #expect(description.localizedNotes == description.notes.map(\.es))
    }
}

@Suite(.enabled(if: CGPreflightScreenCaptureAccess(), "Screen Recording is not granted to this process; screenshot tests are skipped"), .serialized)
struct LiveScreenTests {
    static let outputDirectory: URL = {
        if let override = ProcessInfo.processInfo.environment["FRIDAY_SCREENSHOT_OUT"] { return URL(fileURLWithPath: override, isDirectory: true) }
        return FileManager.default.temporaryDirectory.appendingPathComponent("friday-computer-tests/screenshots", isDirectory: true)
    }()

    @Test func takesAScreenshotAndRecognisesText() async throws {
        let service = ScreenCaptureService(directory: Self.outputDirectory)
        let image = try await service.screenshot(display: 0, maxWidth: 1600)
        #expect(image.width > 0 && image.width <= 1600)
        #expect(image.scale > 0)
        let url = try await service.saveJPEG(image, to: Self.outputDirectory, name: "live-test-display0.jpg")
        #expect(FileManager.default.fileExists(atPath: url.path))
        let lines = try await service.ocr(image)
        for line in lines {
            #expect(!line.text.isEmpty)
            #expect(line.frame.width > 0 && line.frame.height > 0)
            #expect(image.origin.cgRect.insetBy(dx: -1, dy: -1).contains(line.frame.cgRect))
        }
        let description = try await service.describe(display: 0)
        #expect(description.screenshotPath == nil, "describe keeps the screenshot in memory unless asked to save it")
        #expect(!description.text.isEmpty)
        #expect(description.text.hasPrefix("Front app: ") || description.text.hasPrefix("App: ") || !description.notes.isEmpty)
        let saved = try await service.describe(display: 0, language: .es, saveScreenshot: true)
        let path = try #require(saved.screenshotPath)
        #expect(path.hasPrefix(Self.outputDirectory.path))
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(saved.text.hasPrefix("App en primer plano: ") || !saved.notes.isEmpty)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}
