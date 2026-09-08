import Foundation

/// Reconciles the phone's library with edits made on the watch.
///
/// The phone owns the library — it can add, rename, and delete — so the incoming list
/// defines which plans exist. But a plan edited more recently on the wrist keeps its
/// wrist version, because losing a change you made thirty seconds ago while standing at
/// the trailhead is far worse than a stale plan lingering on the phone.
///
/// Pure and side-effect free so the awkward cases are testable without two devices.
public enum PlanMerge {

    /// - Parameters:
    ///   - incoming: the library as the phone sees it.
    ///   - local: what the watch currently holds.
    /// - Returns: `incoming`, with any plan the watch edited more recently substituted in.
    public static func merge(incoming: [WorkoutPlan], local: [WorkoutPlan]) -> [WorkoutPlan] {
        // An empty push is treated as "nothing to say", not "delete everything" — a failed
        // encode or a first-run race shouldn't wipe the watch.
        guard !incoming.isEmpty else { return local }

        let localByID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        return incoming.map { remote in
            guard let mine = localByID[remote.id] else { return remote }
            return mine.modifiedAt > remote.modifiedAt ? mine : remote
        }
    }
}
