import Foundation

/// Cues that fire regardless of what's driving segment transitions.
///
/// A time-driven plan can still warn you about heart rate; an HR-driven plan can still
/// call out half-mile splits. Only the drive mode moves you between segments — advisories
/// are pure information.
public struct Advisories: Codable, Hashable, Sendable {
    public var heartRateGuard: HeartRateGuard?
    public var paceTarget: PaceTarget?
    public var distanceSplits: DistanceSplits?
    /// Bare BPM lines you want flagged whenever crossed, in either direction.
    public var thresholdCrossings: [Int]

    public init(
        heartRateGuard: HeartRateGuard? = nil,
        paceTarget: PaceTarget? = nil,
        distanceSplits: DistanceSplits? = nil,
        thresholdCrossings: [Int] = []
    ) {
        self.heartRateGuard = heartRateGuard
        self.paceTarget = paceTarget
        self.distanceSplits = distanceSplits
        self.thresholdCrossings = thresholdCrossings
    }

    public static let none = Advisories()
}

/// Warns you as you approach the edges of a target zone.
public struct HeartRateGuard: Codable, Hashable, Sendable {
    /// Which zone to police. 2 for the classic easy-aerobic run.
    public var zone: Int
    /// Warn when nearing the top of the zone.
    public var watchCeiling: Bool
    /// Warn when drifting below the bottom of the zone.
    public var watchFloor: Bool

    public init(zone: Int = 2, watchCeiling: Bool = true, watchFloor: Bool = true) {
        self.zone = zone
        self.watchCeiling = watchCeiling
        self.watchFloor = watchFloor
    }
}

/// Target pace band, stored as seconds per meter so the engine stays metric.
public struct PaceTarget: Codable, Hashable, Sendable {
    /// Per segment kind, so running and walking can have different targets.
    public var bandsByKind: [SegmentKind: ClosedRange<Double>]
    /// Rolling average window. Instantaneous GPS pace is far too jittery to cue on.
    public var window: TimeInterval
    public var cooldown: TimeInterval
    /// Ignore pace entirely for this long after a segment starts, so you aren't scolded
    /// for being "too slow" during the seconds it takes to actually get moving.
    public var graceAfterSegmentStart: TimeInterval

    public init(
        bandsByKind: [SegmentKind: ClosedRange<Double>] = [:],
        window: TimeInterval = 25,
        cooldown: TimeInterval = 30,
        graceAfterSegmentStart: TimeInterval = 20
    ) {
        self.bandsByKind = bandsByKind
        self.window = window
        self.cooldown = cooldown
        self.graceAfterSegmentStart = graceAfterSegmentStart
    }

    /// Build a band from human units: minutes-and-seconds per mile (or km).
    public static func band(
        fastest: TimeInterval,
        slowest: TimeInterval,
        per unit: DistanceUnit
    ) -> ClosedRange<Double> {
        let fast = fastest / unit.metersPerUnit
        let slow = slowest / unit.metersPerUnit
        return min(fast, slow)...max(fast, slow)
    }
}

/// Periodic distance chimes — every half mile, every mile, and so on.
public struct DistanceSplits: Codable, Hashable, Sendable {
    public enum Scope: String, Codable, Sendable {
        /// Count against total workout distance.
        case total
        /// Restart the count at each new segment, for "every half mile of running".
        case perSegment
    }

    public var everyMeters: Double
    public var scope: Scope

    public init(everyMeters: Double, scope: Scope = .total) {
        self.everyMeters = everyMeters
        self.scope = scope
    }

    public static func every(_ value: Double, _ unit: DistanceUnit, scope: Scope = .total) -> DistanceSplits {
        DistanceSplits(everyMeters: unit.meters(fromUnits: value), scope: scope)
    }
}
