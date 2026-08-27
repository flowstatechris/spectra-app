import SwiftUI
import SpectraCore
import ThinkingOrbsKit

/// Orb + mono status eyebrow. Maps SessionStatus → ThinkingOrbsKit states
/// (spec §7); alert is layered as a red badge (the orb has no danger state).
struct OrbView: View {
    let status: SessionStatus
    let connectionState: HermesRPCConnection.State
    var size: OrbSize = .px64
    var showsLabel: Bool = true

    private var orbState: OrbState {
        if connectionState != .connected { return .connecting }
        switch status {
        case .idle: return .breathing
        case .connecting: return .connecting
        case .thinking(let search): return search ? .searching : .working
        case .speaking: return .composing
        case .alert: return .breathing
        }
    }

    static func label(for status: SessionStatus,
                      connectionState: HermesRPCConnection.State) -> String {
        if connectionState == .connecting { return "Connecting" }
        if connectionState == .disconnected { return "Offline" }
        switch status {
        case .idle: return "Idle"
        case .connecting: return "Connecting"
        case .thinking(let search): return search ? "Searching" : "Working"
        case .speaking: return "Composing"
        case .alert: return "Needs you"
        }
    }

    private var label: String { Self.label(for: status, connectionState: connectionState) }

    private var isAlert: Bool { if case .alert = status { return true }; return false }

    var body: some View {
        VStack(spacing: 12) {
            ThinkingOrb(state: orbState, size: size)
                .overlay(alignment: .topTrailing) {
                    if isAlert {
                        Circle().fill(Theme.danger)
                            .frame(width: 11, height: 11)
                            .overlay(Circle().strokeBorder(Theme.paper, lineWidth: 2))
                            .accessibilityLabel("Needs attention")
                    }
                }
            if showsLabel {
                Eyebrow(label, color: isAlert ? Theme.danger : Theme.muted)
            }
        }
    }
}
