import SwiftUI
import TranscribeerCore

struct OnboardingModelsView: View {
    @Bindable var state: OnboardingState
    let downloader: HebrewModelDownloader

    @State private var hebrewDownloadStarted = false
    @State private var hebrewError: String?

    var body: some View {
        VStack(spacing: 0) {
            header

            Form {
                Section {
                    if state.selectedLanguages.contains("en") {
                        englishRow
                    }
                    if state.selectedLanguages.contains("he") {
                        hebrewRow
                    }
                } footer: {
                    Text("Models are stored in ~/.transcribeer/models/ and are reused across sessions.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .task {
            // Auto-start Hebrew download if selected and not yet installed
            if state.selectedLanguages.contains("he"),
               !downloader.isInstalled(ModelManifest.hebrewTurbo) {
                await startHebrewDownload()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 6) {
            Text("Downloading models")
                .font(.title2)
                .fontWeight(.semibold)
        }
        .padding(.top, 24)
        .padding(.bottom, 8)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - English row

    private var englishRow: some View {
        let entry = ModelManifest.hebrewTurbo // English uses WhisperKit's openai_whisper-large-v3-turbo
        _ = entry // suppress unused warning; English model info is static
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("openai_whisper-large-v3-turbo")
                    .font(.body)
                Text("English \u{b7} ~1.6 GB")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            englishStatusBadge
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var englishStatusBadge: some View {
        if isEnglishInstalled() {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Downloaded")
        } else {
            Text("Downloads on first use")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Check whether the English WhisperKit model is already in the local snapshot cache.
    private func isEnglishInstalled() -> Bool {
        let snapshotDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                ".transcribeer/models/models/argmaxinc/whisperkit-coreml",
                isDirectory: true
            )
        let modelDir = snapshotDir.appendingPathComponent(
            "openai_whisper-large-v3-turbo",
            isDirectory: true
        )
        return FileManager.default.fileExists(atPath: modelDir.path)
    }

    // MARK: - Hebrew row

    private var hebrewRow: some View {
        let entry = ModelManifest.hebrewTurbo
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName)
                    .font(.body)
                let sizeGB = String(format: "%.1f", Double(entry.sizeBytes) / 1_000_000_000)
                Text("Hebrew \u{b7} ~\(sizeGB) GB")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let errorMsg = hebrewError {
                    Text(errorMsg)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Spacer()
            hebrewStatusBadge(entry: entry)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func hebrewStatusBadge(entry: ModelManifestEntry) -> some View {
        if downloader.isInstalled(entry) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Downloaded")
        } else if let progress = downloader.progress {
            VStack(alignment: .trailing, spacing: 4) {
                ProgressView(value: progress)
                    .frame(width: 100)
                    .progressViewStyle(.linear)
                Text("\(Int(progress * 100))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } else if !hebrewDownloadStarted {
            Button("Download") {
                Task { await startHebrewDownload() }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.accentColor)
        } else {
            ProgressView()
                .controlSize(.small)
        }
    }

    // MARK: - Download

    private func startHebrewDownload() async {
        hebrewDownloadStarted = true
        hebrewError = nil
        do {
            try await downloader.download(ModelManifest.hebrewTurbo)
        } catch {
            hebrewError = error.localizedDescription
        }
    }
}
