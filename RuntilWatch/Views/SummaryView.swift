import SwiftUI
import RuntilCore

struct SummaryView: View {
    let controller: WorkoutController
    let store: PlanStore
    let onDone: () -> Void

    @State private var appliedLag = false
    @State private var appliedPace = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Nice work")
                    .font(.headline)

                LabeledContent("Time") { Text(Format.duration(controller.elapsed)) }
                LabeledContent("Distance") {
                    Text(Format.distance(meters: controller.distance, unit: controller.plan?.units ?? .miles))
                }
                if let engine = controller.engine {
                    LabeledContent("Laps") { Text("\(engine.cycle)") }
                }

                if let suggestion = controller.measuredLagSuggestion,
                   let plan = controller.plan {
                    Divider()
                    LagCalibrationCard(
                        plan: plan,
                        suggestion: suggestion,
                        applied: appliedLag,
                        onApply: { apply(suggestion, to: plan) }
                    )
                }

                if let pace = controller.paceSuggestion, let plan = controller.plan {
                    Divider()
                    PaceCalibrationCard(
                        plan: plan,
                        suggestion: pace.suggestion,
                        kind: pace.kind,
                        applied: appliedPace,
                        onApply: { applyPace(pace.suggestion, kind: pace.kind, to: plan) }
                    )
                }

                Button("Done", action: onDone)
                    .padding(.top, 4)
            }
            .font(.caption)
            .padding(.horizontal, 4)
        }
    }

    private func apply(_ suggestion: TimeInterval, to plan: WorkoutPlan) {
        var updated = plan
        updated.hrResponse.lagSeconds = suggestion.rounded()
        store.update(updated)
        appliedLag = true
    }

    private func applyPace(
        _ suggestion: PaceCalibration.Suggestion,
        kind: SegmentKind,
        to plan: WorkoutPlan
    ) {
        var updated = plan
        updated.advisories.paceTarget?.bandsByKind[kind]?.toleranceSecondsPerMeter =
            suggestion.suggestedTolerance
        store.update(updated)
        appliedPace = true
    }
}

/// Offers to widen a pace band that turned out too tight, using what the run actually did.
///
/// The same idea as lag calibration: the number is decided afterwards, with evidence, not
/// mid-stride from memory.
private struct PaceCalibrationCard: View {
    let plan: WorkoutPlan
    let suggestion: PaceCalibration.Suggestion
    let kind: SegmentKind
    let applied: Bool
    let onApply: () -> Void

    private var unit: DistanceUnit { plan.units }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Pace cues", systemImage: "speedometer")
                .font(.caption.weight(.semibold))

            Text("Fired \(suggestion.cueCount) times. You ran \(Format.duration(suggestion.observedRange.lowerBound * unit.metersPerUnit))–\(Format.duration(suggestion.observedRange.upperBound * unit.metersPerUnit)) /\(unit.abbreviation).")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if applied {
                Label("Widened", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
            } else {
                Button("Widen to ±\(Int(suggestion.suggestedTolerance * unit.metersPerUnit))s", action: onApply)
                    .font(.system(size: 12))
            }
        }
    }
}

/// Closes the loop on the lag setting: rather than leaving you to guess, the app measures
/// how long your heart rate actually took to respond during this run and offers the number.
private struct LagCalibrationCard: View {
    let plan: WorkoutPlan
    let suggestion: TimeInterval
    let applied: Bool
    let onApply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Heart rate lag", systemImage: "waveform.path.ecg")
                .font(.caption.weight(.semibold))

            Text("Measured \(Int(suggestion.rounded()))s this run · currently set to \(Int(plan.hrResponse.lagSeconds))s")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if applied {
                Label("Updated", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
            } else if abs(suggestion - plan.hrResponse.lagSeconds) >= 3 {
                Button("Use \(Int(suggestion.rounded()))s", action: onApply)
                    .font(.system(size: 12))
            } else {
                Text("Close to your setting — no change needed.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
