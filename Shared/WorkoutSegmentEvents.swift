import Foundation
import HealthKit
import RuntilCore

/// Stores a run's segment boundaries in the workout itself, as HealthKit workout events.
///
/// Only the boundaries are written. Distance, pace and heart rate per segment are derived
/// from them at read time by `RunAnalysis.segmentBreakdown`, out of the samples HealthKit
/// already holds — so nothing is duplicated, and the numbers can improve later without
/// rewriting anyone's history.
///
/// `.segment` is HealthKit's own event type for this, which means the boundaries are also
/// visible to other apps rather than locked inside runtil.
enum WorkoutSegmentEvents {

    /// Converts recorded segments into events, relative to when the workout began.
    static func events(for records: [SegmentRecord], startingAt start: Date) -> [HKWorkoutEvent] {
        records.compactMap { record in
            // A zero-length segment is a skip pressed the instant a segment opened. It has
            // nothing to show and HealthKit has no use for an empty interval.
            guard record.duration > 0 else { return nil }
            return HKWorkoutEvent(
                type: .segment,
                dateInterval: DateInterval(
                    start: start.addingTimeInterval(record.start),
                    duration: record.duration
                ),
                metadata: [MetadataKey.segmentKind: record.kind.rawValue]
            )
        }
    }

    /// Reads the boundaries back, in the order they happened.
    ///
    /// Events without a runtil kind are ignored rather than guessed at: other apps write
    /// `.segment` events too, and a lap from some other tracker isn't a run/walk interval.
    static func segments(
        in workout: HKWorkout
    ) -> [(kind: SegmentKind, start: TimeInterval, end: TimeInterval)] {
        let start = workout.startDate
        return (workout.workoutEvents ?? [])
            .filter { $0.type == .segment }
            .compactMap { event in
                guard let raw = event.metadata?[MetadataKey.segmentKind] as? String,
                      let kind = SegmentKind(rawValue: raw)
                else { return nil }
                let interval = event.dateInterval
                return (
                    kind,
                    interval.start.timeIntervalSince(start),
                    interval.end.timeIntervalSince(start)
                )
            }
            .sorted { $0.start < $1.start }
    }
}
