import Foundation

public enum PromptProfileManager {
    private static var promptsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".transcribeer/prompts")
    }

    /// Return available profile names. "default" is always first.
    public static func listProfiles() -> [String] {
        var profiles = ["default"]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: promptsDir, includingPropertiesForKeys: nil
        ) else { return profiles }

        let extras = contents
            .filter { $0.pathExtension == "md" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .filter { $0 != "default" }
            .sorted()
        profiles.append(contentsOf: extras)
        return profiles
    }
}
