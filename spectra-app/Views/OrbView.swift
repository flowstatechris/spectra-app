import SwiftUI
import SpectraCore
import ThinkingOrbsKit

/// Maps SessionStatus → ThinkingOrbsKit states (spec §7 table, adjusted to
/// the package's real state set). Alert/attention is layered as a red badge —
/// the orb has no danger state by design.
struct OrbView: View {
    let status: SessionStatus
    let connectionState: HermesRPCConnection.State
    var size: OrbSize = .px64
    var displaySize: Double? = nil

    private var orbState: OrbState {
        if connectionState != .connected { return .connecting }
        switch status {
        case .idle: return .breathing
        case .connecting: return .connecting
        case .thinking(let search): return search ? .searching : .working
        case .speaking: return .composing
        case .alert: return .breathing   // badge carries the alarm, not the orb
        }
    }

    private var showsBadge: Bool {
        if case .alert = status { return true }
        return false
    }

    var body: some View {
        ThinkingOrb(state: orbState, size: size, displaySize: displaySize)
            .overlay(alignment: .topTrailing) {
                if showsBadge {
                    Circle()
                        .fill(.red)
                        .frame(width: 12, height: 12)
                        .accessibilityLabel("Needs attention")
                }
            }
    }
}
