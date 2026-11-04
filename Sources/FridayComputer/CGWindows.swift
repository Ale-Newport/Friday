// Portions adapted from Atticus (https://github.com/SaarthurR/atticus-mac), MIT License, Copyright (c) 2026 SaarthurR.
// Hands logic adapts ideas from Plip (https://github.com/hussainn7/plip-oss), MIT License, Copyright (c) 2026 Hussain.
// See NOTICE-ATTICUS.md (`MiniScreen.bounds/windowTarget`, `Hands.windowNumber/windowsAt/windowAt`, `systemUI`).
import AppKit
import CoreGraphics
import Foundation
import FridayCore

/// One record from the window server (`CGWindowListCopyWindowInfo`), as plain data.
struct CGWindowRecord: Sendable, Hashable {
    var id: UInt32
    var pid: Int32
    var layer: Int
    var bounds: CGRect
    /// `kCGWindowName`; macOS only fills it for other apps' windows when Screen Recording is granted.
    var name: String?
    var ownerName: String?
    var alpha: Double
    var isOnScreen: Bool
}

/// Window-server queries. No Accessibility permission needed; titles may be missing without Screen Recording.
enum CGWindows {
    /// Adapted from Atticus `MiniScreen.bounds`.
    static func bounds(_ info: [String: Any]) -> CGRect? {
        (info[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
    }

    static func list(onScreenOnly: Bool, includeDesktop: Bool = false) -> [CGWindowRecord] {
        var options: CGWindowListOption = onScreenOnly ? [.optionOnScreenOnly] : [.optionAll]
        if !includeDesktop { options.insert(.excludeDesktopElements) }
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return raw.compactMap { info in
            guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, let bounds = bounds(info)
            else { return nil }
            return CGWindowRecord(
                id: id, pid: pid, layer: (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0, bounds: bounds,
                name: info[kCGWindowName as String] as? String, ownerName: info[kCGWindowOwnerName as String] as? String,
                alpha: (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
                isOnScreen: (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? onScreenOnly)
        }
    }

    static func record(id: UInt32) -> CGWindowRecord? {
        guard let raw = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]], let info = raw.first,
            let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, let bounds = bounds(info)
        else { return nil }
        return CGWindowRecord(
            id: id, pid: pid, layer: (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0, bounds: bounds,
            name: info[kCGWindowName as String] as? String, ownerName: info[kCGWindowOwnerName as String] as? String,
            alpha: (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
            isOnScreen: (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false)
    }

    /// Real, user-visible windows of an app: normal layer, a sensible size (apps also own invisible full-width strips).
    static func isRealWindow(_ record: CGWindowRecord) -> Bool {
        record.layer == 0 && record.bounds.width > 1 && record.bounds.height > 1
            && (record.bounds.height > 40 || record.bounds.width < record.bounds.height * 10)
    }

    /// The window number of the one window of `pid` whose frame matches `frame` within two points (adapted from
    /// Atticus `Hands.windowNumber`, which falls back to this when the private AX window number is unavailable).
    static func windowNumber(pid: Int32, frame: CGRect) -> UInt32? {
        let matches = list(onScreenOnly: false).filter {
            $0.pid == pid && $0.layer == 0 && abs($0.bounds.minX - frame.minX) < 2 && abs($0.bounds.minY - frame.minY) < 2
                && abs($0.bounds.width - frame.width) < 2 && abs($0.bounds.height - frame.height) < 2
        }
        return matches.count == 1 ? matches[0].id : nil
    }

    /// Visible app windows (normal layer, not transparent) containing `point`, front to back (Atticus `windowsAt`).
    static func windowsAt(_ point: CGPoint) -> [CGWindowRecord] {
        list(onScreenOnly: true).filter { $0.layer == 0 && $0.alpha > 0 && $0.bounds.contains(point) }
    }

    /// The window of `pid` a click at `point` would reach (Atticus `windowAt`).
    static func windowAt(_ point: CGPoint, pid: Int32) -> UInt32? {
        windowsAt(point).first { $0.pid == pid }?.id
    }

    /// The windows in front of window `id` (for the visibility test).
    static func windowsAbove(_ id: UInt32) -> [CGRect] {
        let onScreen = list(onScreenOnly: true)
        guard let index = onScreen.firstIndex(where: { $0.id == id }) else { return [] }
        return onScreen.prefix(index).filter { $0.layer == 0 && $0.alpha > 0 }.map(\.bounds)
    }

    /// System UI currently on screen that is not an ordinary app window (menu-bar panels, Control Center, dialogs of
    /// background agents…), keyed by window number, with a short description. Adapted from Atticus `systemUI`.
    static func systemUI(ownPID: Int32 = ProcessInfo.processInfo.processIdentifier, displays: [DisplayInfo]) -> [UInt32: String] {
        var result: [UInt32: String] = [:]
        let dock = Int(CGWindowLevelForKey(.dockWindow))
        let mainMenu = Int(CGWindowLevelForKey(.mainMenuWindow))
        let status = Int(CGWindowLevelForKey(.statusWindow))
        for window in list(onScreenOnly: true) {
            guard window.layer >= 0, window.layer != dock, window.layer != mainMenu, window.pid != ownPID, window.alpha > 0,
                window.bounds.width > 1, window.bounds.height > 1, window.layer > 0,
                let display = displays.first(where: { $0.frame.cgRect.intersects(window.bounds) })
            else { continue }
            // Thin status strips cannot distinguish persistent menu extras from indicators.
            if window.layer == status, window.bounds.height <= 40, window.bounds.width > 100 { continue }
            result[window.id] =
                "\(window.ownerName ?? "System") \(Int(window.bounds.width))×\(Int(window.bounds.height)) on \(display.name)"
        }
        return result
    }
}

/// Running-application lookups. `NSWorkspace`/`NSRunningApplication` are used from the main actor only.
enum Apps {
    @MainActor
    static func info(_ app: NSRunningApplication) -> AppInfo {
        let name = app.executableURL?.deletingPathExtension().lastPathComponent ?? app.localizedName ?? app.bundleIdentifier ?? "app"
        return AppInfo(pid: app.processIdentifier, bundleID: app.bundleIdentifier, name: name, localizedName: app.localizedName ?? name)
    }

    @MainActor
    static func frontmost() -> AppInfo? {
        NSWorkspace.shared.frontmostApplication.map(info)
    }

    @MainActor
    static func info(pid: Int32) -> AppInfo? {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return nil }
        return info(app)
    }

    @MainActor
    static func running(regularOnly: Bool = true) -> [AppInfo] {
        NSWorkspace.shared.runningApplications.filter { !regularOnly || $0.activationPolicy == .regular }.map(info)
    }

    /// Exact bundle id, exact pid, exact (folded) name, else fuzzy name matches. Empty when nothing matches.
    @MainActor
    static func find(_ query: String) -> [AppInfo] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let apps = running(regularOnly: false)
        if let pid = Int32(trimmed), let app = apps.first(where: { $0.pid == pid }) { return [app] }
        let exactBundle = apps.filter { $0.bundleID?.lowercased() == trimmed.lowercased() }
        if !exactBundle.isEmpty { return exactBundle }
        let folded = Safety.normalized(trimmed)
        let exactName = apps.filter { Safety.normalized($0.localizedName) == folded || Safety.normalized($0.name) == folded }
        if !exactName.isEmpty { return exactName }
        let regular = apps.filter { $0.bundleID != nil }
        let ranked = NameMatcher.rank(regular, query: trimmed, minimumScore: 60) { $0.localizedName }
        guard let top = ranked.first?.score else { return [] }
        return ranked.filter { $0.score == top }.map(\.item)
    }

    /// Activates `pid` and waits (up to one second) until it is frontmost.
    @MainActor
    static func activate(pid: Int32) async -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return false }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { return true }
        app.unhide()
        _ = app.activate(options: [])
        for _ in 0..<20 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    static func isAlive(pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }
}

/// Display enumeration (AppKit `NSScreen`, main actor), converted to top-left coordinates.
enum Displays {
    @MainActor
    static func current() -> [DisplayInfo] {
        let screens = NSScreen.screens
        guard let main = screens.first else { return [] }
        let mainHeight = main.frame.height
        return screens.enumerated().map { index, screen in
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 ?? 0
            return DisplayInfo(
                index: index, displayID: id, name: screen.localizedName,
                frame: ScreenRect(WindowGeometry.topLeftRect(fromAppKit: screen.frame, mainDisplayHeight: mainHeight)),
                visibleFrame: ScreenRect(WindowGeometry.topLeftRect(fromAppKit: screen.visibleFrame, mainDisplayHeight: mainHeight)),
                scale: screen.backingScaleFactor, isMain: index == 0)
        }
    }

    static func index(containing rect: CGRect, in displays: [DisplayInfo]) -> Int? {
        WindowGeometry.display(containing: rect, in: displays)?.index
    }
}
