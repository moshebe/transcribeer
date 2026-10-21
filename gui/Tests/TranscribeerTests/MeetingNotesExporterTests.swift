import Foundation
import Testing
@testable import TranscribeerApp

struct MeetingNotesExporterTests {
    @Test("slug", arguments: [
        ("Weekly Team Sync", "weekly-team-sync"),
        ("Design review: API/v2", "design-review-api-v2"),
        ("סנכרון צוות", "meeting-1248"),
        ("", "meeting-1248"),
    ])
    func slug(title: String, expected: String) {
        #expect(MeetingNotesExporter.slug(title, fallback: "meeting-1248") == expected)
    }

    @Test("date comes from the session folder name")
    func sessionDate() {
        #expect(MeetingNotesExporter.sessionDate("2026-10-19-1248") == "2026-10-19")
        #expect(MeetingNotesExporter.sessionDate("2026-10-18-1706-1") == "2026-10-18")
    }

    @Test("re-export after a rename replaces the old notes and keeps unrelated files")
    func reexportReplaces() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let session = root.appendingPathComponent("sessions/2026-10-19-1248")
        let notes = root.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "summary body".write(to: session.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        try "[00:00 -> 00:05] You: hi".write(
            to: session.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8
        )
        let unrelated = notes.appendingPathComponent("2026-10-19-other-summary.md")
        try "---\ntitle: other\n---\n".write(to: unrelated, atomically: true, encoding: .utf8)

        SessionManager.setName(session, "First Name")
        try MeetingNotesExporter.export(session: session, to: notes)
        SessionManager.setName(session, "Second Name")
        let written = try MeetingNotesExporter.export(session: session, to: notes)

        let names = try FileManager.default.contentsOfDirectory(atPath: notes.path).sorted()
        #expect(names == [
            "2026-10-19-other-summary.md",
            "2026-10-19-second-name-summary.md",
            "2026-10-19-second-name-transcript.md",
        ])
        let summary = try String(contentsOf: written[0], encoding: .utf8)
        #expect(summary.hasPrefix("---\ntitle: \"Second Name - summary\"\ndate: 2026-10-19\n"))
        #expect(summary.contains("transcribeer_session: 2026-10-19-1248\n"))
        #expect(summary.hasSuffix("# Second Name - Summary\n\nsummary body"))
    }

    @Test("missing folder throws")
    func missingFolder() {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        #expect(throws: MeetingNotesExporter.ExportError.self) {
            try MeetingNotesExporter.export(session: missing, to: missing)
        }
    }
}
