// Portions adapted from Atticus (https://github.com/SaarthurR/atticus-mac), MIT License, Copyright (c) 2026 SaarthurR.
// See NOTICE-ATTICUS.md (`--look` display capture excluding own windows, `--text` window OCR).
import AppKit
import CoreGraphics
import Foundation
import FridayCore
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import Vision

/// A JPEG screenshot plus the geometry needed to map pixels back to screen points.
public struct CapturedImage: Sendable {
    public var jpeg: Data
    /// Pixel size of the image.
    public var width: Int
    public var height: Int
    /// Screen points per image pixel (`origin.width / width`).
    public var scale: Double
    /// The screen area the image shows, in top-left screen points.
    public var origin: ScreenRect
    public var displayIndex: Int?
    public var windowID: UInt32?
    public var capturedAt: Date

    public init(jpeg: Data, width: Int, height: Int, scale: Double, origin: ScreenRect, displayIndex: Int?, windowID: UInt32?, capturedAt: Date = Date()) {
        self.jpeg = jpeg
        self.width = width
        self.height = height
        self.scale = scale
        self.origin = origin
        self.displayIndex = displayIndex
        self.windowID = windowID
        self.capturedAt = capturedAt
    }

    /// Converts a point inside the image (pixels) to screen points.
    public func screenPoint(x: Double, y: Double) -> CGPoint {
        CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
    }
}

/// One line of recognised text with its location in screen points.
public struct OCRLine: Codable, Sendable, Hashable {
    public var text: String
    public var confidence: Double
    public var frame: ScreenRect

    public init(text: String, confidence: Double, frame: ScreenRect) {
        self.text = text
        self.confidence = confidence
        self.frame = frame
    }

    public var json: JSONValue { ["text": .string(text), "confidence": .double((confidence * 100).rounded() / 100), "frame": frame.json] }
}

/// Everything a text-only model needs to answer "what is on my screen?", plus (on request) a screenshot path for
/// vision models.
public struct ScreenDescription: Sendable {
    public var app: AppInfo?
    public var windowTitle: String?
    /// The compact accessibility description (see ``UITree/describe(maxLines:)``), empty when AX is unavailable.
    public var uiText: String
    public var tree: UITree?
    public var ocrLines: [OCRLine]
    /// Whether OCR was run because the accessibility tree yielded little.
    public var usedOCR: Bool
    /// Set only when the caller asked for the screenshot to be saved.
    public var screenshotPath: String?
    /// Warnings worth showing the user (missing permissions, failed captures), in both languages.
    public var notes: [LocalizedText]
    /// The language ``text`` is written in.
    public var language: Language

    /// A single text block: header, UI description, OCR text, notes.
    public var text: String {
        var parts: [String] = []
        if let app {
            let window = windowTitle.map { language.pick(" · Window: “\($0)”", " · Ventana: «\($0)»") } ?? ""
            parts.append(language.pick("Front app: ", "App en primer plano: ") + app.localizedName + window)
        }
        if !uiText.isEmpty { parts.append(uiText) }
        if !ocrLines.isEmpty { parts.append(language.pick("Text on screen (OCR):\n", "Texto en pantalla (OCR):\n") + ocrLines.map(\.text).joined(separator: "\n")) }
        if !notes.isEmpty { parts.append(notes.map { $0.resolved(language) }.joined(separator: "\n")) }
        return parts.joined(separator: "\n\n")
    }

    /// The notes in the description's language.
    public var localizedNotes: [String] { notes.map { $0.resolved(language) } }

    public var json: JSONValue {
        var object: JSONObject = [
            "text": .string(text), "used_ocr": .bool(usedOCR), "ocr_lines": .array(ocrLines.map(\.json)),
            "notes": .array(notes.map { .string($0.en) }),
        ]
        if let app { object["app"] = app.json }
        if let windowTitle { object["window_title"] = .string(windowTitle) }
        if let screenshotPath { object["screenshot_path"] = .string(screenshotPath) }
        if let tree { object["ui"] = tree.json }
        return .object(object)
    }
}

/// Screenshots (ScreenCaptureKit), OCR (Vision) and a combined screen description.
///
/// Needs ``ComputerPermissions/screenRecording``; without it ``screenshot(display:window:maxWidth:excludeOwnWindows:)``
/// throws `JarvisError.permissionRequired`.
public actor ScreenCaptureService {
    public static let defaultDirectory = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/Friday/screenshots", isDirectory: true)
    /// Saved screenshots are working files, not an archive: only the newest `retainedScreenshots` that are younger
    /// than `screenshotMaxAge` survive the next save. A screenshot can show anything that was on screen.
    public static let retainedScreenshots = 20
    public static let screenshotMaxAge: TimeInterval = 24 * 60 * 60

    private let accessibility: AccessibilityService
    private let directory: URL

    public init(accessibility: AccessibilityService = AccessibilityService(), directory: URL = ScreenCaptureService.defaultDirectory) {
        self.accessibility = accessibility
        self.directory = directory
    }

    // MARK: Screenshot

    /// Captures one display (default: the main one) or one window as JPEG, at most `maxWidth` pixels wide. Friday's
    /// own windows are left out of display captures so a model sees the real screen, not the assistant's panels.
    public func screenshot(display: Int? = nil, window: UInt32? = nil, maxWidth: Int = 1_600, excludeOwnWindows: Bool = true) async throws -> CapturedImage {
        guard #available(macOS 14.0, *) else { throw Self.unsupported() }
        guard CGPreflightScreenCaptureAccess() else { throw JarvisError.permissionRequired(ComputerPermissions.screenRecording) }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: window == nil)
        } catch {
            throw JarvisError.failed("capture_failed", en: "Could not list the screen content: \(error.localizedDescription)", es: "No se pudo listar el contenido de la pantalla: \(error.localizedDescription)")
        }
        let ownBundle = Bundle.main.bundleIdentifier
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let mine = content.windows.filter { ($0.owningApplication?.processID == ownPID) || (ownBundle != nil && $0.owningApplication?.bundleIdentifier == ownBundle) }
        let width = max(200, min(maxWidth, 8_000))
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = false
        let image: CGImage
        let area: CGRect
        var displayIndex: Int?
        if let window {
            guard let target = content.windows.first(where: { $0.windowID == window }) else {
                throw JarvisError.notFound("window_not_found", en: "No window with id \(window) is available for capture.", es: "No hay ninguna ventana con id \(window) disponible para capturar.")
            }
            area = target.frame
            let pointWidth = max(1, area.width)
            let scale = Double(width) / pointWidth
            configuration.width = width
            configuration.height = max(1, Int((area.height * scale).rounded()))
            do {
                image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: configuration)
            } catch {
                throw JarvisError.failed("capture_failed", en: "The window capture failed: \(error.localizedDescription)", es: "La captura de la ventana falló: \(error.localizedDescription)")
            }
        } else {
            let displays = await Displays.current()
            let index = display ?? 0
            guard let info = displays.first(where: { $0.index == index }) else {
                throw JarvisError.invalidArgument(parameter: "display", LocalizedText(en: "There is no display \(index).", es: "No existe la pantalla \(index)."))
            }
            guard let target = content.displays.first(where: { $0.displayID == info.displayID }) ?? content.displays.first else {
                throw JarvisError.unavailable(LocalizedText(en: "No display is available for capture.", es: "No hay ninguna pantalla disponible para capturar."))
            }
            displayIndex = info.index
            area = info.frame.cgRect
            let scale = Double(width) / Double(max(1, target.width))
            configuration.width = min(width, target.width)
            configuration.height = max(1, Int((Double(target.height) * min(1, scale)).rounded()))
            do {
                image = try await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(display: target, excludingWindows: excludeOwnWindows ? mine : []), configuration: configuration)
            } catch {
                throw JarvisError.failed("capture_failed", en: "The screenshot failed: \(error.localizedDescription)", es: "La captura de pantalla falló: \(error.localizedDescription)")
            }
        }
        guard let jpeg = Self.jpegData(image, quality: 0.75) else {
            throw JarvisError.failed("encode_failed", en: "Could not encode the screenshot.", es: "No se pudo codificar la captura.")
        }
        return CapturedImage(
            jpeg: jpeg, width: image.width, height: image.height, scale: area.width / Double(max(1, image.width)), origin: ScreenRect(area),
            displayIndex: displayIndex, windowID: window)
    }

    /// Writes the JPEG into the screenshots directory (created owner-only), prunes older screenshots there (see
    /// ``retainedScreenshots`` / ``screenshotMaxAge``) and returns the new file's URL.
    public func saveJPEG(_ image: CapturedImage, to directory: URL? = nil, name: String? = nil) throws -> URL {
        let folder = directory ?? self.directory
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        } catch {
            throw JarvisError.failed("directory_failed", en: "Could not create the screenshots folder.", es: "No se pudo crear la carpeta de capturas.")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let fileName = name ?? "screenshot-\(formatter.string(from: image.capturedAt))-\(UUID().uuidString.prefix(8)).jpg"
        let url = folder.appendingPathComponent(fileName)
        do {
            try image.jpeg.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw JarvisError.failed("write_failed", en: "Could not save the screenshot.", es: "No se pudo guardar la captura.")
        }
        Self.pruneScreenshots(in: folder, keeping: url, now: Date())
        return url
    }

    /// Deletes the `.jpg` files in `folder` beyond the newest ``retainedScreenshots`` or older than
    /// ``screenshotMaxAge``; `keeping` (the file just written) always survives. Returns how many were removed.
    @discardableResult
    static func pruneScreenshots(
        in folder: URL, keeping: URL? = nil, now: Date, limit: Int = retainedScreenshots, maxAge: TimeInterval = screenshotMaxAge
    ) -> Int {
        let manager = FileManager.default
        guard
            let entries = try? manager.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        else { return 0 }
        let keep = keeping?.standardizedFileURL
        let dated = entries.filter { $0.pathExtension.lowercased() == "jpg" }.map { url -> (url: URL, date: Date) in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return (url, date)
        }.sorted { $0.date > $1.date }
        var removed = 0
        for (index, entry) in dated.enumerated() where entry.url.standardizedFileURL != keep {
            guard index >= limit || now.timeIntervalSince(entry.date) > maxAge else { continue }
            if (try? manager.removeItem(at: entry.url)) != nil { removed += 1 }
        }
        return removed
    }

    // MARK: OCR

    /// Recognises text (accurate, English and Spanish) and returns lines with frames in screen points.
    public func ocr(_ image: CapturedImage) async throws -> [OCRLine] {
        guard let source = CGImageSourceCreateWithData(image.jpeg as CFData, nil), let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw JarvisError.failed("decode_failed", en: "Could not decode the screenshot for OCR.", es: "No se pudo decodificar la captura para el OCR.")
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US", "es-ES"]
        request.usesLanguageCorrection = true
        do {
            try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        } catch {
            throw JarvisError.failed("ocr_failed", en: "Text recognition failed: \(error.localizedDescription)", es: "El reconocimiento de texto falló: \(error.localizedDescription)")
        }
        let observations = request.results ?? []
        return observations.compactMap { observation -> OCRLine? in
            guard let candidate = observation.topCandidates(1).first, !candidate.string.isEmpty else { return nil }
            let frame = Self.screenFrame(normalized: observation.boundingBox, in: image.origin)
            return OCRLine(text: Safety.mask(candidate.string), confidence: Double(candidate.confidence), frame: frame)
        }
    }

    /// Vision bounding boxes are normalised with a bottom-left origin; the screen uses top-left points.
    public static func screenFrame(normalized box: CGRect, in area: ScreenRect) -> ScreenRect {
        ScreenRect(
            x: area.x + box.minX * area.width, y: area.y + (1 - box.maxY) * area.height, width: box.width * area.width,
            height: box.height * area.height)
    }

    // MARK: Describe

    /// Front app, window title, the accessibility description and, when that yields little, OCR of a screenshot.
    /// Works with either permission alone: without Screen Recording it answers from Accessibility text and says
    /// so; without Accessibility it answers from OCR. The screenshot stays in memory unless `saveScreenshot` is
    /// set (then its path is returned for vision-capable models).
    public func describe(
        display: Int? = nil, maxLines: Int = 150, forceOCR: Bool = false, language: Language = .en, saveScreenshot: Bool = false
    ) async throws -> ScreenDescription {
        var notes: [LocalizedText] = []
        let app = try? await accessibility.frontmostApplication()
        var tree: UITree?
        var uiText = ""
        if AXIsProcessTrusted() {
            do {
                let captured = try await accessibility.capture(scope: .frontmostWindow, maxElements: 400)
                tree = captured
                uiText = captured.describe(maxLines: maxLines)
            } catch let error as JarvisError {
                notes.append(LocalizedText(en: "Accessibility: " + error.message(in: .en), es: "Accesibilidad: " + error.message(in: .es)))
            } catch {
                notes.append(LocalizedText(en: "Accessibility: \(error.localizedDescription)", es: "Accesibilidad: \(error.localizedDescription)"))
            }
        } else {
            notes.append(
                LocalizedText(
                    en: "Accessibility permission is not granted, so the controls of the front window could not be read. Grant it in System Settings › Privacy & Security › Accessibility.",
                    es: "El permiso de Accesibilidad no está concedido, así que no se pudieron leer los controles de la ventana en primer plano. Concédelo en Ajustes del Sistema › Privacidad y seguridad › Accesibilidad."))
        }
        var ocrLines: [OCRLine] = []
        var usedOCR = false
        var path: String?
        if CGPreflightScreenCaptureAccess() {
            do {
                let image = try await screenshot(display: display)
                if saveScreenshot { path = try saveJPEG(image).path }
                if forceOCR || tree.map({ !$0.isRich }) ?? true {
                    ocrLines = try await ocr(image)
                    usedOCR = true
                }
            } catch let error as JarvisError {
                notes.append(LocalizedText(en: "Screenshot: " + error.message(in: .en), es: "Captura: " + error.message(in: .es)))
            } catch {
                notes.append(LocalizedText(en: "Screenshot: \(error.localizedDescription)", es: "Captura: \(error.localizedDescription)"))
            }
        } else {
            notes.append(
                LocalizedText(
                    en: "Screen Recording is not granted, so this is based on Accessibility text only (no screenshot or OCR). Grant it in System Settings › Privacy & Security › Screen Recording to read text in images.",
                    es: "La grabación de pantalla no está concedida, así que esto se basa solo en el texto de Accesibilidad (sin captura ni OCR). Concédela en Ajustes del Sistema › Privacidad y seguridad › Grabación de pantalla para leer texto en imágenes."))
        }
        return ScreenDescription(
            app: app, windowTitle: tree?.window?.title, uiText: uiText, tree: tree, ocrLines: ocrLines, usedOCR: usedOCR,
            screenshotPath: path, notes: notes, language: language)
    }

    // MARK: Helpers

    static func jpegData(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    static func unsupported() -> JarvisError {
        JarvisError.unsupported(LocalizedText(en: "Screenshots need macOS 14 or later.", es: "Las capturas requieren macOS 14 o posterior."), alternative: nil)
    }
}
