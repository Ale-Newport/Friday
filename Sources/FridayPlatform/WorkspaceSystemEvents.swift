import AppKit
import Foundation
import WakeWordCore
import WakeWordKit

/// Sleep/wake, fast-user-switching and app-activation notifications, as ``SystemEvent``s.
/// Purely event-driven: nothing here polls.
public final class WorkspaceSystemEvents: SystemEventSource, @unchecked Sendable {
    private let broadcaster = Broadcaster<SystemEvent>()
    private let tokens: Protected<[(center: NotificationCenter, token: NSObjectProtocol)]> = Protected([])

    /// - Parameters:
    ///   - workspaceCenter: where NSWorkspace posts power and session notifications.
    ///   - applicationCenter: where the application posts activation notifications.
    public init(
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        applicationCenter: NotificationCenter = .default
    ) {
        let mapping: [(NotificationCenter, Notification.Name, SystemEvent)] = [
            (workspaceCenter, NSWorkspace.willSleepNotification, .willSleep),
            (workspaceCenter, NSWorkspace.didWakeNotification, .didWake),
            (workspaceCenter, NSWorkspace.sessionDidResignActiveNotification, .userSessionDidResignActive),
            (workspaceCenter, NSWorkspace.sessionDidBecomeActiveNotification, .userSessionDidBecomeActive),
            (applicationCenter, NSApplication.didBecomeActiveNotification, .applicationDidBecomeActive),
        ]
        let broadcaster = self.broadcaster
        let registered = mapping.map { center, name, event in
            (center, center.addObserver(forName: name, object: nil, queue: nil) { _ in broadcaster.send(event) })
        }
        tokens.withLock { $0 = registered }
    }

    deinit {
        for (center, token) in tokens.get() { center.removeObserver(token) }
    }

    public func events() -> AsyncStream<SystemEvent> { broadcaster.stream() }
}
