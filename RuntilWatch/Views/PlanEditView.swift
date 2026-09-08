import SwiftUI
import RuntilCore

/// Adjust a plan from the wrist.
///
/// Deliberately narrower than the phone editor: only the numbers you'd want to change
/// while standing at the door in the cold. Structural changes — drive mode, adding or
/// removing segments, zone models — stay on the phone, where there's room to see what
/// you're doing.
///
/// Edits save when you leave, and are stamped so the phone's next sync won't overwrite
/// them (see `PlanMerge`).
struct PlanEditView: View {
    @State private var plan: WorkoutPlan
    private let store: PlanStore
    private let onStart: (WorkoutPlan) -> Void

    @Environment(\.dismiss) private var dismiss

    init(plan: WorkoutPlan, store: PlanStore, onStart: @escaping (WorkoutPlan) -> Void) {
        _plan = State(initialValue: plan)
        self.store = store
        self.onStart = onStart
    }

    var body: some View {
        List {
            Section {
                Button {
                    save()
                    onStart(plan)
                } label: {
                    Label("Start", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .tint(.green)
            }

            Section("Segments") {
                ForEach($plan.segments) { $segment in
                    SegmentRow(segment: $segment, units: plan.units)
                }
            }

            Section("Laps") {
                Toggle("Until I stop", isOn: Binding(
                    get: { plan.repeatCount == nil },
                    set: { plan.repeatCount = $0 ? nil : 4 }
                ))
                if let count = plan.repeatCount {
                    Stepper(value: Binding(
                        get: { count },
                        set: { plan.repeatCount = $0 }
                    ), in: 1...30) {
                        Text("\(count) laps")
                    }
                }
            }

            if plan.driveMode == .heartRate {
                Section {
                    Stepper(value: $plan.hrResponse.lagSeconds, in: 0...90, step: 5) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("HR lag")
                            Text("\(Int(plan.hrResponse.lagSeconds))s")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Stepper(value: $plan.hrResponse.approachMargin, in: 0...20) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Buffer")
                            Text("\(plan.hrResponse.approachMargin) bpm before the edge")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Response")
                } footer: {
                    Text("Switches you \(plan.hrResponse.approachMargin) bpm early, and looks \(Int(plan.hrResponse.lagSeconds))s ahead of your heart rate.")
                }
            }

            Section {
                Toggle("Save to Health", isOn: $plan.savesToHealth)
            } footer: {
                Text(plan.savesToHealth
                     ? "Saved as a workout."
                     : "Coaching only — heart rate still recorded.")
            }
        }
        .navigationTitle(plan.name)
        .navigationBarTitleDisplayMode(.inline)
        // Saving on the way out means the back chevron behaves like every other watch
        // screen — no separate confirm step to remember mid-run-prep.
        .onDisappear(perform: save)
    }

    private func save() {
        var updated = plan
        updated.touch()
        store.update(updated)
    }
}

/// One segment's trigger, rendered as whatever unit that plan's drive mode actually uses.
private struct SegmentRow: View {
    @Binding var segment: Segment
    let units: DistanceUnit

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(segment.kind.displayName.uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(segment.kind.isEffort ? .green : .orange)

            switch segment.end {
            case .duration(let seconds):
                Stepper(value: Binding(
                    get: { seconds },
                    set: { segment.end = .duration($0) }
                ), in: 10...3600, step: 15) {
                    Text(Format.duration(seconds))
                        .font(.title3)
                        .monospacedDigit()
                }

            case .distance(let meters):
                Stepper(value: Binding(
                    get: { units.units(fromMeters: meters) },
                    set: { segment.end = .distance(meters: units.meters(fromUnits: $0)) }
                ), in: 0.05...26.2, step: 0.05) {
                    Text(Format.distance(meters: meters, unit: units))
                        .font(.title3)
                        .monospacedDigit()
                }

            case .heartRateAtOrAbove(let bpm):
                Stepper(value: Binding(
                    get: { bpm },
                    set: { segment.end = .heartRateAtOrAbove(bpm: $0) }
                ), in: 60...220) {
                    Text("→ \(bpm) bpm")
                        .font(.title3)
                        .monospacedDigit()
                }

            case .heartRateAtOrBelow(let bpm):
                Stepper(value: Binding(
                    get: { bpm },
                    set: { segment.end = .heartRateAtOrBelow(bpm: $0) }
                ), in: 60...220) {
                    Text("↓ \(bpm) bpm")
                        .font(.title3)
                        .monospacedDigit()
                }

            case .manual:
                Text("Until I tap")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
