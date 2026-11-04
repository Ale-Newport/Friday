// Portions adapted from Atticus (https://github.com/SaarthurR/atticus-mac), MIT License, Copyright (c) 2026 SaarthurR.
// See NOTICE-ATTICUS.md (`MiniScreen.windowTarget/open` for window lookup and raise; placement semantics follow the
// Python `place`, re-implemented natively with AX position/size).
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import FridayCore

/// Result of changing a window's frame: what was asked, what the app actually did.
public struct WindowChange: Sendable, Hashable {
    public var window: WindowInfo
    public var requested: ScreenRect?
    public var actual: ScreenRect
    /// Whether `actual` matches `requested` within a few points (apps enforce minimum sizes and snap to grids).
    public var matched: Bool

    public var json: JSONValue {
        var object: JSONObject = ["window": window.json, "frame": actual.json, "matched": .bool(matched)]
        if let requested { object["requested"] = requested.json }
        return .object(object)
    }
}

/// Lists, focuses, moves, resizes, arranges, minimises and closes windows of other applications.
///
/// Window-server queries need no permission; everything that changes a window goes through Accessibility and needs
/// ``ComputerPermissions/accessibility``. Frames use the top-left coordinate space (see ``ScreenRect``); multi-display
/// maths lives in ``WindowGeometry``.
public actor WindowManager {
    private let executor = SerialQueueExecutor(label: "com.newportdiaz.friday.computer.windows")
    public nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }

    public init() {}

    // MARK: Reading

    public func displays() async -> [DisplayInfo] { await Displays.current() }

    /// Windows of regular applications. Titles come from the window server (needs Screen Recording) or, when AX is
    /// trusted, from each app's AX windows matched by frame.
    public func windows(onScreenOnly: Bool = true) async -> [WindowInfo] {
        let apps = await Apps.running(regularOnly: true)
        let byPID = Dictionary(apps.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let displays = await Displays.current()
        let trusted = AXIsProcessTrusted()
        var axWindows: [Int32: [AXElement]] = [:]
        return CGWindows.list(onScreenOnly: onScreenOnly).compactMap { record in
            guard let app = byPID[record.pid], CGWindows.isRealWindow(record) else { return nil }
            var title = record.name ?? ""
            var minimized = false
            if trusted {
                if axWindows[record.pid] == nil { axWindows[record.pid] = AX.windows(of: AXElement.application(pid: record.pid)) }
                if let window = axWindows[record.pid]?.first(where: { ScreenRect(AX.frame($0)).matches(ScreenRect(record.bounds)) }) {
                    if title.isEmpty { title = AX.title(window) ?? AX.name(window) }
                    minimized = AX.bool(window, kAXMinimizedAttribute) ?? false
                }
            }
            return WindowInfo(
                id: record.id, pid: record.pid, appName: app.localizedName, bundleID: app.bundleID, title: Safety.mask(title),
                frame: ScreenRect(record.bounds), isOnScreen: record.isOnScreen,
                displayIndex: Displays.index(containing: record.bounds, in: displays), isMinimized: minimized)
        }
    }

    public func window(id: UInt32) async -> WindowInfo? {
        await windows(onScreenOnly: false).first { $0.id == id }
    }

    // MARK: Focus

    /// Running apps matching a name, bundle id or pid (exact first, then fuzzy). Empty when nothing matches.
    public func findApps(_ query: String) async -> [AppInfo] { await Apps.find(query) }

    /// Activates `pid` and waits until it is frontmost.
    public func activate(pid: Int32) async -> Bool { await Apps.activate(pid: pid) }

    /// Activates an app by bundle id or name and verifies it is frontmost. Several matches throw an
    /// `invalidArgument` listing them; none throws `notFound`.
    public func focus(app query: String) async throws -> AppInfo {
        let matches = await Apps.find(query)
        guard let app = matches.first else {
            throw JarvisError.notFound("app_not_running", en: "No running app matches “\(query)”.", es: "Ninguna app en ejecución coincide con «\(query)».")
        }
        guard matches.count == 1 else {
            throw JarvisError.invalidArgument(
                parameter: "app", LocalizedText(en: "Several apps match “\(query)”: " + matches.map(\.localizedName).joined(separator: ", "),
                    es: "Varias apps coinciden con «\(query)»: " + matches.map(\.localizedName).joined(separator: ", ")))
        }
        guard await Apps.activate(pid: app.pid) else {
            throw JarvisError.verificationFailed(LocalizedText(en: "\(app.localizedName) did not come to the front.", es: "\(app.localizedName) no pasó al frente."))
        }
        return app
    }

    /// Un-minimises, raises and focuses one window, then activates its app. Adapted from Atticus `MiniScreen.open`.
    public func focusWindow(id: UInt32) async throws -> WindowInfo {
        try requireTrust()
        let (window, element) = try await axWindow(id: id)
        if AX.bool(element, kAXMinimizedAttribute) == true { AX.set(element, kAXMinimizedAttribute, kCFBooleanFalse) }
        _ = AX.perform(element, ["AXRaise"])
        AX.set(element, kAXMainAttribute, kCFBooleanTrue)
        AX.set(element, kAXFocusedAttribute, kCFBooleanTrue)
        _ = await Apps.activate(pid: window.pid)
        usleep(100_000)
        _ = AX.perform(element, ["AXRaise"])
        let application = AXElement.application(pid: window.pid)
        let focusedNow = AX.element(application, kAXFocusedWindowAttribute).map { $0 == element } ?? false
        let frontmost = await Apps.frontmost()?.pid == window.pid
        guard frontmost, focusedNow || AX.bool(element, kAXMainAttribute) == true else {
            throw JarvisError.verificationFailed(LocalizedText(en: "The window did not become the focused window.", es: "La ventana no pasó a ser la ventana activa."))
        }
        return await refreshed(window, element: element)
    }

    // MARK: Geometry

    public func move(windowID: UInt32, to origin: CGPoint) async throws -> WindowChange {
        let (window, element) = try await axWindow(id: windowID)
        let frame = AX.frame(element)
        return try await apply(CGRect(origin: origin, size: frame.size), to: window, element: element)
    }

    public func resize(windowID: UInt32, to size: CGSize) async throws -> WindowChange {
        let (window, element) = try await axWindow(id: windowID)
        let frame = AX.frame(element)
        return try await apply(CGRect(origin: frame.origin, size: size), to: window, element: element)
    }

    public func setFrame(windowID: UInt32, frame: CGRect) async throws -> WindowChange {
        let (window, element) = try await axWindow(id: windowID)
        return try await apply(frame, to: window, element: element)
    }

    /// Arranges a window on `display` (its current one by default). `fullScreen` toggles the macOS full-screen Space.
    public func arrange(windowID: UInt32, preset: WindowPreset, display: Int? = nil) async throws -> WindowChange {
        let (window, element) = try await axWindow(id: windowID)
        let displays = await Displays.current()
        guard !displays.isEmpty else {
            throw JarvisError.unavailable(LocalizedText(en: "No display is connected.", es: "No hay ninguna pantalla conectada."))
        }
        let current = AX.frame(element)
        let target: DisplayInfo
        if let display {
            guard let found = displays.first(where: { $0.index == display }) else {
                throw JarvisError.invalidArgument(parameter: "display", LocalizedText(en: "There is no display \(display).", es: "No existe la pantalla \(display)."))
            }
            target = found
        } else {
            target = WindowGeometry.display(containing: current, in: displays) ?? displays[0]
        }
        if preset == .fullScreen {
            let before = AX.bool(element, "AXFullScreen") ?? false
            guard AX.isSettable(element, "AXFullScreen") else {
                throw JarvisError.unsupported(LocalizedText(en: "This window cannot enter full screen.", es: "Esta ventana no puede ponerse a pantalla completa."), alternative: nil)
            }
            AX.set(element, "AXFullScreen", before ? kCFBooleanFalse : kCFBooleanTrue)
            var now = before
            for _ in 0..<20 {
                usleep(100_000)
                now = AX.bool(element, "AXFullScreen") ?? before
                if now != before { break }
            }
            guard now != before else {
                throw JarvisError.verificationFailed(LocalizedText(en: "The window did not change its full-screen state.", es: "La ventana no cambió su estado de pantalla completa."))
            }
            let frame = ScreenRect(AX.frame(element))
            return WindowChange(window: await refreshed(window, element: element), requested: nil, actual: frame, matched: true)
        }
        if AX.bool(element, "AXFullScreen") == true {
            AX.set(element, "AXFullScreen", kCFBooleanFalse)
            for _ in 0..<20 where AX.bool(element, "AXFullScreen") == true { usleep(100_000) }
            usleep(300_000)
        }
        guard let frame = WindowGeometry.frame(for: preset, in: target.visibleFrame.cgRect, current: current) else {
            throw JarvisError.invalidArgument(parameter: "preset", LocalizedText(en: "Unknown preset.", es: "Disposición desconocida."))
        }
        return try await apply(frame, to: window, element: element)
    }

    public func moveToDisplay(windowID: UInt32, index: Int) async throws -> WindowChange {
        let (window, element) = try await axWindow(id: windowID)
        let displays = await Displays.current()
        guard let target = displays.first(where: { $0.index == index }) else {
            throw JarvisError.invalidArgument(parameter: "display", LocalizedText(en: "There is no display \(index).", es: "No existe la pantalla \(index)."))
        }
        let current = AX.frame(element)
        let source = WindowGeometry.display(containing: current, in: displays) ?? displays[0]
        let frame = WindowGeometry.frame(moving: current, from: source.visibleFrame.cgRect, to: target.visibleFrame.cgRect)
        return try await apply(frame, to: window, element: element)
    }

    public func minimize(windowID: UInt32) async throws -> WindowInfo {
        let (window, element) = try await axWindow(id: windowID)
        guard AX.isSettable(element, kAXMinimizedAttribute) else {
            throw JarvisError.unsupported(LocalizedText(en: "This window cannot be minimised.", es: "Esta ventana no se puede minimizar."), alternative: nil)
        }
        AX.set(element, kAXMinimizedAttribute, kCFBooleanTrue)
        var minimized = false
        for _ in 0..<20 {
            usleep(50_000)
            minimized = AX.bool(element, kAXMinimizedAttribute) ?? false
            if minimized { break }
        }
        guard minimized else {
            throw JarvisError.verificationFailed(LocalizedText(en: "The window did not minimise.", es: "La ventana no se minimizó."))
        }
        return await refreshed(window, element: element)
    }

    /// Presses the window's close button and verifies the window is gone (a "save changes?" sheet may keep it open).
    public func closeWindow(windowID: UInt32) async throws -> Bool {
        let (_, element) = try await axWindow(id: windowID)
        guard let button = AX.element(element, kAXCloseButtonAttribute), AX.perform(button, ["AXPress"]) else {
            throw JarvisError.unsupported(LocalizedText(en: "This window has no close button.", es: "Esta ventana no tiene botón de cerrar."), alternative: nil)
        }
        for _ in 0..<20 {
            usleep(100_000)
            if CGWindows.record(id: windowID) == nil { return true }
        }
        return CGWindows.record(id: windowID) == nil
    }

    // MARK: Internals

    /// Applies a frame the way apps accept it best: size, then position, then size again (adapted from Atticus's
    /// placement semantics), and reads the frame back.
    private func apply(_ frame: CGRect, to window: WindowInfo, element: AXElement) async throws -> WindowChange {
        try requireTrust()
        guard frame.width > 0, frame.height > 0, frame.origin.x.isFinite, frame.origin.y.isFinite else {
            throw JarvisError.invalidArgument(parameter: "frame", LocalizedText(en: "The frame must have a positive size.", es: "El marco debe tener un tamaño positivo."))
        }
        guard AX.isSettable(element, kAXPositionAttribute) || AX.isSettable(element, kAXSizeAttribute) else {
            throw JarvisError.unsupported(LocalizedText(en: "This window cannot be moved or resized.", es: "Esta ventana no se puede mover ni redimensionar."), alternative: nil)
        }
        let rounded = CGRect(x: frame.minX.rounded(), y: frame.minY.rounded(), width: frame.width.rounded(), height: frame.height.rounded())
        AX.set(element, kAXSizeAttribute, size: rounded.size)
        AX.set(element, kAXPositionAttribute, point: rounded.origin)
        AX.set(element, kAXSizeAttribute, size: rounded.size)
        var actual = AX.frame(element)
        for _ in 0..<10 where !ScreenRect(actual).matches(ScreenRect(rounded), tolerance: 2) {
            usleep(50_000)
            actual = AX.frame(element)
        }
        let matched = ScreenRect(actual).matches(ScreenRect(rounded), tolerance: 8)
        return WindowChange(window: await refreshed(window, element: element), requested: ScreenRect(rounded), actual: ScreenRect(actual), matched: matched)
    }

    private func refreshed(_ window: WindowInfo, element: AXElement) async -> WindowInfo {
        var copy = window
        let frame = AX.frame(element)
        copy.frame = ScreenRect(frame)
        copy.title = Safety.mask(AX.title(element) ?? AX.name(element))
        copy.isMinimized = AX.bool(element, kAXMinimizedAttribute) ?? false
        copy.displayIndex = Displays.index(containing: frame, in: await Displays.current())
        copy.isOnScreen = CGWindows.record(id: window.id)?.isOnScreen ?? copy.isOnScreen
        return copy
    }

    /// The AX window behind a window-server id: the app's AX window with the same frame (or, for a window that moved
    /// since, the same title). Adapted from Atticus `MiniScreen.windowTarget`/`open`.
    private func axWindow(id: UInt32) async throws -> (WindowInfo, AXElement) {
        try requireTrust()
        guard let record = CGWindows.record(id: id), let app = await Apps.info(pid: record.pid) else {
            throw JarvisError.notFound("window_not_found", en: "No window with id \(id) exists any more.", es: "Ya no existe ninguna ventana con id \(id).")
        }
        let application = AXElement.application(pid: record.pid)
        let windows = AX.windows(of: application)
        let byFrame = windows.filter { ScreenRect(AX.frame($0)).matches(ScreenRect(record.bounds)) }
        var element = byFrame.count == 1 ? byFrame.first : nil
        if element == nil, let name = record.name, !name.isEmpty {
            let byTitle = windows.filter { (AX.title($0) ?? AX.name($0)) == name }
            if byTitle.count == 1 { element = byTitle.first }
        }
        if element == nil, byFrame.count > 1 { element = byFrame.first }
        if element == nil, windows.count == 1, CGWindows.list(onScreenOnly: false).filter({ $0.pid == record.pid && CGWindows.isRealWindow($0) }).count == 1 {
            element = windows.first
        }
        guard let element else {
            throw JarvisError.notFound(
                "window_not_accessible", en: "\(app.localizedName) does not expose that window through Accessibility.",
                es: "\(app.localizedName) no expone esa ventana mediante Accesibilidad.")
        }
        let displays = await Displays.current()
        let info = WindowInfo(
            id: id, pid: record.pid, appName: app.localizedName, bundleID: app.bundleID,
            title: Safety.mask(record.name ?? AX.title(element) ?? AX.name(element)), frame: ScreenRect(record.bounds),
            isOnScreen: record.isOnScreen, displayIndex: Displays.index(containing: record.bounds, in: displays),
            isMinimized: AX.bool(element, kAXMinimizedAttribute) ?? false)
        return (info, element)
    }

    private func requireTrust() throws {
        guard AXIsProcessTrusted() else { throw JarvisError.permissionRequired(ComputerPermissions.accessibility) }
    }
}
