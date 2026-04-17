import AVFoundation
import Foundation

/// Represents a single recording session directory.
struct Session: Identifiable, Equatable {
    let id: String  // directory path
    let path: URL
    let name: String
    let isUntitled: Bool
    let date: Date
    let formattedDate: String
    let duration: String
    let snippet: String
    /// Raw language code stored in `meta.json` (e.g. `"en"`, `"he"`, `"auto"`).
    /// `nil` when the session hasn't been transcribed yet.
    let language: String?
    /// Pipeline artifacts present on disk. Drives the sidebar status icons.
    let hasAudio: Bool
    let hasTranscript: Bool
    let hasSummary: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }
}

/// Detailed data for a selected session.
struct SessionDetail {
    let name: String
    let notes: String
    let date: String
    let duration: String
    let transcript: String
    let summary: String
    let canTranscribe: Bool
    let canSummarize: Bool
    let audioURL: URL?
    /// Per-session language override, or `nil` to fall back to the global default.
    let language: String?
}

// MARK: - Session Manager

enum SessionManager {
    /// List session dirs sorted most-recent first.
    static func listSessions(sessionsDir: String) -> [Session] {
        let dir = URL(fileURLWithPath: (sessionsDir as NSString).expandingTildeInPath)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey],
            options: .skipsHiddenFiles,
        ) else { return [] }

        return contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { creationDate(of: $0) > creationDate(of: $1) }
            .map(sessionRow)
    }

    /// Create a new session directory.
    static func newSession(sessionsDir: String) -> URL {
        let dir = URL(fileURLWithPath: (sessionsDir as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let name = formatter.string(from: Date())
        var path = dir.appendingPathComponent(name)
        var suffix = 0
        while FileManager.default.fileExists(atPath: path.path) {
            suffix += 1
            path = dir.appendingPathComponent("\(name)-\(suffix)")
        }
        try? FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }

    static func sessionRow(_ dir: URL) -> Session {
        let meta = readMeta(dir)
        let rawName = meta["name"] as? String ?? ""
        let displayName = rawName.isEmpty ? dir.lastPathComponent : rawName
        let creationDate = creationDate(of: dir)
        let fileManager = FileManager.default
        let hasTranscript = fileManager.fileExists(
            atPath: dir.appendingPathComponent("transcript.txt").path,
        )
        let hasSummary = fileManager.fileExists(
            atPath: dir.appendingPathComponent("summary.md").path,
        )

        return Session(
            id: dir.path,
            path: dir,
            name: displayName,
            isUntitled: rawName.isEmpty,
            date: creationDate,
            formattedDate: dateFormatter.string(from: creationDate),
            duration: audioDuration(dir),
            snippet: snippet(dir),
            language: meta["language"] as? String,
            hasAudio: audioURL(in: dir) != nil,
            hasTranscript: hasTranscript,
            hasSummary: hasSummary,
        )
    }

    static func sessionDetail(_ dir: URL) -> SessionDetail {
        let meta = readMeta(dir)
        let txPath = dir.appendingPathComponent("transcript.txt")
        let smPath = dir.appendingPathComponent("summary.md")
        let audio = audioURL(in: dir)

        return SessionDetail(
            name: meta["name"] as? String ?? "",
            notes: meta["notes"] as? String ?? "",
            date: dateFormatter.string(from: creationDate(of: dir)),
            duration: audioDuration(dir),
            transcript: (try? String(contentsOf: txPath, encoding: .utf8)) ?? "",
            summary: (try? String(contentsOf: smPath, encoding: .utf8)) ?? "",
            canTranscribe: audio != nil,
            canSummarize: FileManager.default.fileExists(atPath: txPath.path),
            audioURL: audio,
            language: meta["language"] as? String,
        )
    }

    // MARK: - Meta

    static func readMeta(_ dir: URL) -> [String: Any] {
        let path = dir.appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return json
    }

    static func writeMeta(_ dir: URL, _ data: [String: Any]) {
        let path = dir.appendingPathComponent("meta.json")
        guard let jsonData = try? JSONSerialization.data(
            withJSONObject: data, options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? jsonData.write(to: path, options: .atomic)
    }

    static func setName(_ dir: URL, _ name: String) {
        var data = readMeta(dir)
        data["name"] = name
        writeMeta(dir, data)
    }

    static func setNotes(_ dir: URL, _ notes: String) {
        var data = readMeta(dir)
        data["notes"] = notes
        writeMeta(dir, data)
    }

    static func setLanguage(_ dir: URL, _ language: String?) {
        var data = readMeta(dir)
        if let language, !language.isEmpty {
            data["language"] = language
        } else {
            data.removeValue(forKey: "language")
        }
        writeMeta(dir, data)
    }

    static func displayName(_ dir: URL) -> String {
        let name = readMeta(dir)["name"] as? String ?? ""
        return name.isEmpty ? dir.lastPathComponent : name
    }

    // MARK: - Destructive operations

    /// Move a session directory to the Trash. Returns `true` on success.
    @discardableResult
    static func deleteSession(_ dir: URL) -> Bool {
        (try? FileManager.default.trashItem(at: dir, resultingItemURL: nil)) != nil
    }

    // MARK: - Helpers

    private static let dateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d, yyyy HH:mm"
        return fmt
    }()

    private static func creationDate(of dir: URL) -> Date {
        (try? dir.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
    }

    /// Locate the audio file in a session directory (M4A preferred, WAV fallback).
    static func audioURL(in dir: URL) -> URL? {
        ["audio.m4a", "audio.wav"]
            .lazy
            .map(dir.appendingPathComponent)
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Audio duration using AVAudioFile — works for any Core Audio format.
    private static func audioDuration(_ dir: URL) -> String {
        guard let url = audioURL(in: dir),
              let file = try? AVAudioFile(forReading: url) else { return "—" }
        let seconds = Int(Double(file.length) / file.fileFormat.sampleRate)
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }

    private static func snippet(_ dir: URL) -> String {
        let summaryPath = dir.appendingPathComponent("summary.md")
        if let text = try? String(contentsOf: summaryPath, encoding: .utf8),
           let first = firstNonEmptyLine(text) {
            return String(first.prefix(120))
        }
        let transcriptPath = dir.appendingPathComponent("transcript.txt")
        if let text = try? String(contentsOf: transcriptPath, encoding: .utf8) {
            // Prefer the parsed shape so special tokens and `[MM:SS]` headers
            // don't leak into the sidebar. Fall back to sanitized raw text for
            // transcripts that don't match the speaker-line format.
            if let firstLine = TranscriptFormatter.parse(text).first, !firstLine.text.isEmpty {
                return String(firstLine.text.prefix(120))
            }
            if let first = firstNonEmptyLine(text) {
                return String(TranscriptFormatter.sanitize(first).prefix(120))
            }
        }
        return ""
    }

    private static func firstNonEmptyLine(_ text: String) -> String? {
        text.components(separatedBy: .newlines)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }
}
