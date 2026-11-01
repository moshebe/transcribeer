import SwiftUI

/// A compact, non-dismissable status banner that appears when `ResourceGovernor`
/// reports thermal pressure or Low Power Mode.
///
/// Automatically disappears when the condition clears — no dismiss button needed.
struct ResourceStatusBanner: View {
    @Environment(ResourceGovernor.self) private var governor

    var body: some View {
        if let message = degradedMessage {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.orange.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: - Private

    private var degradedMessage: String? {
        // Suppressed when the user has opted out of reduced performance mode.
        guard !governor.isThrottlingDisabled else { return nil }

        // Thermal takes priority over power mode in the message hierarchy.
        switch governor.thermalState {
        case .critical, .serious:
            return "Reduced performance — Mac is warm."
        default:
            break
        }

        if governor.isLowPowerMode {
            return "Reduced performance — Low Power Mode is on."
        }

        return nil
    }
}
