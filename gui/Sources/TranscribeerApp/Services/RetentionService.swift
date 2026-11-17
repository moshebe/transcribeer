import Foundation
import os.log

private let logger = Logger(subsystem: "com.transcribeer", category: "retention")

/// Opt-in clean-up of old sessions (Settings → Storage).
///
/// Removes audio and/or transcripts from sessions older than the configured
/// number of days, moving them to the Trash so a mistake stays recoverable.
/// Summaries, notes and metadata are always kept, and a file is only removed
/// when something derived from it survives: audio needs a transcript or a
/// summary, a transcript needs a summary. An unprocessed recording is never
/// touched.
enum RetentionService {
    struct Outcome: Equatable {
        let session: URL
        let removed: [String]
    }

    /// Moves a file to the Trash. Injectable so tests don't fill the user's Trash.
    typealias Remover = (URL) throws -> Void

    static let moveToTrash: Remover = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// Apply `settings` to every session in `sessionsDir`. No-op when
    /// retention is off.
    @discardableResult
    static func sweep(
        sessionsDir: String,
        settings: AppConfig.RetentionSettings,
        now: Date = Date(),
        remove: Remover = moveToTrash,
    ) -> [Outcome] {
        guard settings.enabled else { return [] }
        let cutoff = now.addingTimeInterval(-Double(max(1, settings.days)) * 86_400)

        var outcomes: [Outcome] = []
        for session in SessionManager.listSessions(sessionsDir: sessionsDir) {
            let finishedAt = session.endedAt ?? session.startedAt ?? session.date
            guard finishedAt < cutoff else { continue }
            let files = filesToRemove(in: session.path, settings: settings)
            guard !files.isEmpty else { continue }

            let removed = files.filter { (try? remove($0)) != nil }.map(\.lastPathComponent)
            guard !removed.isEmpty else { continue }
            appendRunLog(
                session.path,
                "retention: moved to Trash \(removed.joined(separator: ", ")) (older than \(settings.days) days)"
            )
            outcomes.append(Outcome(session: session.path, removed: removed))
        }
        if !outcomes.isEmpty {
            logger.info("retention: cleaned \(outcomes.count, privacy: .public) session(s)")
        }
        return outcomes
    }

    /// Files in `session` that `settings` allows removing, respecting the
    /// "something derived survives" rule.
    static func filesToRemove(in session: URL, settings: AppConfig.RetentionSettings) -> [URL] {
        let summary = session.appendingPathComponent("summary.md")
        let transcript = session.appendingPathComponent("transcript.txt")
        let hasSummary = hasContent(summary)
        let hasTranscript = hasContent(transcript)

        var files: [URL] = []
        if settings.deleteAudio, hasSummary || hasTranscript {
            files += audioFiles(in: session)
        }
        if settings.deleteTranscript, hasSummary, FileManager.default.fileExists(atPath: transcript.path) {
            files.append(transcript)
        }
        return files
    }

    /// The mixed recording and the per-source sidecars (`audio.m4a`,
    /// `audio.mic.caf`, `audio.sys.m4a`, …).
    private static func audioFiles(in session: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: session,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles,
        )) ?? []
        return contents
            .filter { $0.lastPathComponent.hasPrefix("audio.") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func hasContent(_ url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func appendRunLog(_ session: URL, _ message: String) {
        let line = Data("[\(Date().formatted(date: .omitted, time: .standard))] \(message)\n".utf8)
        let runLog = session.appendingPathComponent("run.log")
        guard let handle = try? FileHandle(forWritingTo: runLog) else {
            try? line.write(to: runLog)
            return
        }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(line)
    }
}
