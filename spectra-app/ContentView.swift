import SwiftUI
import SpectraCore
import ThinkingOrbsKit

// Temporary wiring check — replaced by real screens in the UI slice.
struct ContentView: View {
    var body: some View {
        VStack(spacing: 24) {
            ThinkingOrb(state: .breathing, size: .px64)
            Text("Spectra")
                .font(.title2)
        }
    }
}
