import Foundation

/// Metadata keys runtil writes onto a workout that HealthKit has no standard key for.
///
/// Namespaced so they can't collide with Apple's, and shared between the writers and the
/// detail screen so the string is never typed twice.
public enum MetadataKey {
    /// Dew point in degrees Celsius — the number that actually predicts how hard the air
    /// makes a run, and which HealthKit has no key of its own for.
    public static let dewPointCelsius = "com.ergilp.runtil.dewPointCelsius"

    /// Which kind of segment a `.segment` workout event was. HealthKit records that a lap
    /// happened but has no notion of it being a run rather than a walk, and that
    /// distinction is the whole point of the breakdown.
    public static let segmentKind = "com.ergilp.runtil.segmentKind"
}
