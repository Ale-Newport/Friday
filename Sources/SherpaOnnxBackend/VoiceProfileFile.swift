import Foundation
import WakeWordKit

/// The file in which the engine keeps what it has learned about a person's voice: `jarvis_pronunciations.txt` in the user's models
/// folder, one sequence of sounds per line. It is an ordinary text file the person can read, edit or delete; deleting it goes back to
/// the engine's own list. Nothing is ever overwritten: whatever was there is kept next to it first.
public enum VoiceProfileFile {
    /// The first line of the files the learning writes, so that a later run can tell its own output from a list written by hand.
    static let marker = "# Pronunciations of “Jarvis” learned from your voice"

    /// The text of a profile holding `pronunciations`.
    public static func text(pronunciations: [String], phrases: Int, sensitivity: Float, date: Date = Date()) -> String {
        let day = Self.dayFormatter.string(from: date)
        return marker + " — one sequence of sounds per line.\n"
            + "# \(phrases) phrases, sensitivity \(String(format: "%.2f", sensitivity)), learned \(day). Delete this file to go back to the built-in list.\n"
            + pronunciations.joined(separator: "\n") + "\n"
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private struct WriteFailure: LocalizedError {
        let errorDescription: String?
    }

    /// The first name `file` can be kept under without replacing an earlier copy: `….previous`, `….previous-2`, `….previous-3`…
    private static func backupURL(for file: URL) throws -> URL {
        var number = 1
        var copy = file.appendingPathExtension("previous")
        while FileManager.default.fileExists(atPath: copy.path) {
            number += 1
            guard number <= 99 else { throw WriteFailure(errorDescription: "ninety-nine earlier copies are already kept next to it; remove some") }
            copy = file.appendingPathExtension("previous-\(number)")
        }
        return copy
    }

    /// Writes `text` to `file` and keeps whatever was there: it is copied to `file.previous` — or `.previous-2`, `-3`…, because an earlier
    /// copy is never overwritten and a list written by hand survives any number of lessons — and the new text then replaces the file
    /// atomically, so a failed write leaves the old one in place. Returns the name the old file was kept under, if there was one.
    @discardableResult
    public static func write(_ text: String, replacing file: URL) throws -> String? {
        var isDirectory: ObjCBool = false
        var kept: String?
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory) {
            guard !isDirectory.boolValue else { throw WriteFailure(errorDescription: "that is a folder; it takes the name of a file") }
            let copy = try backupURL(for: file)
            try FileManager.default.copyItem(at: file, to: copy)
            kept = copy.lastPathComponent
        }
        try text.write(to: file, atomically: true, encoding: .utf8)
        return kept
    }

    /// Takes the profile out of use without deleting it: it is moved to `file.previous` (or the next free name). Nil if there is none.
    @discardableResult
    public static func setAside(_ file: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let copy = try backupURL(for: file)
        try FileManager.default.moveItem(at: file, to: copy)
        return copy.lastPathComponent
    }

    /// Undoes a ``write``, given the name it returned: the file goes back to what it held before — the copy kept under `previous`, which stays
    /// where it is — or, when there was nothing before (or the copy is gone), goes out of use. The profile being given up is kept aside, as
    /// ever: nothing is deleted.
    public static func revert(_ file: URL, restoring previous: String?) throws {
        let folder = file.deletingLastPathComponent()
        if let previous, !previous.isEmpty, !previous.contains("/"), previous != "..", previous != "." {
            let backup = folder.appendingPathComponent(previous)
            if FileManager.default.fileExists(atPath: backup.path) {
                // Copied beside the file first, so that a failure leaves the profile that is in force exactly as it was.
                let staged = folder.appendingPathComponent(".\(file.lastPathComponent).restoring-\(UUID().uuidString)")
                try FileManager.default.copyItem(at: backup, to: staged)
                defer { try? FileManager.default.removeItem(at: staged) }
                try setAside(file)
                try FileManager.default.moveItem(at: staged, to: file)
                return
            }
        }
        try setAside(file)
    }

    /// What the file holds, for the person to read; nil if there is no file (or it cannot be read at all).
    public static func describe(_ file: URL) -> VoiceProfile? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        // (Never more than the limit is read: this runs when the app starts, whatever the file is.)
        let data: Data? = {
            guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
            defer { try? handle.close() }
            return try? handle.read(upToCount: PronunciationLimits.fileBytes + 1)
        }()
        guard let data, data.count <= PronunciationLimits.fileBytes, let text = String(data: data, encoding: .utf8) else {
            return VoiceProfile(summary: "A pronunciation file that can’t be read")
        }
        let lines = text.components(separatedBy: .newlines)
        let count = lines.filter { line in
            !(line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map { $0.allSatisfy(\.isWhitespace) } ?? true)
        }.count
        let ways = count == 1 ? "1 way" : "\(count) ways"
        guard lines.first?.hasPrefix(marker) == true else {
            return VoiceProfile(summary: "A pronunciation file of your own (\(ways) of saying it)")
        }
        var learnedAt: Date?
        if let match = lines.dropFirst().first?.firstMatch(of: /learned (\d{4}-\d{2}-\d{2})/) {
            learnedAt = dayFormatter.date(from: String(match.1))
        }
        let when = learnedAt.map { ", learned on " + $0.formatted(.dateTime.day().month(.wide).year()) } ?? ""
        return VoiceProfile(summary: "\(ways) of saying it\(when)", learnedAt: learnedAt)
    }
}
