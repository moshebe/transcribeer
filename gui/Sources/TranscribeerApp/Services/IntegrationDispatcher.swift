import AppKit
import Foundation
import os.log

private let logger = Logger(subsystem: "com.transcribeer", category: "integrations")

/// Best-effort post-pipeline side-effects: clipboard copy, file export, Obsidian validation.
/// All operations catch their own errors and log to `run.log`. A failure in one integration
/// never blocks another or propagates up to the pipeline.
enum IntegrationDispatcher {
    static func dispatch(session: URL, config: AppConfig) async {
        let runLog = session.appendingPathComponent("run.log")

        func log(_ message: String) {
            let timestamp = DateFormatter.localizedString(
                from: Date(),
                dateStyle: .none,
                timeStyle: .medium
            )
            let data = Data("[\(timestamp)] integrations: \(message)\n".utf8)
            if let handle = try? FileHandle(forWritingTo: runLog) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        }

        // MARK: Clipboard
        await dispatchClipboard(session: session, config: config, log: log)

        // MARK: File export (auto-export formats)
        dispatchFileExport(session: session, config: config, log: log)

        // MARK: Obsidian vault validation
        dispatchObsidian(config: config, log: log)
    }

    // MARK: - Clipboard

    @MainActor
    private static func dispatchClipboard(
        session: URL,
        config: AppConfig,
        log: (String) -> Void
    ) async {
        let integ = config.integrations
        guard integ.clipboardCopySummary || integ.clipboardCopyTranscript else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        if integ.clipboardCopySummary {
            let summaryURL = session.appendingPathComponent("summary.md")
            do {
                let text = try String(contentsOf: summaryURL, encoding: .utf8)
                pasteboard.setString(text, forType: .string)
                log("clipboard: copied summary (\(text.count) chars)")
            } catch {
                log("clipboard: summary read failed — \(error.localizedDescription)")
            }
        }

        if integ.clipboardCopyTranscript {
            let transcriptURL = session.appendingPathComponent("transcript.txt")
            do {
                let text = try String(contentsOf: transcriptURL, encoding: .utf8)
                pasteboard.setString(text, forType: .string)
                log("clipboard: copied transcript (\(text.count) chars)")
            } catch {
                log("clipboard: transcript read failed — \(error.localizedDescription)")
            }
        }
    }

    // MARK: - File export

    private static func dispatchFileExport(
        session: URL,
        config: AppConfig,
        log: (String) -> Void
    ) {
        let formats = config.integrations.exportFormats
        guard !formats.isEmpty else { return }
        // The pipeline already writes srt/vtt directly if the config is set.
        // Log that auto-export is configured so users can verify it via run.log.
        log("auto-export configured: formats=\(formats.joined(separator: ","))")
    }

    // MARK: - Obsidian

    private static func dispatchObsidian(config: AppConfig, log: (String) -> Void) {
        guard config.integrations.obsidianEnabled,
              !config.integrations.obsidianVaultPath.isEmpty
        else { return }

        let expanded = (config.integrations.obsidianVaultPath as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir)
        if exists && isDir.boolValue {
            log("obsidian: vault path ok — \(expanded)")
        } else {
            log("obsidian: vault path not found or not a directory — \(expanded)")
            logger.warning("Obsidian vault not found at \(expanded, privacy: .public)")
        }
    }
}
