import SwiftUI
import RuntilCore

/// Pair a Bluetooth heart rate monitor.
///
/// Anything implementing the standard Bluetooth Heart Rate Service works — a chest strap,
/// an optical armband, some earbuds and bike computers — so this is a connect button
/// rather than a brand picker.
struct HeartRateMonitorView: View {
    @Bindable var monitor: HeartRateMonitor

    var body: some View {
        List {
            Section {
                LabeledContent("Status") {
                    Text(monitor.state.description)
                        .foregroundStyle(monitor.state.isConnected ? .green : .secondary)
                }
                if let bpm = monitor.heartRate {
                    LabeledContent("Heart rate") {
                        Text("\(bpm) bpm")
                            .monospacedDigit()
                            .foregroundStyle(.pink)
                    }
                }
                if monitor.poorContact {
                    Label("Poor skin contact — try wetting the sensor", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section {
                if monitor.state.isConnected {
                    Button("Disconnect", role: .destructive) { monitor.disconnect() }
                } else {
                    Button("Search for monitor") { monitor.startScanning() }
                }
            } footer: {
                Text("Put the monitor on before searching — most don't broadcast until they detect skin, and damp contacts read far better than dry ones. Once paired, runtil reconnects on its own.")
            }

            Section("What works") {
                Text("Any monitor using the standard Bluetooth heart rate profile: chest straps, optical armbands, and some earbuds and bike computers. No particular brand required.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("If you have an Apple Watch, start heart-rate plans from the watch app instead — the reading is already on your wrist, and no extra hardware is needed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Heart rate monitor")
        .navigationBarTitleDisplayMode(.inline)
    }
}
