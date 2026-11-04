// Portions adapted from Atticus (https://github.com/SaarthurR/atticus-mac), MIT License, Copyright (c) 2026 SaarthurR.
// See NOTICE-ATTICUS.md (`MiniScreen.visible`, `MeetingFrame.clamp`; the window-placement semantics follow Atticus's
// Python `place`, re-implemented natively).
import CoreGraphics
import Foundation
import FridayCore

/// One display. Frames use the top-left (Core Graphics / Accessibility) convention, see ``ScreenRect``.
public struct DisplayInfo: Codable, Sendable, Hashable, Identifiable {
    /// 0-based index in `NSScreen.screens` order (0 is the display with the menu bar).
    public var index: Int
    public var displayID: UInt32
    public var name: String
    public var frame: ScreenRect
    /// The frame minus menu bar and Dock: where windows may be placed.
    public var visibleFrame: ScreenRect
    public var scale: Double
    public var isMain: Bool

    public var id: Int { index }

    public init(index: Int, displayID: UInt32, name: String, frame: ScreenRect, visibleFrame: ScreenRect, scale: Double, isMain: Bool) {
        self.index = index
        self.displayID = displayID
        self.name = name
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.scale = scale
        self.isMain = isMain
    }

    public var json: JSONValue {
        [
            "index": .int(index), "display_id": .int(Int(displayID)), "name": .string(name), "frame": frame.json,
            "visible_frame": visibleFrame.json, "scale": .double(scale), "is_main": .bool(isMain),
        ]
    }
}

/// One window of a running application (from the window server, enriched through Accessibility).
public struct WindowInfo: Codable, Sendable, Hashable, Identifiable {
    public var id: UInt32
    public var pid: Int32
    public var appName: String
    public var bundleID: String?
    public var title: String
    public var frame: ScreenRect
    public var isOnScreen: Bool
    public var displayIndex: Int?
    public var isMinimized: Bool

    public init(
        id: UInt32, pid: Int32, appName: String, bundleID: String?, title: String, frame: ScreenRect, isOnScreen: Bool,
        displayIndex: Int?, isMinimized: Bool = false
    ) {
        self.id = id
        self.pid = pid
        self.appName = appName
        self.bundleID = bundleID
        self.title = title
        self.frame = frame
        self.isOnScreen = isOnScreen
        self.displayIndex = displayIndex
        self.isMinimized = isMinimized
    }

    public var json: JSONValue {
        [
            "id": .int(Int(id)), "pid": .int(Int(pid)), "app": .string(appName), "bundle_id": JSONValue(bundleID),
            "title": .string(title), "frame": frame.json, "on_screen": .bool(isOnScreen), "display": JSONValue(displayIndex),
            "minimized": .bool(isMinimized),
        ]
    }
}

/// Where to put a window on a display.
public enum WindowPreset: String, Sendable, Hashable, Codable, CaseIterable {
    case leftHalf = "left_half"
    case rightHalf = "right_half"
    case topHalf = "top_half"
    case bottomHalf = "bottom_half"
    case maximize
    case center
    /// Toggles the macOS full-screen Space (`AXFullScreen`), not a frame.
    case fullScreen = "full_screen"
    case topLeft = "top_left"
    case topRight = "top_right"
    case bottomLeft = "bottom_left"
    case bottomRight = "bottom_right"
    case leftThird = "left_third"
    case middleThird = "middle_third"
    case rightThird = "right_third"
    case leftTwoThirds = "left_two_thirds"
    case rightTwoThirds = "right_two_thirds"

    /// Accepts `left_half`, `left-half`, `left half`, `mitad izquierda`, `maximizar`, `centrar`, `pantalla completa`…
    public init?(name: String) {
        let folded = TextFolding.fold(name).replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        if let exact = WindowPreset.allCases.first(where: { $0.rawValue.replacingOccurrences(of: "_", with: " ") == folded }) {
            self = exact
            return
        }
        let aliases: [String: WindowPreset] = [
            "left": .leftHalf, "right": .rightHalf, "top": .topHalf, "bottom": .bottomHalf, "half left": .leftHalf,
            "izquierda": .leftHalf, "mitad izquierda": .leftHalf, "derecha": .rightHalf, "mitad derecha": .rightHalf,
            "arriba": .topHalf, "mitad superior": .topHalf, "abajo": .bottomHalf, "mitad inferior": .bottomHalf,
            "maximise": .maximize, "maximizar": .maximize, "max": .maximize, "full": .maximize, "fill": .maximize,
            "centre": .center, "centrar": .center, "centro": .center, "centered": .center,
            "fullscreen": .fullScreen, "pantalla completa": .fullScreen, "full screen": .fullScreen,
            "top left quarter": .topLeft, "top right quarter": .topRight, "bottom left quarter": .bottomLeft,
            "bottom right quarter": .bottomRight, "superior izquierda": .topLeft, "superior derecha": .topRight,
            "inferior izquierda": .bottomLeft, "inferior derecha": .bottomRight,
            "tercio izquierdo": .leftThird, "tercio central": .middleThird, "center third": .middleThird,
            "tercio derecho": .rightThird, "dos tercios izquierda": .leftTwoThirds, "dos tercios derecha": .rightTwoThirds,
        ]
        guard let preset = aliases[folded] else { return nil }
        self = preset
    }
}

/// Pure window-placement maths and coordinate conversion. Everything is testable without a display.
///
/// AppKit describes screens with a bottom-left origin: the main display's bottom-left corner is (0,0) and y grows
/// upwards. Core Graphics, the window server and Accessibility use a top-left origin: the main display's top-left
/// corner is (0,0) and y grows downwards. Converting one into the other only needs the main display's height.
public enum WindowGeometry {
    /// AppKit (bottom-left) → Core Graphics / AX (top-left).
    public static func topLeftRect(fromAppKit rect: CGRect, mainDisplayHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: mainDisplayHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Core Graphics / AX (top-left) → AppKit (bottom-left).
    public static func appKitRect(fromTopLeft rect: CGRect, mainDisplayHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: mainDisplayHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The target frame for `preset` inside a display's visible frame (top-left coordinates). `current` is the
    /// window's present frame, used by `center` (keeps the size). Returns `nil` for `fullScreen`, which is not a frame.
    public static func frame(for preset: WindowPreset, in visible: CGRect, current: CGRect? = nil) -> CGRect? {
        let v = visible
        let halfW = (v.width / 2).rounded(.down)
        let halfH = (v.height / 2).rounded(.down)
        let thirdW = (v.width / 3).rounded(.down)
        switch preset {
        case .leftHalf: return CGRect(x: v.minX, y: v.minY, width: halfW, height: v.height)
        case .rightHalf: return CGRect(x: v.minX + halfW, y: v.minY, width: v.width - halfW, height: v.height)
        case .topHalf: return CGRect(x: v.minX, y: v.minY, width: v.width, height: halfH)
        case .bottomHalf: return CGRect(x: v.minX, y: v.minY + halfH, width: v.width, height: v.height - halfH)
        case .maximize: return v
        case .center:
            let size = CGSize(
                width: min(current?.width ?? v.width * 0.7, v.width), height: min(current?.height ?? v.height * 0.7, v.height))
            return CGRect(
                x: (v.minX + (v.width - size.width) / 2).rounded(), y: (v.minY + (v.height - size.height) / 2).rounded(),
                width: size.width, height: size.height)
        case .fullScreen: return nil
        case .topLeft: return CGRect(x: v.minX, y: v.minY, width: halfW, height: halfH)
        case .topRight: return CGRect(x: v.minX + halfW, y: v.minY, width: v.width - halfW, height: halfH)
        case .bottomLeft: return CGRect(x: v.minX, y: v.minY + halfH, width: halfW, height: v.height - halfH)
        case .bottomRight: return CGRect(x: v.minX + halfW, y: v.minY + halfH, width: v.width - halfW, height: v.height - halfH)
        case .leftThird: return CGRect(x: v.minX, y: v.minY, width: thirdW, height: v.height)
        case .middleThird: return CGRect(x: v.minX + thirdW, y: v.minY, width: thirdW, height: v.height)
        case .rightThird: return CGRect(x: v.minX + 2 * thirdW, y: v.minY, width: v.width - 2 * thirdW, height: v.height)
        case .leftTwoThirds: return CGRect(x: v.minX, y: v.minY, width: 2 * thirdW, height: v.height)
        case .rightTwoThirds: return CGRect(x: v.minX + thirdW, y: v.minY, width: v.width - thirdW, height: v.height)
        }
    }

    /// The display showing most of `rect`: the one containing its centre, else the largest overlap, else the main one.
    public static func display(containing rect: CGRect, in displays: [DisplayInfo]) -> DisplayInfo? {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        if let hit = displays.first(where: { $0.frame.cgRect.contains(centre) }) { return hit }
        let overlaps = displays.map { display -> (DisplayInfo, CGFloat) in
            let intersection = display.frame.cgRect.intersection(rect)
            return (display, intersection.isNull ? 0 : intersection.width * intersection.height)
        }
        if let best = overlaps.max(by: { $0.1 < $1.1 }), best.1 > 0 { return best.0 }
        return displays.first(where: \.isMain) ?? displays.first
    }

    /// Keeps `frame` inside `bounds`, shrinking it when it is larger (adapted from Atticus `MeetingFrame.clamp`).
    public static func clamp(_ frame: CGRect, to bounds: CGRect) -> CGRect {
        var result = frame
        result.size.width = min(result.width, bounds.width)
        result.size.height = min(result.height, bounds.height)
        result.origin.x = min(max(result.minX, bounds.minX), bounds.maxX - result.width)
        result.origin.y = min(max(result.minY, bounds.minY), bounds.maxY - result.height)
        return result
    }

    /// Moves `frame` from the visible area `source` to `target`, keeping its relative position and its size (clamped).
    public static func frame(moving frame: CGRect, from source: CGRect, to target: CGRect) -> CGRect {
        let relativeX = source.width > 0 ? (frame.minX - source.minX) / source.width : 0
        let relativeY = source.height > 0 ? (frame.minY - source.minY) / source.height : 0
        let moved = CGRect(
            x: (target.minX + relativeX * target.width).rounded(), y: (target.minY + relativeY * target.height).rounded(),
            width: frame.width, height: frame.height)
        return clamp(moved, to: target)
    }

    /// Adapted from Atticus `MiniScreen.visible`: a window counts as visible when at least 90 % of it lies on a display
    /// and at most 10 % is covered by the windows in front of it.
    public static func isVisible(_ rect: CGRect, displays: [CGRect], above: [CGRect]) -> Bool {
        func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }
        guard area(rect) > 0 else { return false }
        let shown = displays.reduce(CGFloat(0)) { $0 + area($1.intersection(rect)) }
        let covered = above.reduce(CGFloat(0)) { $0 + area($1.intersection(rect)) }
        return shown >= area(rect) * 0.9 && covered <= area(rect) * 0.1
    }
}
