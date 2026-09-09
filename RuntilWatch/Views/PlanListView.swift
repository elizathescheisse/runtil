import SwiftUI
import RuntilCore

struct PlanListView: View {
    let store: PlanStore
    let controller: WorkoutController

    @State private var selectedPlan: WorkoutPlan?
    /// Which plan this presentation already started.
    ///
    /// `.task` re-fires whenever the presented view's body changes — which happens the
    /// instant a run finishes and the screen switches to the summary. Guarding on "is a
    /// run active" is not enough, because a finished run isn't active, so ending a run
    /// immediately started another one.
    @State private var startedRunID: UUID?
    @State private var editingPlan: WorkoutPlan?
    @State private var useSimulation = Self.runningInSimulator

    private var coordinator: LaunchCoordinator { .shared }

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
            // Leaving the run screen doesn't stop the run, so there has to be a way back
            // to it — without this the session keeps going with no reachable End button.
            if controller.isActive, let running = controller.plan {
                Section {
                    Button {
                        selectedPlan = running
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "figure.run.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Run in progress")
                                    .font(.headline)
                                Text(running.name)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }

            Section {
                ForEach(store.plans) { plan in
                    Button {
                        selectedPlan = plan
                    } label: {
                        PlanRow(plan: plan)
                    }
                    // Tap still starts immediately — that's the common case and it stays
                    // one tap. Adjusting is a swipe away rather than an extra step.
                    .swipeActions(edge: .trailing) {
                        Button {
                            editingPlan = plan
                        } label: {
                            Label("Adjust", systemImage: "slider.horizontal.3")
                        }
                        .tint(.blue)
                    }
                }
            } header: {
                Text("Plans")
            } footer: {
                Text("Tap to start · swipe left to adjust")
                    .font(.system(size: 11))
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
        .fullScreenCover(item: $selectedPlan, onDismiss: {
            startedRunID = nil
            // Leaving a finished run returns the controller to idle, so the next plan
            // tapped starts cleanly.
            if controller.state == .finished { controller.reset() }
        }) { plan in
            ActiveWorkoutView(controller: controller, store: store)
                .task {
                    // Once per presentation, whatever SwiftUI does to the body afterwards.
                    guard startedRunID != plan.id else { return }
                    startedRunID = plan.id
                    // And never on top of a run already going — re-entering shows it.
                    guard !controller.isActive else { return }
                    await controller.start(plan: plan, simulated: useSimulation)
                }
        }
        .sheet(item: $editingPlan) { plan in
            NavigationStack {
                PlanEditView(plan: plan, store: store) { edited in
                    editingPlan = nil
                    selectedPlan = edited
                }
            }
        }
        .onAppear(perform: autostartIfRequested)
        // Siri ("start a Zone 2 run with runtil") and the complication both land here.
        .onChange(of: coordinator.requestedPlanID) { _, id in
            guard let id, let match = store.plans.first(where: { $0.id == id }) else { return }
            selectedPlan = match
            coordinator.clear()
        }
        .onOpenURL { url in
            guard url.scheme == "runtil" else { return }
            // A bare runtil://start just opens the list; naming a plan starts it directly.
            let wanted = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "plan" })?.value
            if let wanted, let match = store.plans.first(where: {
                $0.name.lowercased().contains(wanted.lowercased())
            }) {
                selectedPlan = match
            }
        }
    }

    private func autostartIfRequested() {
        // A cold launch from Siri sets the request *before* this view exists, so onChange
        // never fires for it — the pending request has to be picked up on appear too.
        if let id = coordinator.requestedPlanID,
           let match = store.plans.first(where: { $0.id == id }) {
            selectedPlan = match
            coordinator.clear()
            return
        }
        if coordinator.requestedPlanList {
            coordinator.clear()
        }

        startFromLaunchArguments()
    }

    /// Launch with `-autostart <plan name prefix>` to jump straight into a simulated run.
    /// Used to drive the app from the command line for verification, where there's no way
    /// to tap the screen.
    private func startFromLaunchArguments() {
        let arguments = ProcessInfo.processInfo.arguments

        // `-edit <name>` opens the adjust screen, for driving the app from the command
        // line where there's no way to swipe.
        if let flagIndex = arguments.firstIndex(of: "-edit"),
           arguments.indices.contains(flagIndex + 1),
           let match = named(arguments[flagIndex + 1]) {
            editingPlan = match
            return
        }

        guard let flagIndex = arguments.firstIndex(of: "-autostart") else { return }
        let wanted = arguments.indices.contains(flagIndex + 1) ? arguments[flagIndex + 1] : ""
        let match = wanted.isEmpty ? store.plans.first : named(wanted)
        guard let match else { return }
        useSimulation = true
        selectedPlan = match
    }

    private func named(_ prefix: String) -> WorkoutPlan? {
        store.plans.first { $0.name.lowercased().hasPrefix(prefix.lowercased()) }
    }
}

private struct PlanRow: View {
    let plan: WorkoutPlan

    var body: some View {
        HStack(spacing: 9) {
            // Outline means "available to start". Solid is reserved for the run actually
            // in progress, so a glance tells you whether anything is live. Always green
            // here — unlike the phone, the watch has the sensor, so nothing needs gating.
            Image(systemName: "play.circle")
                .font(.title3)
                .foregroundStyle(.green)

            details
        }
        .padding(.vertical, 2)
    }

    private var details: some View {
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
