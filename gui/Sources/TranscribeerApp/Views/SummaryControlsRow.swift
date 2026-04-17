import SwiftUI

/// Compact toolbar shown above the summary body. Holds the per-summary
/// knobs — prompt profile, model, and the free-form "focus on X" field —
/// so the app-wide defaults in Settings stay untouched for one-off
/// regenerations. While the LLM is streaming, the focus field is replaced
/// with a live MM:SS timer so the strip doubles as progress.
struct SummaryControlsRow: View {
    let profiles: [String]
    let modelOptions: [SummaryModelOption]
    let isBusy: Bool
    let summaryStartedAt: Date?

    @Binding var selectedProfile: String
    @Binding var selectedModel: SummaryModelOption?
    @Binding var focus: String

    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            profilePicker
            modelPicker
            if isBusy { timerBadge } else { focusField }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var profilePicker: some View {
        Picker("Profile", selection: $selectedProfile) {
            ForEach(profiles, id: \.self) { profile in
                Text(profile).tag(profile)
            }
        }
        .labelsHidden()
        .fixedSize()
        .controlSize(.small)
        .help("Prompt profile for summarization")
        .disabled(isBusy)
    }

    private var modelPicker: some View {
        Picker("Model", selection: $selectedModel) {
            ForEach(groups, id: \.backend) { group in
                Section(group.backend.displayName) {
                    ForEach(group.options) { option in
                        Text(option.shortLabel).tag(Optional(option))
                    }
                }
            }
        }
        .labelsHidden()
        .fixedSize()
        .controlSize(.small)
        .help("Model used for this summary — doesn't change the app-wide default")
        .disabled(isBusy)
    }

    private var focusField: some View {
        TextField("Focus on… (hiring, Q3 roadmap)", text: $focus)
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .help("One-off instructions appended to the prompt for this summary only")
            .onSubmit(onSubmit)
    }

    /// Live MM:SS counter that replaces the focus field while the model is
    /// streaming. `TimelineView` refreshes the counter without re-evaluating
    /// the rest of the row every tick.
    private var timerBadge: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            if let startedAt = summaryStartedAt {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text("Summarizing… \(elapsedMMSS(since: startedAt, now: context.date))")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Summarizing…")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// Options grouped by backend for the model picker's section headers.
    /// Iterates `LLMBackend.allCases` so section order is stable regardless
    /// of the incoming array's sort.
    private var groups: [(backend: LLMBackend, options: [SummaryModelOption])] {
        let grouped = Dictionary(grouping: modelOptions, by: \.backend)
        return LLMBackend.allCases.compactMap { backend in
            guard let options = grouped[backend], !options.isEmpty else { return nil }
            return (backend, options)
        }
    }

    private func elapsedMMSS(since start: Date, now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
