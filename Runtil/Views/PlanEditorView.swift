import SwiftUI
import RuntilCore

struct PlanEditorView: View {
    @State private var plan: WorkoutPlan
    let onSave: (WorkoutPlan) -> Void

    @Environment(\.dismiss) private var dismiss

    init(plan: WorkoutPlan, onSave: @escaping (WorkoutPlan) -> Void) {
        _plan = State(initialValue: plan)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Plan") {
                    TextField("Name", text: $plan.name)
                    Picker("Units", selection: $plan.units) {
                        ForEach(DistanceUnit.allCases, id: \.self) { unit in
                            Text(unit.rawValue.capitalized).tag(unit)
                        }
                    }
                }

                Section {
                    Picker("Switch on", selection: $plan.driveMode) {
                        ForEach(DriveMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .onChange(of: plan.driveMode) { _, newMode in
                        retargetSegments(to: newMode)
                    }
                } header: {
                    Text("Drive mode")
                } footer: {
                    Text(plan.driveMode.explanation)
                }

                SegmentsSection(plan: $plan)

                Section("Repeat") {
                    Toggle("Repeat until I stop", isOn: Binding(
                        get: { plan.repeatCount == nil },
                        set: { plan.repeatCount = $0 ? nil : 4 }
                    ))
                    if let count = plan.repeatCount {
                        Stepper("\(count) laps", value: Binding(
                            get: { count },
                            set: { plan.repeatCount = $0 }
                        ), in: 1...50)
                    }
                }

                Section {
                    NavigationLink {
                        ZoneEditorView(zones: $plan.zones)
                    } label: {
                        LabeledContent("Heart rate zones") {
                            let z2 = plan.zones.range(forZone: 2)
                            Text("Z2 \(z2.lowerBound)–\(z2.upperBound)")
                        }
                    }
                    NavigationLink {
                        ResponseProfileEditorView(profile: $plan.hrResponse)
                    } label: {
                        LabeledContent("Heart rate response") {
                            Text("\(Int(plan.hrResponse.lagSeconds))s lag")
                        }
                    }
                }

                AdvisoriesSection(plan: $plan)

                Section {
                    Toggle("Save run to Health", isOn: $plan.savesToHealth)
                } header: {
                    Text("Recording")
                } footer: {
                    Text(plan.savesToHealth
                         ? "runtil saves this run to Health as a complete workout, so it counts toward your rings and other apps can import it."
                         : "runtil coaches without saving a workout, so a second app recording the same run doesn't leave two overlapping entries in Health.\n\nYour heart rate is still recorded either way. Holding a workout session is what makes the watch measure heart rate continuously instead of every few minutes, and those readings stay in Health for the other app to pick up.\n\nApple Watch allows only one workout at a time, so the other app has to be tracking from your phone, not your watch.")
                }
            }
            .navigationTitle("Edit plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(plan)
                        dismiss()
                    }
                }
            }
        }
    }

    /// Switching drive mode rewrites each segment's trigger to one that mode can actually
    /// use, so a plan can never end up with segments that contradict its own mode.
    private func retargetSegments(to mode: DriveMode) {
        let z2 = plan.zones.range(forZone: 2)
        plan.segments = plan.segments.map { segment in
            var updated = segment
            switch mode {
            case .time:
                if case .duration = segment.end {} else {
                    updated.end = .duration(segment.kind.isEffort ? 90 : 60)
                }
            case .distance:
                if case .distance = segment.end {} else {
                    updated.end = .distance(meters: plan.units.meters(fromUnits: segment.kind.isEffort ? 0.5 : 0.25))
                }
            case .heartRate:
                updated.end = segment.kind.isEffort
                    ? .heartRateAtOrAbove(bpm: z2.upperBound)
                    : .heartRateAtOrBelow(bpm: z2.lowerBound)
                updated.minDuration = plan.hrResponse.effectiveMinSegmentDuration
                updated.maxDuration = plan.hrResponse.maxSegmentDuration
            case .manual:
                updated.end = .manual
            }
            return updated
        }
    }
}

// MARK: - Segments

private struct SegmentsSection: View {
    @Binding var plan: WorkoutPlan

    var body: some View {
        Section {
            ForEach($plan.segments) { $segment in
                SegmentEditorRow(segment: $segment, plan: plan)
            }
            .onDelete { plan.segments.remove(atOffsets: $0) }
            .onMove { plan.segments.move(fromOffsets: $0, toOffset: $1) }

            Button {
                plan.segments.append(newSegment())
            } label: {
                Label("Add segment", systemImage: "plus.circle")
            }
        } header: {
            Text("Segments")
        } footer: {
            Text("These cycle in order for the whole workout.")
        }
    }

    private func newSegment() -> Segment {
        let effort = plan.segments.last?.kind.isEffort != true
        let kind: SegmentKind = effort ? .run : .walk
        let z2 = plan.zones.range(forZone: 2)

        switch plan.driveMode {
        case .time:
            return Segment(kind: kind, end: .duration(effort ? 90 : 60))
        case .distance:
            return Segment(kind: kind, end: .distance(meters: plan.units.meters(fromUnits: effort ? 0.5 : 0.25)))
        case .heartRate:
            return Segment(
                kind: kind,
                end: effort ? .heartRateAtOrAbove(bpm: z2.upperBound) : .heartRateAtOrBelow(bpm: z2.lowerBound),
                minDuration: plan.hrResponse.effectiveMinSegmentDuration,
                maxDuration: plan.hrResponse.maxSegmentDuration
            )
        case .manual:
            return Segment(kind: kind, end: .manual)
        }
    }
}

private struct SegmentEditorRow: View {
    @Binding var segment: Segment
    let plan: WorkoutPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Kind", selection: $segment.kind) {
                ForEach(SegmentKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }

            switch segment.end {
            case .duration(let seconds):
                Stepper(
                    "For \(Format.duration(seconds))",
                    value: Binding(
                        get: { seconds },
                        set: { segment.end = .duration($0) }
                    ),
                    in: 10...3600,
                    step: 15
                )

            case .distance(let meters):
                Stepper(
                    "For \(Format.distance(meters: meters, unit: plan.units, decimals: 2))",
                    value: Binding(
                        get: { plan.units.units(fromMeters: meters) },
                        set: { segment.end = .distance(meters: plan.units.meters(fromUnits: $0)) }
                    ),
                    in: 0.05...26.2,
                    step: 0.05
                )

            case .heartRateAtOrAbove(let bpm):
                Stepper(
                    "Until near \(bpm) bpm ↑",
                    value: Binding(
                        get: { bpm },
                        set: { segment.end = .heartRateAtOrAbove(bpm: $0) }
                    ),
                    in: 60...220
                )

            case .heartRateAtOrBelow(let bpm):
                Stepper(
                    "Until near \(bpm) bpm ↓",
                    value: Binding(
                        get: { bpm },
                        set: { segment.end = .heartRateAtOrBelow(bpm: $0) }
                    ),
                    in: 60...220
                )

            case .manual:
                Text("Until I tap")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Advisories

private struct AdvisoriesSection: View {
    @Binding var plan: WorkoutPlan

    var body: some View {
        Section {
            Toggle("Zone warnings", isOn: Binding(
                get: { plan.advisories.heartRateGuard != nil },
                set: { plan.advisories.heartRateGuard = $0 ? HeartRateGuard() : nil }
            ))
            .disabled(plan.driveMode == .heartRate)

            Toggle("Distance splits", isOn: Binding(
                get: { plan.advisories.distanceSplits != nil },
                set: { plan.advisories.distanceSplits = $0 ? .every(0.5, plan.units) : nil }
            ))

            if let splits = plan.advisories.distanceSplits {
                Stepper(
                    "Every \(Format.distance(meters: splits.everyMeters, unit: plan.units, decimals: 2))",
                    value: Binding(
                        get: { plan.units.units(fromMeters: splits.everyMeters) },
                        set: { plan.advisories.distanceSplits?.everyMeters = plan.units.meters(fromUnits: $0) }
                    ),
                    in: 0.1...5,
                    step: 0.1
                )
            }
        } header: {
            Text("Advisories")
        } footer: {
            if plan.driveMode == .heartRate {
                Text("Zone warnings are off for heart-rate plans — the switch itself already tells you to change effort.")
            } else {
                Text("Extra buzzes that don't change your segment.")
            }
        }
    }
}
