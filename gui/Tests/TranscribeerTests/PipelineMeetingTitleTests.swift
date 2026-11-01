import Foundation
import Testing
@testable import TranscribeerApp

@MainActor
struct PipelineMeetingTitleTests {
    @Test(arguments: ["", "My meeting notes"])
    func savesLateTitleWithoutReplacingUserName(existingName: String) throws {
        let session = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: session) }
        SessionManager.setName(session, existingName)
        let runner = PipelineRunner()
        runner.currentSession = session
        runner.meetingAutoStartContext = .init(appName: "Zoom", title: nil, delaySeconds: 0)

        runner.applyMeetingTitle("Test Zoom Meeting")

        #expect(runner.liveMeetingTitle == "Test Zoom Meeting")
        let expected = existingName.isEmpty ? "Test Zoom Meeting" : existingName
        #expect(SessionManager.readMeta(session)["name"] as? String == expected)
    }
}
