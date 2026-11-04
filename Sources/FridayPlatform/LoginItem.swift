import Foundation
import ServiceManagement

public enum LoginItemStatus: Equatable, Sendable {
    case enabled
    case notRegistered
    /// Registered but the user has not approved it in System Settings ▸ General ▸ Login Items.
    case requiresApproval
    /// The system cannot find the app (typically: running from a build folder rather than /Applications).
    case unavailable
}

/// "Start at login", backed by the system. The system — not our preferences — is the source of
/// truth: the user can switch it off in System Settings at any time.
public protocol LoginItemManaging: Sendable {
    var status: LoginItemStatus { get }
    func setEnabled(_ enabled: Bool) throws
    func openSystemSettings()
}

public struct MainAppLoginItem: LoginItemManaging {
    public init() {}

    public var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .notRegistered: .notRegistered
        case .requiresApproval: .requiresApproval
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            guard SMAppService.mainApp.status != .enabled else { return }
            try SMAppService.mainApp.register()
        } else {
            guard SMAppService.mainApp.status != .notRegistered else { return }
            try SMAppService.mainApp.unregister()
        }
    }

    public func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
