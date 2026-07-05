import Foundation
import os.log

/// Generates and persists the one-sentence sidebar description for a session.
///
/// Runs as a best-effort follow-up after the main summary stream finishes, so
/// the History sidebar can show what a meeting was about instead of the
/// `# Meeting Summary` heading. Failures are logged but never propagated —
/// the summary itself is the canonical artifact and we don't want a flaky
/// extra LLM call to mark the whole pipeline failed.
enum SessionDescriptionWriter {
    private static let logger = Logger(subsystem: "com.transcribeer", category: "description")

    /// Write `description.txt` next to `summary.md` for the given session.
    /// No-op when the description comes back empty; cancellation is silent,
    /// other errors are logged as warnings.
    static func write(session: URL, summary: String, config: AppConfig) async {
        do {
            let description = try await SummarizationService.generateDescription(
                summary: summary,
                backend: config.llmBackend,
                model: config.llmModel,
                ollamaHost: config.ollamaHost,
            )
            guard !description.isEmpty else { return }
            let path = session.appendingPathComponent("description.txt")
            try description.write(to: path, atomically: true, encoding: .utf8)
        } catch is CancellationError {
            // Cancellation was already logged upstream.
        } catch {
            logger.warning(
                "description generation failed: \(error.localizedDescription, privacy: .public)",
            )
        }
    }
}
