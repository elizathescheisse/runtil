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

/// One kind of segment's pace goal: a number to aim at, and how much drift is fine.
///
/// A target plus a tolerance rather than two endpoints, because that's how running
/// actually feels — you want "around 9:30", not "between 9:15 and 9:45". It also makes the
/// default meaningful: pick your pace and the app supplies a sane window.
public struct PaceBand: Codable, Hashable, Sendable {
    /// Seconds per metre. The engine is metric throughout; the UI converts.
    public var targetSecondsPerMeter: Double
    /// Half-width of the acceptable window, seconds per metre.
    public var toleranceSecondsPerMeter: Double

    public init(targetSecondsPerMeter: Double, toleranceSecondsPerMeter: Double) {
        self.targetSecondsPerMeter = targetSecondsPerMeter
        self.toleranceSecondsPerMeter = toleranceSecondsPerMeter
    }

    /// ±20 s per mile.
    ///
    /// Not arbitrary: even after the engine's rolling average, GPS pace still wanders by
    /// roughly 10–20 s/mile at genuinely constant effort. A tighter window than this
    /// measures satellite geometry rather than running, and buzzes accordingly.
    public static let defaultToleranceSecondsPerMile: TimeInterval = 20

    public var range: ClosedRange<Double> {
        let low = max(0, targetSecondsPerMeter - toleranceSecondsPerMeter)
        return low...(targetSecondsPerMeter + toleranceSecondsPerMeter)
    }

    /// Build from the units a runner thinks in: "9:30 per mile, give or take 20 seconds".
    public static func perUnit(
        target: TimeInterval,
        tolerance: TimeInterval? = nil,
        unit: DistanceUnit
    ) -> PaceBand {
        let toleranceSeconds = tolerance ?? defaultToleranceSecondsPerMile
        return PaceBand(
            targetSecondsPerMeter: target / unit.metersPerUnit,
            toleranceSecondsPerMeter: toleranceSeconds / unit.metersPerUnit
        )
    }

    public func target(in unit: DistanceUnit) -> TimeInterval {
        targetSecondsPerMeter * unit.metersPerUnit
    }

    public func tolerance(in unit: DistanceUnit) -> TimeInterval {
        toleranceSecondsPerMeter * unit.metersPerUnit
    }
}

/// Target pace band, stored as seconds per meter so the engine stays metric.
public struct PaceTarget: Codable, Hashable, Sendable {
    /// Per segment kind, so running and walking can have different targets.
    public var bandsByKind: [SegmentKind: PaceBand]
    /// Rolling average window. Instantaneous GPS pace is far too jittery to cue on.
    public var window: TimeInterval
    public var cooldown: TimeInterval
    /// Ignore pace entirely for this long after a segment starts, so you aren't scolded
    /// for being "too slow" during the seconds it takes to actually get moving.
    public var graceAfterSegmentStart: TimeInterval

    public init(
        bandsByKind: [SegmentKind: PaceBand] = [:],
        window: TimeInterval = 25,
        cooldown: TimeInterval = 30,
        graceAfterSegmentStart: TimeInterval = 20
    ) {
        self.bandsByKind = bandsByKind
        self.window = window
        self.cooldown = cooldown
        self.graceAfterSegmentStart = graceAfterSegmentStart
    }

    /// Tolerant of libraries written before pace bands changed shape, so an old plan
    /// loses its pace target rather than failing to decode and taking the plan with it.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bandsByKind = (try? container.decode([SegmentKind: PaceBand].self, forKey: .bandsByKind)) ?? [:]
        window = try container.decodeIfPresent(TimeInterval.self, forKey: .window) ?? 25
        cooldown = try container.decodeIfPresent(TimeInterval.self, forKey: .cooldown) ?? 30
        graceAfterSegmentStart = try container.decodeIfPresent(
            TimeInterval.self, forKey: .graceAfterSegmentStart
        ) ?? 20
    }

    /// Sensible opening values for a plan: an easy running pace and a brisk walk, set only
    /// for the segment kinds the plan actually uses.
    public static func defaultTarget(for plan: WorkoutPlan) -> PaceTarget {
        var target = PaceTarget()
        for segment in plan.segments where target.bandsByKind[segment.kind] == nil {
            target.bandsByKind[segment.kind] = .perUnit(
                target: segment.kind.isEffort ? 9 * 60 : 17 * 60,
                unit: plan.units
            )
        }
        return target
    }
}

extension WorkoutPlan {
    /// One-line description of the pace target, for a settings row.
    public var paceTargetSummary: String {
        guard let target = advisories.paceTarget, !target.bandsByKind.isEmpty else { return "Off" }
        // Lead with the effort segment, which is the one you're actually pacing.
        let kind = segments.first(where: { $0.kind.isEffort })?.kind
            ?? segments.first?.kind
            ?? .run
        guard let band = target.bandsByKind[kind] else { return "Set" }
        return "\(Format.duration(band.target(in: units))) ±\(Int(band.tolerance(in: units)))s"
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
