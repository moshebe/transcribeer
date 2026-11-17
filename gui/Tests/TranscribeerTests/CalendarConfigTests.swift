import Foundation
import Testing
@testable import TranscribeerApp

struct CalendarConfigTests {
    @Test("Calendar enricher is off by default")
    func defaultsOff() {
        let config = AppConfig()
        #expect(!config.calendarEnricherEnabled)
        #expect(config.calendarNames.isEmpty)
    }

    @Test("ConfigManager round-trips calendar enricher settings")
    func roundTrip() throws {
        var cfg = AppConfig()
        cfg.calendarEnricherEnabled = true
        cfg.calendarNames = ["work.example.com", "Team \"A\""]

        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let path = tmpDir.appendingPathComponent("config.toml")

        ConfigManager.save(cfg, to: path)
        let decoded = ConfigManager.load(from: path)

        #expect(decoded.calendarEnricherEnabled)
        #expect(decoded.calendarNames == ["work.example.com", "Team \"A\""])
    }
}
