import SwiftUI

/// Compact horizontal pill row showing the metadata captured for a single
/// pipeline stage: provider · model, token counts, USD cost, generation
/// duration. Used at the top of the summary and transcript tabs.
///
/// Individual badges hide themselves when the underlying value is `nil` so
/// the same view works for both stages (transcription has no token counts;
/// local backends have no cost).
struct PipelineUsageBadges: View {
    let usage: PipelineUsage

    var body: some View {
        HStack(spacing: 6) {
            badge(systemName: "cpu", text: "\(usage.backend) · \(usage.model)")

            if let totalTokens = usage.totalTokens {
                badge(systemName: "number", text: tokenLabel(total: totalTokens))
                    .help(tokenTooltip)
            }

            if let costText = costLabel {
                badge(systemName: "dollarsign.circle", text: costText, prominent: true)
            }

            if usage.durationSeconds > 0 {
                badge(systemName: "timer", text: durationLabel)
            }
        }
        .font(.system(size: 11, weight: .medium))
    }

    private func badge(systemName: String, text: String, prominent: Bool = false) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemName)
                .font(.system(size: 9, weight: .semibold))
            Text(text)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .foregroundStyle(prominent ? Color.accentColor : .secondary)
        .background(
            (prominent ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.12)),
            in: Capsule(),
        )
    }

    private var tokenTooltip: String {
        var parts: [String] = []
        if let input = usage.inputTokens { parts.append("\(input.formatted()) in") }
        if let output = usage.outputTokens { parts.append("\(output.formatted()) out") }
        return parts.joined(separator: " · ")
    }

    private func tokenLabel(total: Int) -> String {
        "\(Self.compactNumber(total)) tokens"
    }

    private var costLabel: String? {
        guard let cost = usage.costUSD else { return nil }
        if cost == 0 { return "free" }
        // Sub-cent values get more decimals so a $0.0008 summary isn't
        // rounded down to "$0.00" — that would look like a bug.
        let format: FloatingPointFormatStyle<Double>.Currency = cost < 0.01
            ? .currency(code: "USD").precision(.fractionLength(4))
            : .currency(code: "USD").precision(.fractionLength(2...4))
        return cost.formatted(format)
    }

    private var durationLabel: String {
        let seconds = usage.durationSeconds
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let minutes = Int(seconds) / 60
        let remainder = Int(seconds) % 60
        return "\(minutes)m \(remainder)s"
    }

    /// Format token counts compactly: `1.2k`, `345`, `2.3M`. Mirrors
    /// `NumberFormatter.Style.compact` but stays sync and locale-stable for
    /// a stat we just want to read at a glance.
    private static func compactNumber(_ value: Int) -> String {
        switch value {
        case 0..<1_000:
            return "\(value)"
        case 1_000..<1_000_000:
            return String(format: "%.1fk", Double(value) / 1_000).replacingOccurrences(of: ".0k", with: "k")
        default:
            return String(format: "%.1fM", Double(value) / 1_000_000).replacingOccurrences(of: ".0M", with: "M")
        }
    }
}
