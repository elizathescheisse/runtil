import SwiftUI
import RuntilCore

struct PlanListView: View {
    let store: PlanStore
    let controller: WorkoutController

    @State private var selectedPlan: WorkoutPlan?
    @State private var useSimulation = Self.runningInSimulator

    /// The simulator has no heart rate sensor and silent haptics, so it defaults to the
    /// scripted source; a real watch always defaults to live data.
    static var runningInSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    var body: some View {
        List {
            Section {
                ForEach(store.plans) { plan in
                    Button {
                        selectedPlan = plan
                    } label: {
                        PlanRow(plan: plan)
                    }
                }
            } header: {
                Text("Plans")
            }

            if Self.runningInSimulator {
                Section {
                    Toggle("Simulated run", isOn: $useSimulation)
                } footer: {
                    Text("No sensors in the simulator. Cues are logged on screen.")
                }
            }
        }
        .navigationTitle("runtil")
        .fullScreenCover(item: $selectedPlan) { plan in
            ActiveWorkoutView(controller: controller, store: store)
                .task { await controller.start(plan: plan, simulated: useSimulation) }
        }
        .onAppear(perform: autostartIfRequested)
    }

    /// Launch with `-autostart <plan name prefix>` to jump straight into a simulated run.
    /// Used to drive the app from the command line for verification, where there's no way
    /// to tap the screen.
    private func autostartIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flagIndex = arguments.firstIndex(of: "-autostart") else { return }
        let wanted = arguments.indices.contains(flagIndex + 1) ? arguments[flagIndex + 1] : ""
        let match = wanted.isEmpty
            ? store.plans.first
            : store.plans.first { $0.name.lowercased().hasPrefix(wanted.lowercased()) }
        guard let match else { return }
        useSimulation = true
        selectedPlan = match
    }
}

private struct PlanRow: View {
    let plan: WorkoutPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(plan.name)
                .font(.headline)
                .lineLimit(1)

            HStack(spacing: 4) {
                Image(systemName: icon)
                    .imageScale(.small)
                Text(subtitle)
                    .lineLimit(1)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        switch plan.driveMode {
        case .time: return "timer"
        case .heartRate: return "heart.fill"
        case .distance: return "point.topleft.down.to.point.bottomright.curvepath"
        case .manual: return "hand.tap"
        }
    }

    private var subtitle: String {
        switch plan.driveMode {
        case .heartRate:
            let zone = plan.zones.range(forZone: plan.advisories.heartRateGuard?.zone ?? 2)
            return "\(zone.lowerBound)–\(zone.upperBound) bpm"
        case .time, .distance, .manual:
            return plan.segments.map(\.kind.displayName).joined(separator: " / ")
        }
    }
}
