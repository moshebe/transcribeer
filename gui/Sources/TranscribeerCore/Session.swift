import AVFoundation
import Foundation

public struct Session: Identifiable, Equatable, Sendable {
    public let id: String  // directory path
    public let path: URL
    public let name: String
    public let isUntitled: Bool
    public let date: Date
    public let formattedDate: String
    public let duration: String
    public let snippet: String

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }
}

public struct SessionDetail: Sendable {
    public let name: String
    public let notes: String
    public let date: String
    public let duration: String
    public let transcript: String
    public let summary: String
    public let canTranscribe: Bool
    public let canSummarize: Bool
    public let audioURL: URL?
}

// MARK: - Session Manager

public enum SessionManager {
    /// List session dirs sorted most-recent first.
    public static func listSessions(sessionsDir: String) -> [Session] {
        let dir = URL(fileURLWithPath: (sessionsDir as NSString).expandingTildeInPath)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles
        ) else { return [] }

        return contents
            .filter { url in
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                return isDir.boolValue
            }
            .sorted { a, b in
                let aDate = (try? a.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                let bDate = (try? b.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                return aDate > bDate
            }
            .map { sessionRow($0) }
    }

    /// Create a new session directory.
    public static func newSession(sessionsDir: String) -> URL {
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

    public static func sessionRow(_ dir: URL) -> Session {
        let meta = readMeta(dir)
        let rawName = meta["name"] as? String ?? ""
        let displayName = rawName.isEmpty ? dir.lastPathComponent : rawName

        let creationDate: Date
        if let vals = try? dir.resourceValues(forKeys: [.creationDateKey]),
           let d = vals.creationDate {
            creationDate = d
        } else {
            creationDate = .distantPast
        }

        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d, yyyy HH:mm"

        return Session(
            id: dir.path,
            path: dir,
            name: displayName,
            isUntitled: rawName.isEmpty,
            date: creationDate,
            formattedDate: fmt.string(from: creationDate),
            duration: audioDuration(dir),
            snippet: snippet(dir)
        )
    }

    public static func sessionDetail(_ dir: URL) -> SessionDetail {
        let meta = readMeta(dir)
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d, yyyy HH:mm"
        let creationDate: Date
        if let vals = try? dir.resourceValues(forKeys: [.creationDateKey]),
           let d = vals.creationDate {
            creationDate = d
        } else {
            creationDate = .distantPast
        }

        let txPath = dir.appendingPathComponent("transcript.txt")
        let smPath = dir.appendingPathComponent("summary.md")
        let audioPath = dir.appendingPathComponent("audio.m4a")

        let hasAudio = FileManager.default.fileExists(atPath: audioPath.path)

        return SessionDetail(
            name: meta["name"] as? String ?? "",
            notes: meta["notes"] as? String ?? "",
            date: fmt.string(from: creationDate),
            duration: audioDuration(dir),
            transcript: (try? String(contentsOf: txPath, encoding: .utf8)) ?? "",
            summary: (try? String(contentsOf: smPath, encoding: .utf8)) ?? "",
            canTranscribe: hasAudio,
            canSummarize: FileManager.default.fileExists(atPath: txPath.path),
            audioURL: hasAudio ? audioPath : nil
        )
    }

    // MARK: - Meta

    public static func readMeta(_ dir: URL) -> [String: Any] {
        let path = dir.appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return json
    }

    public static func writeMeta(_ dir: URL, _ data: [String: Any]) {
        let path = dir.appendingPathComponent("meta.json")
        guard let jsonData = try? JSONSerialization.data(
            withJSONObject: data, options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? jsonData.write(to: path, options: .atomic)
    }

    public static func setName(_ dir: URL, _ name: String) {
        var data = readMeta(dir)
        data["name"] = name
        writeMeta(dir, data)
    }

    public static func setNotes(_ dir: URL, _ notes: String) {
        var data = readMeta(dir)
        data["notes"] = notes
        writeMeta(dir, data)
    }

    public static func displayName(_ dir: URL) -> String {
        let name = readMeta(dir)["name"] as? String ?? ""
        return name.isEmpty ? dir.lastPathComponent : name
    }

    // MARK: - Helpers

    public static func audioDuration(_ dir: URL) -> String {
        let path = dir.appendingPathComponent("audio.m4a")
        guard FileManager.default.fileExists(atPath: path.path) else { return "—" }
        // Use AVAudioFile for a synchronous, non-deprecated duration read.
        // The async `AVURLAsset.load(.duration)` API cannot be used here as
        // this function is non-async.
        guard let file = try? AVAudioFile(forReading: path) else { return "—" }
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0 else { return "—" }
        let seconds = Int(Double(file.length) / sampleRate)
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }

    private static func snippet(_ dir: URL) -> String {
        for fname in ["summary.md", "transcript.txt"] {
            let path = dir.appendingPathComponent(fname)
            guard let text = try? String(contentsOf: path, encoding: .utf8) else { continue }
            for line in text.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    return String(trimmed.prefix(120))
                }
            }
        }
        return ""
    }
}
