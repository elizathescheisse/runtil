import Foundation
import Observation
import WatchConnectivity
import RuntilCore

/// The phone's plan library, and the source of truth that gets pushed to the watch.
@MainActor
@Observable
final class PlanLibrary: NSObject {

    private(set) var plans: [WorkoutPlan] = []
    private(set) var lastPushedAt: Date?
    private(set) var watchReachable = false

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

    // MARK: Library

    func add(_ plan: WorkoutPlan) {
        plans.append(plan)
        persistAndPush()
    }

    func update(_ plan: WorkoutPlan) {
        guard let index = plans.firstIndex(where: { $0.id == plan.id }) else { return }
        var stamped = plan
        // Stamped so the watch can tell whose edit is newer when this pushes across.
        stamped.touch()
        plans[index] = stamped
        persistAndPush()
    }

    func delete(at offsets: IndexSet) {
        plans.remove(atOffsets: offsets)
        persistAndPush()
    }

    func duplicate(_ plan: WorkoutPlan) {
        var copy = plan
        copy.id = UUID()
        copy.name += " copy"
        plans.append(copy)
        persistAndPush()
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

    private func persistAndPush() {
        if let data = try? JSONEncoder().encode(plans) {
            try? data.write(to: fileURL, options: .atomic)
        }
        push()
    }

    static var starterPlans: [WorkoutPlan] {
        let zones = HeartRateZones.estimated(age: 35)
        return [
            .zoneTwoRunWalk(zones: zones),
            .timedIntervals(run: 90, walk: 60, zones: zones),
            .distanceIntervals(run: 0.5, walk: 0.25, unit: .miles, zones: zones)
        ]
    }

    // MARK: Sync

    private func activateSession() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// Pushes the whole library to the watch.
    ///
    /// `updateApplicationContext` is the right primitive here: it keeps only the latest
    /// value and delivers it whenever the watch next wakes, which matches a small library
    /// that's fully replaced each time. `transferUserInfo` is the fallback because the
    /// context call throws if it's invoked too rapidly.
    func push() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        guard let data = try? JSONEncoder().encode(plans) else { return }

        do {
            try session.updateApplicationContext(["plans": data])
        } catch {
            session.transferUserInfo(["plans": data])
        }
        lastPushedAt = Date()
    }
}

extension PlanLibrary: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            self.watchReachable = session.isReachable
            self.push()
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.watchReachable = session.isReachable }
    }
}
