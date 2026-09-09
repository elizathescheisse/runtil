import SwiftUI
import RuntilCore

/// Set the pace band for each kind of segment.
///
/// A band rather than a single number, because chasing an exact pace means being nagged
/// constantly — you're never precisely on it. The cue fires only when you leave the range.
struct PaceTargetEditorView: View {
    @Binding var plan: WorkoutPlan

    /// Only the kinds this plan actually contains, so a run/walk plan doesn't ask you to
    /// set a cooldown pace you'll never use.
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
                    PaceBandRows(plan: $plan, kind: kind)
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
                Text("GPS pace jumps around, so it's averaged before being judged. The grace period stops you being told you're too slow during the seconds it takes to actually get moving after a walk break.")
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

/// Fastest and slowest ends of the band for one segment kind, entered as minutes and
/// seconds per mile or kilometre — the units a runner actually thinks in.
private struct PaceBandRows: View {
    @Binding var plan: WorkoutPlan
    let kind: SegmentKind

    private var unit: DistanceUnit { plan.units }

    private var band: ClosedRange<Double>? {
        plan.advisories.paceTarget?.bandsByKind[kind]
    }

    var body: some View {
        if let band {
            // Lower seconds-per-metre is faster, so the band's lowerBound is the fast end.
            paceStepper(
                title: "Fastest",
                seconds: band.lowerBound * unit.metersPerUnit,
                onChange: { setBand(fastest: $0, slowest: band.upperBound * unit.metersPerUnit) }
            )
            paceStepper(
                title: "Slowest",
                seconds: band.upperBound * unit.metersPerUnit,
                onChange: { setBand(fastest: band.lowerBound * unit.metersPerUnit, slowest: $0) }
            )
            Text("Buzzes if you drift outside \(Format.duration(band.lowerBound * unit.metersPerUnit))–\(Format.duration(band.upperBound * unit.metersPerUnit)) per \(unit.abbreviation).")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Button("Set a target for \(kind.displayName.lowercased())") {
                setBand(
                    fastest: kind.isEffort ? 8 * 60 : 15 * 60,
                    slowest: kind.isEffort ? 10 * 60 : 20 * 60
                )
            }
        }
    }

    private func paceStepper(
        title: String,
        seconds: TimeInterval,
        onChange: @escaping (TimeInterval) -> Void
    ) -> some View {
        Stepper(
            value: Binding(get: { seconds }, set: onChange),
            in: 180...2400,
            step: 5
        ) {
            LabeledContent(title) {
                Text("\(Format.duration(seconds)) /\(unit.abbreviation)")
                    .monospacedDigit()
            }
        }
    }

    /// Keeps the two ends ordered, so dragging "fastest" past "slowest" swaps them rather
    /// than producing a band nothing can satisfy.
    private func setBand(fastest: TimeInterval, slowest: TimeInterval) {
        plan.advisories.paceTarget?.bandsByKind[kind] = PaceTarget.band(
            fastest: fastest,
            slowest: slowest,
            per: unit
        )
    }
}
