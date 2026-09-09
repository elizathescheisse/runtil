import SwiftUI
import RuntilCore

struct PlanLibraryView: View {
    @Bindable var library: PlanLibrary
    @State private var editingPlan: WorkoutPlan?
    @State private var showingNewPlanOptions = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(library.plans) { plan in
                        Button {
                            editingPlan = plan
                        } label: {
                            PlanSummaryRow(plan: plan)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button("Duplicate") { library.duplicate(plan) }
                                .tint(.blue)
                        }
                    }
                    .onDelete(perform: library.delete)
                } footer: {
                    SyncFooter(library: library)
                }
            }
            .navigationTitle("Plans")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingNewPlanOptions = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(item: $editingPlan) { plan in
                PlanEditorView(plan: plan) { library.update($0) }
            }
            .confirmationDialog("New plan", isPresented: $showingNewPlanOptions, titleVisibility: .visible) {
                Button("Zone 2 run/walk") {
                    editingPlan = .zoneTwoRunWalk(zones: defaultZones)
                }
                Button("Timed intervals") {
                    editingPlan = .timedIntervals(run: 90, walk: 60, zones: defaultZones)
                }
                Button("Distance intervals") {
                    editingPlan = .distanceIntervals(run: 0.5, walk: 0.25, unit: .miles, zones: defaultZones)
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    /// Carry the zone and lag settings forward from an existing plan, so they're configured
    /// once rather than re-entered for every new plan.
    private var defaultZones: HeartRateZones {
        library.plans.first?.zones ?? HeartRateZones.estimated(age: 35)
    }
}

private struct PlanSummaryRow: View {
    let plan: WorkoutPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(plan.name).font(.headline)
                Spacer()
                Label(plan.driveMode.displayName, systemImage: icon)
                    .font(.caption2)
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.secondary)
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        switch plan.driveMode {
        case .time: return "timer"
        case .heartRate: return "heart.fill"
        case .distance: return "figure.run"
        case .manual: return "hand.tap"
        }
    }

    private var detail: String {
        let segments = plan.segments.map { segment -> String in
            switch segment.end {
            case .duration(let d): return "\(segment.kind.displayName) \(Format.compactDuration(d))"
            case .distance(let m): return "\(segment.kind.displayName) \(Format.distance(meters: m, unit: plan.units, decimals: 2))"
            case .heartRateAtOrAbove(let bpm): return "\(segment.kind.displayName) → \(bpm)"
            case .heartRateAtOrBelow(let bpm): return "\(segment.kind.displayName) → \(bpm)"
            case .manual: return segment.kind.displayName
            }
        }
        return segments.joined(separator: " · ")
    }
}

private struct SyncFooter: View {
    let library: PlanLibrary

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: library.watchReachable ? "applewatch" : "applewatch.slash")
            if let pushed = library.lastPushedAt {
                Text("Synced \(pushed.formatted(date: .omitted, time: .shortened))")
            } else {
                Text("Not yet synced")
            }
        }
        .font(.caption2)
    }
}
