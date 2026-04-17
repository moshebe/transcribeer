import Foundation
import Testing
@testable import TranscribeerApp

struct PromptProfileTests {
    @Test("Preset library covers common meeting types")
    func presetsCoverCommonMeetingTypes() {
        let ids = Set(PromptProfileManager.presets.map(\.id))
        for expected in [
            "1on1", "standup", "customer-discovery", "user-interview",
            "sales-call", "job-interview", "retro",
        ] {
            #expect(ids.contains(expected), "Missing preset: \(expected)")
        }
    }

    @Test("Presets have non-empty content and unique ids")
    func presetsWellFormed() {
        let presets = PromptProfileManager.presets
        #expect(!presets.isEmpty)
        #expect(Set(presets.map(\.id)).count == presets.count)
        for preset in presets {
            #expect(!preset.title.isEmpty)
            #expect(!preset.content.isEmpty)
            #expect(preset.id != PromptProfileManager.defaultName)
        }
    }

    @Test("Rejects reserved name 'default'")
    func rejectsDefaultName() {
        #expect(throws: PromptProfileManager.ProfileError.self) {
            try PromptProfileManager.save(name: "default", content: "x")
        }
    }

    @Test("Rejects empty / whitespace name")
    func rejectsEmptyName() {
        #expect(throws: PromptProfileManager.ProfileError.self) {
            try PromptProfileManager.save(name: "  ", content: "x")
        }
    }

    @Test("Rejects path-unsafe characters")
    func rejectsPathUnsafeChars() {
        for bad in ["a/b", "x:y", "foo*", "../etc"] {
            #expect(throws: PromptProfileManager.ProfileError.self) {
                try PromptProfileManager.save(name: bad, content: "x")
            }
        }
    }

    @Test("Default profile is always first in the list")
    func defaultIsFirst() {
        let list = PromptProfileManager.listProfiles()
        #expect(list.first == PromptProfileManager.defaultName)
    }
}
