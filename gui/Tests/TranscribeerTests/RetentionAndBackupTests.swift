import Foundation
import Testing
@testable import TranscribeerApp

// MARK: - Helpers

private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let day: TimeInterval = 86_400

/// A session that ended `ageDays` before `now`, with the given files.
private func makeSession(
    in root: URL,
    name: String,
    ageDays: Double,
    files: [String: String],
) throws -> URL {
    let session = root.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
    let ended = now.addingTimeInterval(-ageDays * day)
    SessionManager.setRecordingTimes(session, startedAt: ended.addingTimeInterval(-1_800), endedAt: ended)
    for (file, content) in files {
        try content.write(to: session.appendingPathComponent(file), atomically: true, encoding: .utf8)
    }
    return session
}

private func exists(_ session: URL, _ file: String) -> Bool {
    FileManager.default.fileExists(atPath: session.appendingPathComponent(file).path)
}

private let deleteForReal: RetentionService.Remover = { try FileManager.default.removeItem(at: $0) }

// MARK: - Retention

struct RetentionServiceTests {
    private let processed = [
        "audio.m4a": "a", "audio.mic.m4a": "m", "audio.sys.m4a": "s",
        "transcript.txt": "hello", "summary.md": "# sum",
    ]

    private func settings(audio: Bool = true, transcript: Bool = false, days: Int = 30) -> AppConfig.RetentionSettings {
        AppConfig.RetentionSettings(enabled: true, days: days, deleteAudio: audio, deleteTranscript: transcript)
    }

    @Test("Retention is opt-in: nothing is removed while it's off")
    func disabledDoesNothing() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(in: root, name: "old", ageDays: 400, files: processed)

        var off = settings()
        off.enabled = false
        let outcomes = RetentionService.sweep(sessionsDir: root.path, settings: off, now: now, remove: deleteForReal)

        #expect(outcomes.isEmpty)
        #expect(exists(session, "audio.m4a"))
    }

    @Test("Old processed sessions lose the chosen files; summary and notes stay")
    func removesChosenFiles() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(in: root, name: "old", ageDays: 31, files: processed)

        RetentionService.sweep(
            sessionsDir: root.path, settings: settings(transcript: true), now: now, remove: deleteForReal,
        )

        #expect(!exists(session, "audio.m4a"))
        #expect(!exists(session, "audio.mic.m4a"))
        #expect(!exists(session, "audio.sys.m4a"))
        #expect(!exists(session, "transcript.txt"))
        #expect(exists(session, "summary.md"))
        #expect(exists(session, "meta.json"))
    }

    @Test("Audio can be kept while the transcript is removed")
    func keepsAudioWhenNotChosen() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(in: root, name: "old", ageDays: 31, files: processed)

        RetentionService.sweep(
            sessionsDir: root.path, settings: settings(audio: false, transcript: true), now: now, remove: deleteForReal,
        )

        #expect(exists(session, "audio.m4a"))
        #expect(!exists(session, "transcript.txt"))
    }

    @Test("Recent sessions are untouched")
    func keepsRecentSessions() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(in: root, name: "recent", ageDays: 29, files: processed)

        let outcomes = RetentionService.sweep(
            sessionsDir: root.path, settings: settings(), now: now, remove: deleteForReal,
        )

        #expect(outcomes.isEmpty)
        #expect(exists(session, "audio.m4a"))
    }

    @Test("A recording that was never transcribed or summarized keeps its audio")
    func neverDeletesOnlyCopy() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(in: root, name: "raw", ageDays: 90, files: ["audio.m4a": "a"])

        RetentionService.sweep(sessionsDir: root.path, settings: settings(), now: now, remove: deleteForReal)

        #expect(exists(session, "audio.m4a"))
    }

    @Test("A transcript without a summary is kept")
    func keepsTranscriptWithoutSummary() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(
            in: root, name: "no-summary", ageDays: 90, files: ["audio.m4a": "a", "transcript.txt": "hello"],
        )

        RetentionService.sweep(
            sessionsDir: root.path, settings: settings(transcript: true), now: now, remove: deleteForReal,
        )

        #expect(!exists(session, "audio.m4a"))
        #expect(exists(session, "transcript.txt"))
    }

    @Test("Removals are written to the session's run log")
    func logsRemovals() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(in: root, name: "old", ageDays: 31, files: processed)

        RetentionService.sweep(sessionsDir: root.path, settings: settings(), now: now, remove: deleteForReal)

        let log = try String(contentsOf: session.appendingPathComponent("run.log"), encoding: .utf8)
        #expect(log.contains("retention: moved to Trash audio.m4a, audio.mic.m4a, audio.sys.m4a"))
    }
}

// MARK: - Backup (meeting notes folder with audio)

struct MeetingNotesAudioBackupTests {
    @Test("Audio is copied only when included, and named in the notes")
    func copiesAudioWhenIncluded() throws {
        let root = try tempDir()
        let folder = try tempDir()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: folder)
        }
        let session = try makeSession(
            in: root,
            name: "2026-11-02-0900",
            ageDays: 0,
            files: ["audio.m4a": "AUDIO", "transcript.txt": "hello", "summary.md": "# sum"],
        )
        SessionManager.setName(session, "Weekly Sync")

        let withoutAudio = try MeetingNotesExporter.export(session: session, to: folder)
        #expect(!withoutAudio.contains { $0.lastPathComponent.hasSuffix("-audio.m4a") })

        let withAudio = try MeetingNotesExporter.export(session: session, to: folder, includeAudio: true)
        let audio = try #require(withAudio.first { $0.lastPathComponent == "2026-11-02-weekly-sync-audio.m4a" })
        #expect(try String(contentsOf: audio, encoding: .utf8) == "AUDIO")
        let summary = try String(
            contentsOf: folder.appendingPathComponent("2026-11-02-weekly-sync-summary.md"), encoding: .utf8,
        )
        #expect(summary.contains("audio: 2026-11-02-weekly-sync-audio.m4a"))
    }

    @Test("Renaming a session replaces the old audio copy instead of leaving it behind")
    func renameReplacesAudio() throws {
        let root = try tempDir()
        let folder = try tempDir()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: folder)
        }
        let session = try makeSession(
            in: root,
            name: "2026-11-02-0900",
            ageDays: 0,
            files: ["audio.m4a": "AUDIO", "summary.md": "# sum"],
        )
        SessionManager.setName(session, "Draft")
        try MeetingNotesExporter.export(session: session, to: folder, includeAudio: true)
        SessionManager.setName(session, "Final")
        try MeetingNotesExporter.export(session: session, to: folder, includeAudio: true)

        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(names == ["2026-11-02-final-audio.m4a", "2026-11-02-final-summary.md"])
    }

    @Test("A note can't make the exporter delete files outside the folder")
    func audioRemovalStaysInFolder() throws {
        let folder = try tempDir()
        let outside = try tempDir()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: outside)
        }
        let victim = outside.appendingPathComponent("keep.m4a")
        try "x".write(to: victim, atomically: true, encoding: .utf8)
        let note = """
            ---
            audio: ../\(outside.lastPathComponent)/keep.m4a
            \(MeetingNotesExporter.sessionKey): 2026-11-02-0900
            ---
            """
        try note.write(to: folder.appendingPathComponent("old.md"), atomically: true, encoding: .utf8)
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(in: root, name: "2026-11-02-0900", ageDays: 0, files: ["summary.md": "# s"])

        try MeetingNotesExporter.export(session: session, to: folder)

        #expect(FileManager.default.fileExists(atPath: victim.path))
    }
}

// MARK: - Cloud folders

struct CloudFoldersTests {
    @Test("Cloud storage mount names read naturally", arguments: [
        ("GoogleDrive-dana@example.com", "Google Drive (dana@example.com)"),
        ("OneDrive-Personal", "OneDrive (Personal)"),
        ("Dropbox", "Dropbox"),
    ])
    func displayNames(folder: String, expected: String) {
        #expect(CloudFolders.displayName(forMount: folder) == expected)
    }

    @Test("Suggests iCloud Drive and Google Drive's My Drive when present")
    func suggestsInstalledProviders() throws {
        let home = try tempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let fm = FileManager.default
        try fm.createDirectory(
            at: home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs"),
            withIntermediateDirectories: true,
        )
        try fm.createDirectory(
            at: home.appendingPathComponent("Library/CloudStorage/GoogleDrive-dana@example.com/My Drive"),
            withIntermediateDirectories: true,
        )

        let suggestions = CloudFolders.suggestions(home: home)

        #expect(suggestions.map(\.name) == ["iCloud Drive", "Google Drive (dana@example.com)"])
        #expect(suggestions[1].url.path.hasSuffix("GoogleDrive-dana@example.com/My Drive/Transcribeer"))
    }

    @Test("No cloud apps means no suggestions")
    func noProviders() throws {
        let home = try tempDir()
        defer { try? FileManager.default.removeItem(at: home) }

        #expect(CloudFolders.suggestions(home: home).isEmpty)
    }
}

// MARK: - Config round-trip

struct RetentionConfigTests {
    @Test("Retention and audio backup settings survive a save/load round-trip")
    func roundTrip() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("config.toml")
        var config = AppConfig()
        config.retention = .init(enabled: true, days: 14, deleteAudio: false, deleteTranscript: true)
        config.integrations.exportIncludeAudio = true

        ConfigManager.save(config, to: path)
        let loaded = ConfigManager.load(from: path)

        #expect(loaded.retention == config.retention)
        #expect(loaded.integrations.exportIncludeAudio)
    }

    @Test("Both features are off by default")
    func offByDefault() {
        let config = AppConfig()
        #expect(!config.retention.enabled)
        #expect(!config.integrations.exportIncludeAudio)
    }
}
