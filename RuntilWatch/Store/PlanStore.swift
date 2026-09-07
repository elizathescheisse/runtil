import Foundation
import Observation
import WatchConnectivity
import RuntilCore

/// The watch's copy of the plan library.
///
/// Persisted locally and refreshed from the phone over WatchConnectivity, so a run works
/// with the phone left at home — which is the normal case for running.
///
/// Note there's no App Group here. Shared containers are awkward under free provisioning,
/// and WatchConnectivity plus a local file covers the need without that dependency.
@MainActor
@Observable
final class PlanStore: NSObject {

    private(set) var plans: [WorkoutPlan] = []
    private(set) var lastSyncedAt: Date?

    private let fileURL: URL = {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("plans.json")
    }()

    override init() {
        super.init()
        load()
        activateSession()
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([WorkoutPlan].self, from: data),
              !decoded.isEmpty
        else {
            plans = Self.starterPlans
            return
        }
        plans = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(plans) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func replaceAll(with newPlans: [WorkoutPlan]) {
        guard !newPlans.isEmpty else { return }
        plans = newPlans
        lastSyncedAt = Date()
        save()
    }

    /// Persists a tweak made on the wrist — notably a lag value accepted from the post-run
    /// summary, which shouldn't require getting the phone out.
    func update(_ plan: WorkoutPlan) {
        if let index = plans.firstIndex(where: { $0.id == plan.id }) {
            plans[index] = plan
        } else {
            plans.append(plan)
        }
        save()
    }

    // MARK: Defaults

    /// Something usable on first launch, before the phone has ever synced.
    static var starterPlans: [WorkoutPlan] {
        let zones = HeartRateZones.estimated(age: 35)
        return [
            .zoneTwoRunWalk(zones: zones),
            .timedIntervals(run: 90, walk: 60, zones: zones),
            .timedIntervals(run: 60, walk: 60, zones: zones),
            .distanceIntervals(run: 0.5, walk: 0.25, unit: .miles, zones: zones)
        ]
    }

    // MARK: WatchConnectivity

    private func activateSession() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    fileprivate func ingest(_ context: [String: Any]) {
        guard let data = context["plans"] as? Data,
              let decoded = try? JSONDecoder().decode([WorkoutPlan].self, from: data)
        else { return }
        replaceAll(with: decoded)
    }
}

extension PlanStore: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let context = session.receivedApplicationContext
        guard !context.isEmpty else { return }
        Task { @MainActor in self.ingest(context) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in self.ingest(applicationContext) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        Task { @MainActor in self.ingest(userInfo) }
    }
}
