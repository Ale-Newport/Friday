import CoreGraphics
import Foundation
import Testing

@testable import FridayComputer

@Suite struct GeometryTests {
    /// Main display 1440×900 with a taller 1920×1080 display to its right, bottoms aligned (AppKit coordinates).
    static let mainHeight: CGFloat = 900
    static let main = DisplayInfo(
        index: 0, displayID: 1, name: "Built-in", frame: ScreenRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: ScreenRect(x: 0, y: 25, width: 1440, height: 875), scale: 2, isMain: true)
    static let external = DisplayInfo(
        index: 1, displayID: 2, name: "External", frame: ScreenRect(x: 1440, y: -180, width: 1920, height: 1080),
        visibleFrame: ScreenRect(x: 1440, y: -155, width: 1920, height: 1055), scale: 1, isMain: false)

    @Test func convertsAppKitToTopLeft() {
        let appKit = CGRect(x: 100, y: 100, width: 400, height: 300)
        let topLeft = WindowGeometry.topLeftRect(fromAppKit: appKit, mainDisplayHeight: Self.mainHeight)
        #expect(topLeft == CGRect(x: 100, y: 500, width: 400, height: 300))
        #expect(WindowGeometry.appKitRect(fromTopLeft: topLeft, mainDisplayHeight: Self.mainHeight) == appKit)
    }

    @Test func convertsSecondaryDisplayFrames() {
        // AppKit: the external display's bottom edge is at y = 0, its top at y = 1080.
        let appKitExternal = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let topLeft = WindowGeometry.topLeftRect(fromAppKit: appKitExternal, mainDisplayHeight: Self.mainHeight)
        #expect(topLeft == CGRect(x: 1440, y: -180, width: 1920, height: 1080))
        // A display above the main one: AppKit y = 900…1800 maps to top-left y = -900…0.
        let above = WindowGeometry.topLeftRect(fromAppKit: CGRect(x: 0, y: 900, width: 1440, height: 900), mainDisplayHeight: Self.mainHeight)
        #expect(above == CGRect(x: 0, y: -900, width: 1440, height: 900))
        // The AppKit visible frame of the main display (Dock at the bottom, menu bar on top).
        let visible = WindowGeometry.topLeftRect(fromAppKit: CGRect(x: 0, y: 70, width: 1440, height: 805), mainDisplayHeight: Self.mainHeight)
        #expect(visible == CGRect(x: 0, y: 25, width: 1440, height: 805))
    }

    @Test func computesPresetFrames() {
        let visible = Self.main.visibleFrame.cgRect
        #expect(WindowGeometry.frame(for: .leftHalf, in: visible) == CGRect(x: 0, y: 25, width: 720, height: 875))
        #expect(WindowGeometry.frame(for: .rightHalf, in: visible) == CGRect(x: 720, y: 25, width: 720, height: 875))
        #expect(WindowGeometry.frame(for: .topHalf, in: visible) == CGRect(x: 0, y: 25, width: 1440, height: 437))
        #expect(WindowGeometry.frame(for: .bottomHalf, in: visible) == CGRect(x: 0, y: 462, width: 1440, height: 438))
        #expect(WindowGeometry.frame(for: .maximize, in: visible) == visible)
        #expect(WindowGeometry.frame(for: .topLeft, in: visible) == CGRect(x: 0, y: 25, width: 720, height: 437))
        #expect(WindowGeometry.frame(for: .bottomRight, in: visible) == CGRect(x: 720, y: 462, width: 720, height: 438))
        #expect(WindowGeometry.frame(for: .leftThird, in: visible) == CGRect(x: 0, y: 25, width: 480, height: 875))
        #expect(WindowGeometry.frame(for: .middleThird, in: visible) == CGRect(x: 480, y: 25, width: 480, height: 875))
        #expect(WindowGeometry.frame(for: .rightThird, in: visible) == CGRect(x: 960, y: 25, width: 480, height: 875))
        #expect(WindowGeometry.frame(for: .leftTwoThirds, in: visible) == CGRect(x: 0, y: 25, width: 960, height: 875))
        #expect(WindowGeometry.frame(for: .rightTwoThirds, in: visible) == CGRect(x: 480, y: 25, width: 960, height: 875))
        #expect(WindowGeometry.frame(for: .fullScreen, in: visible) == nil)
    }

    @Test func centersKeepingTheCurrentSize() {
        let visible = Self.main.visibleFrame.cgRect
        let centered = WindowGeometry.frame(for: .center, in: visible, current: CGRect(x: 10, y: 30, width: 800, height: 600))
        #expect(centered == CGRect(x: 320, y: 163, width: 800, height: 600))
        // A window larger than the display is shrunk to fit.
        let huge = WindowGeometry.frame(for: .center, in: visible, current: CGRect(x: 0, y: 0, width: 3000, height: 2000))
        #expect(huge == visible)
    }

    @Test func presetsOnTheSecondaryDisplayUseItsVisibleFrame() {
        let visible = Self.external.visibleFrame.cgRect
        #expect(WindowGeometry.frame(for: .rightHalf, in: visible) == CGRect(x: 2400, y: -155, width: 960, height: 1055))
        #expect(WindowGeometry.frame(for: .topHalf, in: visible) == CGRect(x: 1440, y: -155, width: 1920, height: 527))
    }

    @Test func findsTheDisplayShowingAWindow() {
        let displays = [Self.main, Self.external]
        #expect(WindowGeometry.display(containing: CGRect(x: 100, y: 100, width: 400, height: 300), in: displays)?.index == 0)
        #expect(WindowGeometry.display(containing: CGRect(x: 2000, y: 0, width: 400, height: 300), in: displays)?.index == 1)
        // Straddling: the centre decides.
        #expect(WindowGeometry.display(containing: CGRect(x: 1300, y: 100, width: 400, height: 300), in: displays)?.index == 1)
        // Off every display: the main one.
        #expect(WindowGeometry.display(containing: CGRect(x: 9000, y: 9000, width: 10, height: 10), in: displays)?.index == 0)
    }

    @Test func movesBetweenDisplaysKeepingRelativePosition() {
        let moved = WindowGeometry.frame(moving: CGRect(x: 0, y: 25, width: 720, height: 875), from: Self.main.visibleFrame.cgRect, to: Self.external.visibleFrame.cgRect)
        #expect(moved.origin == CGPoint(x: 1440, y: -155))
        #expect(moved.size == CGSize(width: 720, height: 875))
        let shrunk = WindowGeometry.frame(moving: CGRect(x: 1440, y: -155, width: 1920, height: 1055), from: Self.external.visibleFrame.cgRect, to: Self.main.visibleFrame.cgRect)
        #expect(shrunk == Self.main.visibleFrame.cgRect)
    }

    @Test func clampsIntoBounds() {
        let bounds = CGRect(x: 0, y: 25, width: 1440, height: 875)
        #expect(WindowGeometry.clamp(CGRect(x: 1200, y: 800, width: 400, height: 300), to: bounds) == CGRect(x: 1040, y: 600, width: 400, height: 300))
        #expect(WindowGeometry.clamp(CGRect(x: -50, y: -50, width: 400, height: 300), to: bounds) == CGRect(x: 0, y: 25, width: 400, height: 300))
    }

    @Test func visibilityNeedsNinetyPercentOnScreenAndTenPercentUncovered() {
        let displays = [CGRect(x: 0, y: 0, width: 1440, height: 900)]
        let window = CGRect(x: 100, y: 100, width: 400, height: 300)
        #expect(WindowGeometry.isVisible(window, displays: displays, above: []))
        #expect(!WindowGeometry.isVisible(window, displays: displays, above: [CGRect(x: 100, y: 100, width: 400, height: 100)]))
        #expect(!WindowGeometry.isVisible(CGRect(x: 1300, y: 100, width: 400, height: 300), displays: displays, above: []))
        #expect(!WindowGeometry.isVisible(.zero, displays: displays, above: []))
    }

    @Test(arguments: [
        ("left_half", WindowPreset.leftHalf), ("left half", .leftHalf), ("left-half", .leftHalf), ("mitad izquierda", .leftHalf), ("Right Half", .rightHalf),
        ("maximize", .maximize), ("maximizar", .maximize), ("center", .center), ("centrar", .center), ("full_screen", .fullScreen),
        ("pantalla completa", .fullScreen), ("top_left", .topLeft), ("inferior derecha", .bottomRight), ("tercio central", .middleThird),
    ])
    func parsesPresetNames(name: String, preset: WindowPreset) {
        #expect(WindowPreset(name: name) == preset)
    }

    @Test func screenRectMatching() {
        let a = ScreenRect(x: 0, y: 25, width: 720, height: 875)
        #expect(a.matches(ScreenRect(x: 1, y: 26, width: 719, height: 876)))
        #expect(!a.matches(ScreenRect(x: 10, y: 25, width: 720, height: 875)))
        #expect(a.center == CGPoint(x: 360, y: 462.5))
        #expect(a.description == "(0,25 720×875)")
    }

    @Test func mapsOCRBoxesToScreenPoints() {
        let area = ScreenRect(x: 1440, y: -180, width: 1920, height: 1080)
        // Vision: bottom-left origin, normalised. A box at the top-left corner of the image.
        let frame = ScreenCaptureService.screenFrame(normalized: CGRect(x: 0, y: 0.9, width: 0.5, height: 0.1), in: area)
        #expect(abs(frame.x - 1440) < 0.001)
        #expect(abs(frame.y - (-180)) < 0.001)
        #expect(abs(frame.width - 960) < 0.001)
        #expect(abs(frame.height - 108) < 0.001)
        let image = CapturedImage(jpeg: Data(), width: 1600, height: 900, scale: 1920.0 / 1600.0, origin: area, displayIndex: 1, windowID: nil)
        #expect(image.screenPoint(x: 800, y: 450) == CGPoint(x: 1440 + 960, y: -180 + 540))
    }
}
