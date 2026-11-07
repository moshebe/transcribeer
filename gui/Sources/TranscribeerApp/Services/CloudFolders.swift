import Foundation

/// Folders synced by cloud-storage apps on this Mac, offered as one-click
/// destinations for the meeting-notes backup. Writing into them is enough:
/// the provider's own app does the upload, so no OAuth or API is involved.
enum CloudFolders {
    struct Suggestion: Equatable, Identifiable {
        let name: String
        let url: URL

        var id: String { url.path }
    }

    /// Subfolder created inside the chosen cloud folder.
    static let appFolderName = "Transcribeer"

    static func suggestions(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Suggestion] {
        var result: [Suggestion] = []

        let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if isDirectory(iCloud) {
            result.append(Suggestion(name: "iCloud Drive", url: iCloud.appendingPathComponent(appFolderName)))
        }

        // Google Drive, OneDrive, Dropbox, Box… mount under ~/Library/CloudStorage
        // as `<Provider>-<account>`.
        let cloudStorage = home.appendingPathComponent("Library/CloudStorage")
        let mounts = (try? FileManager.default.contentsOfDirectory(
            at: cloudStorage,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles,
        )) ?? []
        for mount in mounts.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where isDirectory(mount) {
            // Google Drive keeps the user's files under "My Drive".
            let myDrive = mount.appendingPathComponent("My Drive")
            let root = isDirectory(myDrive) ? myDrive : mount
            result.append(Suggestion(
                name: displayName(forMount: mount.lastPathComponent),
                url: root.appendingPathComponent(appFolderName),
            ))
        }
        return result
    }

    /// `GoogleDrive-dana@example.com` → `Google Drive (dana@example.com)`.
    static func displayName(forMount folder: String) -> String {
        let parts = folder.split(separator: "-", maxSplits: 1).map(String.init)
        let provider = switch parts[0] {
        case "GoogleDrive": "Google Drive"
        case "OneDrive": "OneDrive"
        default: parts[0]
        }
        guard parts.count > 1, !parts[1].isEmpty else { return provider }
        return "\(provider) (\(parts[1]))"
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
