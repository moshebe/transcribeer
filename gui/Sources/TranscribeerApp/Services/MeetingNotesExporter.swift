import Foundation
import os.log

private let logger = Logger(subsystem: "com.transcribeer", category: "meeting-notes-export")

/// Mirrors a session's summary and transcript into a user folder as
/// `YYYY-MM-DD-<name>-summary.md` / `-transcript.md` with YAML frontmatter,
/// so tools outside the app (an Obsidian vault, a notes repo) can pick them up.
///
/// Each file carries a `transcribeer_session` key. Re-exporting a session
/// first removes the files carrying its key, so renames and re-summaries
/// replace the old notes instead of piling up.
enum MeetingNotesExporter {
    enum ExportError: LocalizedError {
        case folderMissing(String)

        var errorDescription: String? {
            switch self {
            case let .folderMissing(path): "Export folder not found: \(path)"
            }
        }
    }

    static let sessionKey = "transcribeer_session"

    /// Export when enabled in `config`. Returns a line for the session's
    /// `run.log`, or `nil` when export is off. Never throws: export is a side
    /// effect, not a pipeline step.
    static func exportIfEnabled(session: URL, config: AppConfig) -> String? {
        let integ = config.integrations
        guard integ.exportFolderEnabled, !integ.exportFolderPath.isEmpty else { return nil }
        let folder = URL(fileURLWithPath: (integ.exportFolderPath as NSString).expandingTildeInPath)
        do {
            let written = try export(session: session, to: folder)
            return "export: wrote " + written.map(\.lastPathComponent).joined(separator: ", ")
        } catch {
            logger.error("export failed: \(error.localizedDescription, privacy: .public)")
            return "export failed: \(error.localizedDescription)"
        }
    }

    @discardableResult
    static func export(session: URL, to folder: URL) throws -> [URL] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
            throw ExportError.folderMissing(folder.path)
        }

        let sessionID = session.lastPathComponent
        let title = SessionManager.displayName(session)
        let date = sessionDate(sessionID)
        let timePart = sessionID.hasPrefix(date) ? String(sessionID.dropFirst(date.count + 1)) : sessionID
        let base = "\(date)-\(slug(title, fallback: "meeting-\(timePart)"))"
        let meta = SessionManager.readMeta(session)
        let language = meta["detected_language"] as? String ?? meta["language"] as? String
        let header = Header(title: title, date: date, language: language, sessionID: sessionID)

        try removePreviousExports(of: sessionID, in: folder)

        let summary = nonEmptyContents(of: session.appendingPathComponent("summary.md"))
        let transcript = nonEmptyContents(of: session.appendingPathComponent("transcript.txt"))
        let transcriptName = "\(base)-transcript.md"

        var written: [URL] = []
        if let summary {
            let note = frontmatter(
                header,
                suffix: "summary",
                extra: transcript == nil ? [] : ["transcript: \(transcriptName)"]
            ) + "\n# \(title) - Summary\n\n" + summary
            let dest = folder.appendingPathComponent("\(base)-summary.md")
            try note.write(to: dest, atomically: true, encoding: .utf8)
            written.append(dest)
        }
        if let transcript {
            let note = frontmatter(header, suffix: "transcript") + "\n# \(title) - Transcript\n\n" + transcript
            let dest = folder.appendingPathComponent(transcriptName)
            try note.write(to: dest, atomically: true, encoding: .utf8)
            written.append(dest)
        }
        return written
    }

    // MARK: - Helpers

    struct Header {
        let title: String
        let date: String
        let language: String?
        let sessionID: String
    }

    static func frontmatter(_ header: Header, suffix: String, extra: [String] = []) -> String {
        var lines = [
            "---",
            "title: \(yamlQuoted("\(header.title) - \(suffix)"))",
            "date: \(header.date)",
            "source: transcribeer",
        ]
        if let language = header.language, !language.isEmpty, language != "auto" {
            lines.append("language: \(language)")
        }
        lines += extra
        lines += ["\(sessionKey): \(header.sessionID)", "---", ""]
        return lines.joined(separator: "\n")
    }

    private static func nonEmptyContents(of url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return text
    }

    /// Session folders are named `YYYY-MM-DD-HHMM[-n]`; fall back to today.
    static func sessionDate(_ sessionID: String) -> String {
        let prefix = String(sessionID.prefix(10))
        if prefix.wholeMatch(of: #/\d{4}-\d{2}-\d{2}/#) != nil { return prefix }
        return Date().formatted(.iso8601.year().month().day())
    }

    /// Lowercase ASCII words joined by `-`. Names with no ASCII letters
    /// (e.g. Hebrew titles) use `fallback` so the filename stays stable.
    static func slug(_ title: String, fallback: String) -> String {
        let words = title.lowercased()
            .components(separatedBy: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789").inverted)
            .filter { !$0.isEmpty }
        let slug = words.joined(separator: "-")
        return slug.isEmpty ? fallback : String(slug.prefix(60))
    }

    private static func yamlQuoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Only files whose frontmatter names this exact session are removed.
    private static func removePreviousExports(of sessionID: String, in folder: URL) throws {
        let marker = "\(sessionKey): \(sessionID)"
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "md" {
            guard let head = try? String(contentsOf: file, encoding: .utf8).prefix(1024),
                  head.hasPrefix("---"),
                  head.split(separator: "\n").contains(where: { $0 == marker })
            else { continue }
            try FileManager.default.removeItem(at: file)
        }
    }
}
