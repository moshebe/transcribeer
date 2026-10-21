import SwiftUI

/// App-level notices shown at the top of the History window: missing
/// permissions, model downloads in flight, and model install failures.
struct NoticesSection: View {
    let config: AppConfig
    let transcriptionService: TranscriptionService
    let hebrewDownloader: HebrewModelDownloader

    var body: some View {
        let notices = currentNotices
        if !notices.isEmpty {
            VStack(spacing: 0) {
                ForEach(notices) { notice in
                    NoticeRow(notice: notice)
                    Divider()
                }
            }
        }
    }

    private var currentNotices: [Notice] {
        var notices: [Notice] = []

        if let failure = transcriptionService.modelInstallFailure {
            notices.append(Notice(
                id: "model-install-failure",
                severity: .error,
                title: "Couldn't install model \(failure.modelName)",
                message: failure.message,
                progress: .none,
                action: NoticeAction(title: "Dismiss") {
                    transcriptionService.modelInstallFailure = nil
                }
            ))
        }

        if let hebrew = hebrewDownloader.currentDownload {
            notices.append(Notice(
                id: "hebrew-download",
                severity: .info,
                title: "Downloading \(hebrew.displayName)",
                message: nil,
                progress: hebrewDownloader.progress.map(NoticeProgress.determinate) ?? .indeterminate,
                action: nil
            ))
        }

        if let activity = transcriptionService.modelLoadActivity {
            switch activity.phase {
            case .downloading(let fraction):
                notices.append(Notice(
                    id: "model-activity",
                    severity: .info,
                    title: "Downloading model \(activity.modelName)",
                    message: nil,
                    progress: fraction.map(NoticeProgress.determinate) ?? .indeterminate,
                    action: nil
                ))
            case .loading:
                notices.append(Notice(
                    id: "model-activity",
                    severity: .info,
                    title: "Loading model \(activity.modelName)",
                    message: "The first load on this Mac can take several minutes while CoreML optimizes the model.",
                    progress: .indeterminate,
                    action: nil
                ))
            }
        }

        if config.zoomEnricherEnabled, !AccessibilityGuard.isTrusted {
            notices.append(Notice(
                id: "accessibility",
                severity: .warning,
                title: "Accessibility permission not granted",
                message: "Zoom meeting titles and participants won't be captured until Transcribeer "
                    + "is enabled in System Settings → Privacy & Security → Accessibility.",
                progress: .none,
                action: NoticeAction(title: "Open Settings") {
                    AccessibilityGuard.prompt()
                    AccessibilityGuard.openSystemSettings()
                }
            ))
        }

        return notices
    }
}

struct Notice: Identifiable {
    enum Severity {
        case info, warning, error

        var symbol: String {
            switch self {
            case .info: "arrow.down.circle"
            case .warning: "exclamationmark.triangle.fill"
            case .error: "xmark.octagon.fill"
            }
        }

        var tint: Color {
            switch self {
            case .info: .accentColor
            case .warning: .orange
            case .error: .red
            }
        }
    }

    let id: String
    let severity: Severity
    let title: String
    let message: String?
    let progress: NoticeProgress
    let action: NoticeAction?
}

enum NoticeProgress {
    case none
    case indeterminate
    case determinate(Double)
}

struct NoticeAction {
    let title: String
    let perform: () -> Void
}

private struct NoticeRow: View {
    let notice: Notice

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: notice.severity.symbol)
                .foregroundStyle(notice.severity.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let message = notice.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            progressView
            if let action = notice.action {
                Button(action.title, action: action.perform)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(notice.severity.tint.opacity(0.10))
    }

    @ViewBuilder
    private var progressView: some View {
        switch notice.progress {
        case .none:
            EmptyView()
        case .indeterminate:
            ProgressView().controlSize(.small)
        case .determinate(let fraction):
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .frame(width: 160)
            Text("\(Int(fraction * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
    }
}
