import SwiftUI
import WhisperKit

/// Progress strip shown at the bottom of the session detail view while
/// WhisperKit is loading or transcribing. Drives the live ETA using the
/// session-scoped `ETAEstimator` owned by the parent so re-transcribes
/// reuse the same state.
///
/// `etaEstimator` is a reference type passed by identity — mutations to
/// its internal EMA happen inside `estimate(...)` and are observed on the
/// next `TimelineView` tick, so the child never reassigns the reference
/// and doesn't need a `@Binding`.
struct TranscriptionProgressRow: View {
    let runner: PipelineRunner
    let startedAt: Date?
    let etaEstimator: ETAEstimator

    var body: some View {
        HStack(spacing: 12) {
            Text(progressLabel)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minWidth: 140, alignment: .leading)
                .help(progressLabel)

            if let mic = runner.transcriptionService.micProgress,
               let sys = runner.transcriptionService.sysProgress {
                VStack(alignment: .leading, spacing: 4) {
                    sourceProgressRow(label: "Mic", value: mic)
                    sourceProgressRow(label: "Sys", value: sys)
                }
            } else if let progress = runner.transcriptionProgress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            } else {
                ProgressView().progressViewStyle(.linear)
            }

            if let startedAt {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text(timerLabel(startedAt: startedAt, now: context.date))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 140, alignment: .trailing)
                }
            }

            stopButton
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    /// Single labelled row for a per-source (mic/sys) progress bar.
    private func sourceProgressRow(label: String, value: Double) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .leading)
            ProgressView(value: value)
                .progressViewStyle(.linear)
            Text("\(Int(value * 100))%")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
        }
    }

    private var stopButton: some View {
        Button {
            runner.cancelProcessing()
        } label: {
            Label("Stop", systemImage: "stop.fill")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .disabled(runner.isCancelling)
        .help(runner.isCancelling ? "Cancelling…" : "Stop transcription")
        .accessibilityLabel(runner.isCancelling ? "Cancelling" : "Stop transcription")
    }

    /// `01:23` while warming up, `01:23 · ~00:45 left` once ETA is stable.
    private func timerLabel(startedAt: Date, now: Date) -> String {
        let elapsed = max(0, now.timeIntervalSince(startedAt))
        let elapsedString = formatMMSS(Int(elapsed))
        guard
            let progress = runner.transcriptionProgress,
            let eta = etaEstimator.estimate(progress: progress, elapsed: elapsed)
        else { return elapsedString }
        return "\(elapsedString) · ~\(formatMMSS(Int(eta.rounded()))) left"
    }

    private func formatMMSS(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        return String(format: "%02d:%02d", clamped / 60, clamped % 60)
    }

    /// Top-level status text shown to the left of the bar. Prefers the
    /// cloud-path `transcriptionPhase` when available ("Transcribing 3 of
    /// 6 chunks · OpenAI"), falling back to the legacy model-state label
    /// for local WhisperKit transcription and idle/loading states.
    private var progressLabel: String {
        if runner.isCancelling { return "Cancelling…" }
        if let phase = runner.transcriptionService.transcriptionPhase {
            return phase
        }
        if runner.transcriptionProgress != nil { return "Transcribing…" }
        return switch runner.transcriptionService.modelState {
        case .downloading: "Downloading model…"
        case .downloaded: "Model downloaded"
        case .prewarming: "Preparing model…"
        case .prewarmed: "Model ready"
        case .loading: "Loading model…"
        case .unloading: "Unloading model…"
        case .loaded, .unloaded: "Transcribing…"
        }
    }
}
