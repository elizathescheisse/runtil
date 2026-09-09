import SwiftUI
import RuntilCore

/// Set a target pace and how much drift is acceptable.
///
/// One number and a tolerance, not two endpoints — "around 9:30" is how running is
/// actually thought about, and it means the default can be genuinely useful rather than
/// something you're forced to configure before the feature works.
struct PaceTargetEditorView: View {
    @Binding var plan: WorkoutPlan

    /// Only the kinds this plan contains, so a run/walk plan doesn't ask for a cooldown
    /// pace it will never use.
    private var kinds: [SegmentKind] {
        var seen: [SegmentKind] = []
        for segment in plan.segments where !seen.contains(segment.kind) {
            seen.append(segment.kind)
        }
        return seen
    }

    var body: some View {
        Form {
            ForEach(kinds, id: \.self) { kind in
                Section(kind.displayName) {
                    PaceRows(plan: $plan, kind: kind)
                }
            }

            Section {
                Stepper(value: paceBinding(\.window), in: 10...60, step: 5) {
                    LabeledContent("Averaged over") {
                        Text("\(Int(plan.advisories.paceTarget?.window ?? 25))s")
                    }
                }
                Stepper(value: paceBinding(\.cooldown), in: 10...120, step: 5) {
                    LabeledContent("Quiet period") {
                        Text("\(Int(plan.advisories.paceTarget?.cooldown ?? 30))s")
                    }
                }
                Stepper(value: paceBinding(\.graceAfterSegmentStart), in: 0...60, step: 5) {
                    LabeledContent("Grace at segment start") {
                        Text("\(Int(plan.advisories.paceTarget?.graceAfterSegmentStart ?? 20))s")
                    }
                }
            } header: {
                Text("Sensitivity")
            } footer: {
                Text("GPS pace jumps around, so it's averaged before being judged. The grace period stops you being told you're too slow during the seconds it takes to get moving after a walk break.")
            }
        }
        .navigationTitle("Target pace")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func paceBinding(_ key: WritableKeyPath<PaceTarget, TimeInterval>) -> Binding<TimeInterval> {
        Binding(
            get: { plan.advisories.paceTarget?[keyPath: key] ?? 25 },
            set: { plan.advisories.paceTarget?[keyPath: key] = $0 }
        )
    }
}

private struct PaceRows: View {
    @Binding var plan: WorkoutPlan
    let kind: SegmentKind

    private var unit: DistanceUnit { plan.units }
    private var band: PaceBand? { plan.advisories.paceTarget?.bandsByKind[kind] }

    /// Named tolerances, so the choice is about terrain rather than arithmetic.
    private static let choices: [(label: String, seconds: TimeInterval, note: String)] = [
        ("Tight", 10, "Track or treadmill. GPS noise alone may trigger cues outdoors."),
        ("Normal", 20, "Roads and mixed terrain."),
        ("Loose", 40, "Hills and trails, where pace swings at steady effort.")
    ]

    var body: some View {
        if let band {
            Stepper(
                value: Binding(
                    get: { band.target(in: unit) },
                    set: { update(target: $0, tolerance: band.tolerance(in: unit)) }
                ),
                in: 180...2400,
                step: 5
            ) {
                LabeledContent("Target") {
                    Text("\(Format.duration(band.target(in: unit))) /\(unit.abbreviation)")
                        .monospacedDigit()
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Tolerance")
                    .font(.subheadline)
                HStack(spacing: 8) {
                    ForEach(Self.choices, id: \.label) { choice in
                        Button(choice.label) {
                            update(target: band.target(in: unit), tolerance: choice.seconds)
                        }
                        .buttonStyle(.bordered)
                        .tint(abs(band.tolerance(in: unit) - choice.seconds) < 1 ? .accentColor : .secondary)
                    }
                }
                Stepper(
                    value: Binding(
                        get: { band.tolerance(in: unit) },
                        set: { update(target: band.target(in: unit), tolerance: $0) }
                    ),
                    in: 5...120,
                    step: 5
                ) {
                    Text("±\(Int(band.tolerance(in: unit)))s")
                        .monospacedDigit()
                }
                if let note = Self.choices.first(where: { abs(band.tolerance(in: unit) - $0.seconds) < 1 })?.note {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text("Cues if you leave \(Format.duration(band.range.lowerBound * unit.metersPerUnit))–\(Format.duration(band.range.upperBound * unit.metersPerUnit)) /\(unit.abbreviation).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        } else {
            Button("Set a target for \(kind.displayName.lowercased())") {
                update(target: kind.isEffort ? 9 * 60 : 17 * 60, tolerance: nil)
            }
        }
    }

    private func update(target: TimeInterval, tolerance: TimeInterval?) {
        plan.advisories.paceTarget?.bandsByKind[kind] = .perUnit(
            target: target,
            tolerance: tolerance,
            unit: unit
        )
    }
}
