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
    /// Wall-clock time the user started recording (written by PipelineRunner
    /// when live-recording). `nil` for imported sessions and pre-existing
    /// sessions recorded before this field was tracked.
    let startedAt: Date?
    /// Wall-clock time the recording finished successfully. `nil` in the
    /// same cases as `startedAt` and also while a recording is still in
    /// progress.
    let endedAt: Date?
}

/// A single meeting participant observed during a recording session.
///
/// Persisted as one entry in `meta.json`'s `participants` array. The flags
/// reflect whether the participant was **ever** seen with that role during
/// the meeting — they are OR-ed across observations, never cleared.
struct SessionParticipant: Equatable, Sendable {
    let name: String
    let firstSeenAt: Date
    let lastSeenAt: Date
    let isMe: Bool
    let isHost: Bool
    let isCoHost: Bool
    let isGuest: Bool

    /// Build a new participant observed right now. Convenience for the
    /// recorder — both timestamps collapse to `observedAt`.
    init(
        name: String,
        observedAt: Date,
        isMe: Bool = false,
        isHost: Bool = false,
        isCoHost: Bool = false,
        isGuest: Bool = false,
    ) {
        self.init(
            name: name,
            firstSeenAt: observedAt,
            lastSeenAt: observedAt,
            isMe: isMe,
            isHost: isHost,
            isCoHost: isCoHost,
            isGuest: isGuest,
        )
    }

    init(
        name: String,
        firstSeenAt: Date,
        lastSeenAt: Date,
        isMe: Bool,
        isHost: Bool,
        isCoHost: Bool,
        isGuest: Bool,
    ) {
        self.name = name
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.isMe = isMe
        self.isHost = isHost
        self.isCoHost = isCoHost
        self.isGuest = isGuest
    }

    /// Merge a newer observation into this record:
    /// - keep the earlier `firstSeenAt`,
    /// - take the later `lastSeenAt`,
    /// - OR-accumulate role flags (host/guest/me/co-host never "downgrade").
    func merged(with observation: Self) -> Self {
        Self(
            name: name,
            firstSeenAt: min(firstSeenAt, observation.firstSeenAt),
            lastSeenAt: max(lastSeenAt, observation.lastSeenAt),
            isMe: isMe || observation.isMe,
            isHost: isHost || observation.isHost,
            isCoHost: isCoHost || observation.isCoHost,
            isGuest: isGuest || observation.isGuest,
        )
    }

    // MARK: - meta.json (de)serialization

    init?(dict: [String: Any]) {
        guard let name = dict["name"] as? String, !name.isEmpty else { return nil }
        let formatter = SessionManager.isoFormatter
        let firstSeen = (dict["firstSeenAt"] as? String).flatMap(formatter.date(from:))
        let lastSeen = (dict["lastSeenAt"] as? String).flatMap(formatter.date(from:))
        // A participant without timestamps isn't useful for history ordering
        // — skip it rather than silently fabricating `.distantPast`.
        guard let firstSeen, let lastSeen else { return nil }
        self.init(
            name: name,
            firstSeenAt: firstSeen,
            lastSeenAt: lastSeen,
            isMe: dict["isMe"] as? Bool ?? false,
            isHost: dict["isHost"] as? Bool ?? false,
            isCoHost: dict["isCoHost"] as? Bool ?? false,
            isGuest: dict["isGuest"] as? Bool ?? false,
        )
    }

    func dict(using formatter: ISO8601DateFormatter) -> [String: Any] {
        [
            "name": name,
            "firstSeenAt": formatter.string(from: firstSeenAt),
            "lastSeenAt": formatter.string(from: lastSeenAt),
            "isMe": isMe,
            "isHost": isHost,
            "isCoHost": isCoHost,
            "isGuest": isGuest,
        ]
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
    /// Meeting participants observed while this session was being recorded,
    /// in the order they were first seen. Empty when no Zoom meeting was
    /// associated, the participants panel stayed closed, or the meeting
    /// exceeded the `maxMeetingParticipants` threshold.
    let participants: [SessionParticipant]
}

// MARK: - Session Manager

enum SessionManager {
    /// List session dirs sorted most-recent first.
    ///
    /// Ordering uses each session's logical start time (`Session.date`), which
    /// prefers the `startedAt` wall-clock written during recording and falls
    /// back to the directory's filesystem creation date for imported or
    /// legacy sessions. This keeps split sessions adjacent to their originals
    /// instead of jumping to the top of the list.
    static func listSessions(sessionsDir: String) -> [Session] {
        let dir = URL(fileURLWithPath: (sessionsDir as NSString).expandingTildeInPath)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey],
            options: .skipsHiddenFiles,
        ) else { return [] }

        return contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map(sessionRow)
            .sorted { $0.date > $1.date }
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
        let startedAt = parseDate(meta["startedAt"])
        // Prefer the recorded wall-clock start over the directory's creation
        // date so sessions created by `SessionSplitter` (and any future
        // back-dated flows) sort next to their originals. Falls back to the
        // filesystem creation date for imports and pre-`startedAt` sessions.
        let sortDate = startedAt ?? creationDate(of: dir)
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
            date: sortDate,
            formattedDate: dateFormatter.string(from: sortDate),
            duration: audioDuration(dir),
            snippet: snippet(dir),
            language: meta["language"] as? String,
            hasAudio: audioURL(in: dir) != nil,
            hasTranscript: hasTranscript,
            hasSummary: hasSummary,
            startedAt: startedAt,
            endedAt: parseDate(meta["endedAt"]),
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
            date: dateFormatter.string(from: parseDate(meta["startedAt"]) ?? creationDate(of: dir)),
            duration: audioDuration(dir),
            transcript: (try? String(contentsOf: txPath, encoding: .utf8)) ?? "",
            summary: (try? String(contentsOf: smPath, encoding: .utf8)) ?? "",
            canTranscribe: audio != nil,
            canSummarize: FileManager.default.fileExists(atPath: txPath.path),
            audioURL: audio,
            language: meta["language"] as? String,
            participants: decodeParticipants(meta["participants"]),
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

    /// Persist wall-clock recording window for a session. Called by
    /// PipelineRunner at record start (`endedAt` nil) and again when the
    /// capture finishes successfully. Written as ISO-8601 so it's both
    /// human-readable and unambiguous across time zones.
    static func setRecordingTimes(_ dir: URL, startedAt: Date?, endedAt: Date?) {
        var data = readMeta(dir)
        let fmt = isoFormatter
        if let startedAt {
            data["startedAt"] = fmt.string(from: startedAt)
        } else {
            data.removeValue(forKey: "startedAt")
        }
        if let endedAt {
            data["endedAt"] = fmt.string(from: endedAt)
        } else {
            data.removeValue(forKey: "endedAt")
        }
        writeMeta(dir, data)
    }

    /// Merge a fresh observation of meeting participants into the session's
    /// persisted list. Called by the participants recorder while a recording
    /// is in progress; safe to call repeatedly — existing entries are updated,
    /// new names appended. Call-order semantics:
    ///
    /// - Match by `name` (case-sensitive).
    /// - Existing entry: `firstSeenAt` preserved, `lastSeenAt` bumped, role
    ///   flags OR-ed (once someone was host, they stay "was host" in history).
    /// - New entry: appended in the order it appears in `observed`.
    ///
    /// Returns the merged list so the caller can re-render without re-reading.
    @discardableResult
    static func appendParticipants(
        _ dir: URL,
        observed: [SessionParticipant],
    ) -> [SessionParticipant] {
        var data = readMeta(dir)
        let existing = decodeParticipants(data["participants"])
        let merged = mergeParticipants(existing: existing, observed: observed)
        if merged == existing { return merged }
        data["participants"] = merged.map(encodeParticipant)
        writeMeta(dir, data)
        return merged
    }

    /// Pure merge logic. Extracted for unit testing.
    static func mergeParticipants(
        existing: [SessionParticipant],
        observed: [SessionParticipant],
    ) -> [SessionParticipant] {
        var byName: [String: SessionParticipant] = [:]
        var order: [String] = []
        for participant in existing {
            byName[participant.name] = participant
            order.append(participant.name)
        }
        for observation in observed {
            if let prior = byName[observation.name] {
                byName[observation.name] = prior.merged(with: observation)
            } else {
                byName[observation.name] = observation
                order.append(observation.name)
            }
        }
        return order.compactMap { byName[$0] }
    }

    /// Read the stored participants list. Returns an empty array when the
    /// session has none yet (or when the JSON is malformed).
    static func readParticipants(_ dir: URL) -> [SessionParticipant] {
        decodeParticipants(readMeta(dir)["participants"])
    }

    private static func decodeParticipants(_ raw: Any?) -> [SessionParticipant] {
        guard let array = raw as? [[String: Any]] else { return [] }
        return array.compactMap(SessionParticipant.init(dict:))
    }

    private static func encodeParticipant(_ participant: SessionParticipant) -> [String: Any] {
        participant.dict(using: isoFormatter)
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

    /// Sweep abandoned session directories. Moves to Trash any session that:
    /// - has no `audio.m4a` / `audio.wav` (pipeline never merged capture),
    /// - has no `transcript.txt` / `summary.md` (no downstream artifact to
    ///   salvage), and
    /// - is older than `minAge` (defensive — prevents clobbering a recording
    ///   that started moments before launch if the app is restarted fast).
    ///
    /// Meant to run once at app launch to clean up sessions left behind by
    /// auto-record flicker (Zoom camera toggling creates multiple short-lived
    /// start attempts that never complete).
    ///
    /// Returns the list of directories that were trashed.
    @discardableResult
    static func gcAbandonedSessions(
        sessionsDir: String,
        now: Date = Date(),
        minAge: TimeInterval = 60,
    ) -> [URL] {
        let dir = URL(fileURLWithPath: (sessionsDir as NSString).expandingTildeInPath)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey],
            options: .skipsHiddenFiles,
        ) else { return [] }

        var trashed: [URL] = []
        for entry in contents {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  isAbandoned(sessionDir: entry, now: now, minAge: minAge)
            else { continue }
            if (try? FileManager.default.trashItem(at: entry, resultingItemURL: nil)) != nil {
                trashed.append(entry)
            }
        }
        return trashed
    }

    /// Pure predicate, exposed for tests. A session is abandoned when it has
    /// neither a canonical audio artifact nor a transcript/summary, and is old
    /// enough that we're confident it's not an in-flight recording.
    static func isAbandoned(
        sessionDir: URL,
        now: Date = Date(),
        minAge: TimeInterval = 60,
    ) -> Bool {
        let fm = FileManager.default
        let hasM4A = fm.fileExists(atPath: sessionDir.appendingPathComponent("audio.m4a").path)
        let hasWAV = fm.fileExists(atPath: sessionDir.appendingPathComponent("audio.wav").path)
        let hasTranscript = fm.fileExists(
            atPath: sessionDir.appendingPathComponent("transcript.txt").path,
        )
        let hasSummary = fm.fileExists(
            atPath: sessionDir.appendingPathComponent("summary.md").path,
        )
        if hasM4A || hasWAV || hasTranscript || hasSummary { return false }

        let meta = readMeta(sessionDir)
        let startedAt = parseDate(meta["startedAt"])
        let referenceDate = startedAt ?? creationDate(of: sessionDir)
        return now.timeIntervalSince(referenceDate) >= minAge
    }

    // MARK: - Helpers

    private static let dateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d, yyyy HH:mm"
        return fmt
    }()

    /// ISO-8601 with fractional seconds — matches what Foundation's
    /// `ISO8601DateFormatter` produces by default and round-trips cleanly.
    /// ISO-8601 formatter shared with `SessionParticipant` encoding so all
    /// dates written to `meta.json` round-trip against the same parser.
    static let isoFormatter: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt
    }()

    /// Accept ISO-8601 strings either with or without fractional seconds so
    /// manually-edited meta.json entries still parse.
    private static func parseDate(_ raw: Any?) -> Date? {
        guard let string = raw as? String, !string.isEmpty else { return nil }
        if let date = isoFormatter.date(from: string) { return date }
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: string)
    }

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
