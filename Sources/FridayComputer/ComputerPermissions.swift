// Portions adapted from Atticus (https://github.com/SaarthurR/atticus-mac), MIT License, Copyright (c) 2026 SaarthurR.
// See NOTICE-ATTICUS.md.
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import FridayCore

/// Current state of one macOS privacy permission, read without prompting.
public enum PermissionState: Sendable, Hashable {
    case granted
    /// Not granted. macOS does not tell apart "never asked" from "denied" for Accessibility and Screen Recording;
    /// the caller remembers whether it already prompted.
    case notDetermined
    case denied
}

/// Automation (Apple Events) consent for one target application.
public enum AutomationState: Sendable, Hashable {
    case granted
    case notDetermined
    case denied
    /// The target is not running, so macOS cannot answer without launching it.
    case targetNotRunning
}

/// Accessibility, Screen Recording and Automation permission helpers plus the matching System Settings deep links.
///
/// `accessibilityStatus`/`screenRecordingStatus`/`automationStatus` never prompt. The `request…` functions show the
/// system prompt once; after that only System Settings can change the answer, which ``openSettings(pane:)`` opens.
/// Adapted from Atticus `Onboarding.perms/grant/settings/pane` and `Apps.check/statuses`.
public enum ComputerPermissions {
    public enum SettingsPane: String, Sendable, Hashable, CaseIterable {
        case accessibility = "Accessibility"
        case screenCapture = "ScreenCapture"
        case microphone = "Microphone"
        case speechRecognition = "SpeechRecognition"
        case automation = "Automation"
        case reminders = "Reminders"
        case calendars = "Calendars"
        case contacts = "Contacts"
        case notifications = "Notifications"

        /// The `x-apple.systempreferences:` URL that opens this pane.
        public var url: String {
            switch self {
            case .notifications: return "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
            default: return "x-apple.systempreferences:com.apple.preference.security?Privacy_" + rawValue
            }
        }
    }

    // MARK: Requirements shown to the user

    public static let accessibility = PermissionRequirement(
        id: "macos.accessibility",
        title: LocalizedText(en: "Accessibility", es: "Accesibilidad"),
        rationale: LocalizedText(
            en: "Friday reads the controls of the app in front, clicks, types and arranges windows through macOS Accessibility. Nothing is recorded; only the current window is inspected when you ask.",
            es: "Friday lee los controles de la app en primer plano, hace clic, escribe y organiza ventanas mediante Accesibilidad de macOS. No graba nada; solo inspecciona la ventana actual cuando lo pides."),
        settingsURL: SettingsPane.accessibility.url)

    public static let screenRecording = PermissionRequirement(
        id: "macos.screen_recording",
        title: LocalizedText(en: "Screen Recording", es: "Grabación de pantalla"),
        rationale: LocalizedText(
            en: "Screen Recording lets Friday take a screenshot and read the text on screen when you ask what is on your screen. Images stay on this Mac unless you send them to a vision model.",
            es: "La grabación de pantalla permite a Friday hacer una captura y leer el texto en pantalla cuando preguntas qué hay en ella. Las imágenes se quedan en este Mac salvo que las envíes a un modelo con visión."),
        settingsURL: SettingsPane.screenCapture.url)

    public static let systemEventsAutomation = PermissionRequirement(
        id: "automation.com.apple.systemevents",
        title: LocalizedText(en: "Control “System Events”", es: "Controlar «System Events»"),
        rationale: LocalizedText(
            en: "Switching between light and dark appearance uses System Events, which needs Automation consent.",
            es: "Cambiar entre apariencia clara y oscura usa System Events, que requiere permiso de Automatización."),
        settingsURL: SettingsPane.automation.url)

    // MARK: Accessibility

    public static func accessibilityStatus() -> PermissionState {
        AXIsProcessTrusted() ? .granted : .notDetermined
    }

    /// Shows the system Accessibility prompt (once per process; later calls are no-ops for macOS) and returns the
    /// current trust state.
    @discardableResult
    public static func requestAccessibility() -> Bool {
        // The constant `kAXTrustedCheckOptionPrompt` is imported as a mutable global; its value is this literal.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: Screen Recording

    public static func screenRecordingStatus() -> PermissionState {
        CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
    }

    /// Shows the system Screen Recording prompt the first time and returns whether access is granted. macOS applies a
    /// freshly granted Screen Recording permission only after the app is relaunched.
    @discardableResult
    public static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    // MARK: Automation (adapted from Atticus `Apps.check`)

    static func automationCheck(bundleID: String, ask: Bool) -> OSStatus {
        var descriptor = AEAddressDesc()
        _ = bundleID.withCString { AECreateDesc(typeApplicationBundleID, $0, bundleID.utf8.count, &descriptor) }
        defer { AEDisposeDesc(&descriptor) }
        return AEDeterminePermissionToAutomateTarget(&descriptor, typeWildCard, typeWildCard, ask)
    }

    static func automationState(from status: OSStatus) -> AutomationState {
        switch Int(status) {
        case Int(noErr): return .granted
        case -1743: return .denied  // errAEEventNotPermitted
        case -1744: return .notDetermined  // errAEEventWouldRequireUserConsent
        case -600: return .targetNotRunning  // procNotFound
        default: return .denied
        }
    }

    /// Automation consent for `bundleID` without prompting. A frozen target can stall the answer, so the probe is
    /// capped at 1.5 seconds (treated as not determined).
    public static func automationStatus(bundleID: String) async -> AutomationState {
        await withTimeout(seconds: 1.5, fallback: .notDetermined) {
            automationState(from: automationCheck(bundleID: bundleID, ask: false))
        }
    }

    /// Shows the Automation consent dialog for `bundleID` (launching nothing) and waits for the answer.
    public static func requestAutomation(bundleID: String) async -> AutomationState {
        await withTimeout(seconds: 120, fallback: .notDetermined) {
            automationState(from: automationCheck(bundleID: bundleID, ask: true))
        }
    }

    private static func withTimeout<T: Sendable>(
        seconds: Double, fallback: T, _ work: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            let gate = ContinuationGate<T>(continuation)
            DispatchQueue.global(qos: .userInitiated).async { gate.finish(work()) }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) { gate.finish(fallback) }
        }
    }

    // MARK: System Settings

    /// Opens the System Settings pane for `pane`. Must run on the main actor (NSWorkspace).
    @MainActor
    @discardableResult
    public static func openSettings(pane: SettingsPane) -> Bool {
        guard let url = URL(string: pane.url) else { return false }
        return NSWorkspace.shared.open(url)
    }

    /// Every permission this module can need, read without prompting.
    public static func snapshot() -> [String: PermissionState] {
        ["accessibility": accessibilityStatus(), "screen_recording": screenRecordingStatus()]
    }
}

/// Resumes a continuation at most once, whichever of several racing completions arrives first.
final class ContinuationGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) { self.continuation = continuation }

    func finish(_ value: T) {
        let pending: CheckedContinuation<T, Never>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}
