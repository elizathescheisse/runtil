import SwiftUI
import RuntilCore

/// Pair a Bluetooth heart rate strap.
///
/// Any strap implementing the standard Heart Rate Service works, which is all of them —
/// so this is a connect button rather than a brand picker.
struct StrapSettingsView: View {
    @Bindable var strap: HeartRateStrap

    var body: some View {
        List {
            Section {
                LabeledContent("Status") {
                    Text(strap.state.description)
                        .foregroundStyle(strap.state.isConnected ? .green : .secondary)
                }
                if let bpm = strap.heartRate {
                    LabeledContent("Heart rate") {
                        Text("\(bpm) bpm")
                            .monospacedDigit()
                            .foregroundStyle(.pink)
                    }
                }
                if strap.poorContact {
                    Label("Poor skin contact — try wetting the strap", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section {
                if strap.state.isConnected {
                    Button("Disconnect", role: .destructive) { strap.disconnect() }
                } else {
                    Button("Search for strap") { strap.startScanning() }
                }
            } footer: {
                Text("Wear the strap and moisten the contacts before searching — most straps don't advertise until they detect skin. Once paired, runtil reconnects on its own.")
            }

            Section("Why a strap") {
                Text("Your iPhone can't measure heart rate on its own, so heart-rate plans need one. A chest strap also reads more accurately than a wrist sensor while running, where arm motion causes trouble.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Heart rate strap")
        .navigationBarTitleDisplayMode(.inline)
    }
}
