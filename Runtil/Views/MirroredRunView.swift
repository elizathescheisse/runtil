import SwiftUI
import RuntilCore

/// A run happening on your wrist, shown on the phone.
///
/// Read-only on purpose. The watch holds the session and plays the cues; adding controls
/// here would invite the two devices to disagree about a run only one of them is actually
/// running.
struct MirroredRunView: View {
    let state: MirroredState
    let isActive: Bool

    var body: some View {
        VStack(spacing: 18) {
            Label(isActive ? "Running on your watch" : "Run finished", systemImage: "applewatch")
                .font(.caption)
                .foregroundStyle(isActive ? .green : .secondary)
                .padding(.top, 12)

            Text(state.planName)
                .font(.headline)
                .foregroundStyle(.secondary)

            VStack(spacing: 2) {
                Text(state.segmentKind?.displayName.uppercased() ?? "—")
                    .font(.system(size: 40, weight: .heavy, design: .rounded))
                    .foregroundStyle((state.segmentKind?.isEffort ?? true) ? .green : .orange)

                Text(Format.duration(state.timeRemainingInSegment ?? state.timeInSegment))
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(state.timeRemainingInSegment == nil ? .secondary : .primary)
            }

            HStack(spacing: 0) {
                Metric(title: "Distance",
                       value: Format.distance(meters: state.distanceMeters, unit: state.units))
                Metric(title: "Pace",
                       value: Format.pace(secondsPerMeter: state.paceSecondsPerMeter, unit: state.units))
                Metric(title: "Heart", value: heartRateText)
            }

            HStack(spacing: 16) {
                Text("Lap \(state.cycle + 1)")
                Text(Format.duration(state.elapsed)).monospacedDigit()
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            if let cue = state.lastCueSummary {
                Label(cue, systemImage: "waveform")
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.quaternary, in: Capsule())
            }

            Spacer()

            Text("Controls stay on the watch — it's the device running the session.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 8)
        }
        .padding()
    }

    /// Shows the projection alongside the reading when they differ, matching the watch.
    private var heartRateText: String {
        guard let bpm = state.heartRate else { return "—" }
        if let projected = state.projectedHeartRate, abs(projected - bpm) >= 3 {
            return "\(bpm) → \(projected)"
        }
        return "\(bpm)"
    }
}

private struct Metric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
