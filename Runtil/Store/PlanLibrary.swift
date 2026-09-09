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

    /// Set when zones were filled in from Health, so the app can say what it did rather
    /// than silently changing numbers the user is about to train against.
    private(set) var importedProfile: HealthProfileImporter.Profile?

    private var hasImportedHealthProfile: Bool {
        get { UserDefaults.standard.bool(forKey: "didImportHealthProfile") }
        set { UserDefaults.standard.set(newValue, forKey: "didImportHealthProfile") }
    }

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

    /// Saves a plan, inserting it if it's new.
    ///
    /// An upsert rather than a strict update: the editor is used for both creating and
    /// editing, so refusing unknown ids meant a newly created plan was silently discarded
    /// the moment you pressed Save — the sheet closed and nothing happened.
    func update(_ plan: WorkoutPlan) {
        var stamped = plan
        // Stamped so the watch can tell whose edit is newer when this pushes across.
        stamped.touch()

        if let index = plans.firstIndex(where: { $0.id == stamped.id }) {
            plans[index] = stamped
        } else {
            plans.append(stamped)
        }
        persistAndPush()
    }

    func delete(at offsets: IndexSet) {
        plans.remove(atOffsets: offsets)
        persistAndPush()
    }

    func delete(_ plan: WorkoutPlan) {
        plans.removeAll { $0.id == plan.id }
        persistAndPush()
    }

    func duplicate(_ plan: WorkoutPlan) {
        var copy = plan
        copy.id = UUID()
        copy.name += " copy"
        plans.append(copy)
        persistAndPush()
    }

    /// Fills in zones from Health on first launch.
    ///
    /// Opening on an invented 35-year-old and waiting to be corrected is a poor default
    /// when the real numbers are sitting in Health — a wrong Zone 2 is not a cosmetic
    /// problem, it is training in the wrong range without knowing.
    ///
    /// Runs once, and only touches plans still on the placeholder. Anything chosen or
    /// edited is left alone: filling in a guess is helpful, overwriting a decision is not.
    func applyHealthProfileIfNeeded() async {
        guard !hasImportedHealthProfile else { return }

        let importer = HealthProfileImporter()
        await importer.load()
        let profile = importer.profile

        // Nothing usable — leave the flag unset so a later launch can try again, once
        // permission is granted or the watch has recorded a resting rate.
        guard profile.hasAnything, let maxHR = profile.bestMaxHeartRate else { return }

        hasImportedHealthProfile = true

        let zones: HeartRateZones
        if let resting = profile.restingHeartRate {
            zones = HeartRateZones(method: .karvonen(maxHR: maxHR, restingHR: resting))
        } else {
            zones = HeartRateZones(method: .percentMax(maxHR: maxHR))
        }

        var changed = false
        plans = plans.map { plan in
            guard plan.zones.isUnpersonalisedDefault else { return plan }
            var updated = plan
            updated.zones = zones
            updated.retargetHeartRateSegments(using: zones)
            updated.touch()
            changed = true
            return updated
        }

        if changed {
            importedProfile = profile
            persistAndPush()
        }
    }

    func dismissImportNotice() {
        importedProfile = nil
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
