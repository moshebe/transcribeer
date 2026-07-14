import SwiftUI

/// A compact, non-dismissable status banner that appears when `ResourceGovernor`
/// reports a degraded operating state (thermal pressure, low power, or recent
/// memory pressure).
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

        // Recent memory pressure (within 60 s) counts as degraded.
        if let event = governor.lastMemoryPressureEvent,
           Date().timeIntervalSince(event) <= 60 {
            return "Reduced performance — memory low."
        }

        return nil
    }
}
