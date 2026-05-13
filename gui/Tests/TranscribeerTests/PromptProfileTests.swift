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

    @Test("New-profile validation flags 'default' as reserved")
    func validationFlagsDefaultName() {
        // The new-profile sheet uses validationError to gate the Create button,
        // so 'default' must still be rejected there even though save() now
        // accepts it (to persist an override of the built-in prompt).
        #expect(PromptProfileManager.validationError(for: "default") != nil)
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
