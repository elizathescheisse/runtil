import Foundation
import RuntilCore

/// Where the watch keeps its plan library on disk.
///
/// Pulled out of `PlanStore` because Siri's intent query needs to read the same plans
/// without touching the main-actor store — App Intents can be resolved before, or
/// independently of, any UI existing.
enum PlanFile {

    static var url: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("plans.json")
    }

    static func load() -> [WorkoutPlan] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([WorkoutPlan].self, from: data),
              !decoded.isEmpty
        else { return defaults }
        return decoded
    }

    static func save(_ plans: [WorkoutPlan]) {
        guard let data = try? JSONEncoder().encode(plans) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Something usable on first launch, before the phone has ever synced.
    static var defaults: [WorkoutPlan] {
        let zones = HeartRateZones.estimated(age: 35)
        return [
            .zoneTwoRunWalk(zones: zones),
            .timedIntervals(run: 90, walk: 60, zones: zones),
            .timedIntervals(run: 60, walk: 60, zones: zones),
            .distanceIntervals(run: 0.5, walk: 0.25, unit: .miles, zones: zones)
        ]
    }
}
