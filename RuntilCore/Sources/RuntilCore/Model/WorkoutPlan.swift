import Foundation

/// What moves you from one segment to the next.
///
/// Exactly one drive mode per plan, so a buzz is never ambiguous — you always know whether
/// the watch switched you because of the clock, your heart rate, or the distance covered.
public enum DriveMode: String, Codable, CaseIterable, Hashable, Sendable {
    case time
    case heartRate
    case distance
    case manual

    public var displayName: String {
        switch self {
        case .time: return "Time"
        case .heartRate: return "Heart rate"
        case .distance: return "Distance"
        case .manual: return "Manual"
        }
    }

    public var explanation: String {
        switch self {
        case .time: return "Segments switch on the clock."
        case .heartRate: return "Segments switch when your heart rate reaches the edges of your zone."
        case .distance: return "Segments switch after a set distance."
        case .manual: return "Segments switch when you tap."
        }
    }

    /// Segment triggers that make sense for this mode. The editor uses this so you can't
    /// build a plan whose segments contradict its drive mode.
    public var validEnds: [String] {
        switch self {
        case .time: return ["duration"]
        case .heartRate: return ["heartRateAtOrAbove", "heartRateAtOrBelow"]
        case .distance: return ["distance"]
        case .manual: return ["manual"]
        }
    }
}

public struct WorkoutPlan: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var driveMode: DriveMode
    public var segments: [Segment]
    /// How many times to cycle the segment list. nil repeats until you stop.
    public var repeatCount: Int?
    public var zones: HeartRateZones
    public var hrResponse: HRResponseProfile
    public var advisories: Advisories
    public var units: DistanceUnit

    /// Whether to save this run to Health as a workout.
    ///
    /// Turn it off when something else is recording the run — a phone-based tracker, say.
    /// runtil still needs its workout session for background haptics, but discards the
    /// result instead of saving, so Health doesn't end up with two overlapping workouts
    /// double-counting the same miles and calories.
    public var savesToHealth: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        driveMode: DriveMode,
        segments: [Segment],
        repeatCount: Int? = nil,
        zones: HeartRateZones,
        hrResponse: HRResponseProfile = .default,
        advisories: Advisories = .none,
        units: DistanceUnit = .miles,
        savesToHealth: Bool = true
    ) {
        self.savesToHealth = savesToHealth
        self.id = id
        self.name = name
        self.driveMode = driveMode
        self.segments = segments
        self.repeatCount = repeatCount
        self.zones = zones
        self.hrResponse = hrResponse
        self.advisories = advisories
        self.units = units
    }

    /// Decoded by hand so a plan saved before a field existed still loads, defaulting the
    /// missing value instead of throwing and wiping the library.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        driveMode = try container.decode(DriveMode.self, forKey: .driveMode)
        segments = try container.decode([Segment].self, forKey: .segments)
        repeatCount = try container.decodeIfPresent(Int.self, forKey: .repeatCount)
        zones = try container.decode(HeartRateZones.self, forKey: .zones)
        hrResponse = try container.decodeIfPresent(HRResponseProfile.self, forKey: .hrResponse) ?? .default
        advisories = try container.decodeIfPresent(Advisories.self, forKey: .advisories) ?? .none
        units = try container.decodeIfPresent(DistanceUnit.self, forKey: .units) ?? .miles
        savesToHealth = try container.decodeIfPresent(Bool.self, forKey: .savesToHealth) ?? true
    }

    /// Total planned duration when that's knowable — nil for HR- or distance-driven plans,
    /// and for plans that repeat forever.
    public var plannedDuration: TimeInterval? {
        guard let repeatCount else { return nil }
        var total: TimeInterval = 0
        for segment in segments {
            guard case .duration(let d) = segment.end else { return nil }
            total += d
        }
        return total * Double(repeatCount)
    }
}

// MARK: - Starter plans

extension WorkoutPlan {

    /// The plan from the original ask: run until you near the top of Zone 2, walk until you
    /// come back down to near the bottom, repeat. Guardrails come from the HR profile, so
    /// tuning your lag tunes this plan.
    public static func zoneTwoRunWalk(
        zones: HeartRateZones,
        response: HRResponseProfile = .default,
        units: DistanceUnit = .miles
    ) -> WorkoutPlan {
        let z2 = zones.range(forZone: 2)
        let floor = response.effectiveMinSegmentDuration
        let ceiling = response.maxSegmentDuration

        return WorkoutPlan(
            name: "Zone 2 run/walk",
            driveMode: .heartRate,
            segments: [
                Segment(
                    kind: .run,
                    end: .heartRateAtOrAbove(bpm: z2.upperBound),
                    minDuration: floor,
                    maxDuration: ceiling
                ),
                Segment(
                    kind: .walk,
                    end: .heartRateAtOrBelow(bpm: z2.lowerBound),
                    minDuration: floor,
                    maxDuration: ceiling
                )
            ],
            repeatCount: nil,
            zones: zones,
            hrResponse: response,
            advisories: Advisories(
                heartRateGuard: HeartRateGuard(zone: 2),
                distanceSplits: .every(0.5, units)
            ),
            units: units
        )
    }

    /// Fixed run/walk intervals — the "90 seconds running, 60 seconds walking, repeat"
    /// pattern. Predictable enough to be the sensible first outdoor test.
    public static func timedIntervals(
        run: TimeInterval,
        walk: TimeInterval,
        repeatCount: Int? = nil,
        zones: HeartRateZones,
        response: HRResponseProfile = .default,
        units: DistanceUnit = .miles
    ) -> WorkoutPlan {
        WorkoutPlan(
            name: "\(Format.compactDuration(run))/\(Format.compactDuration(walk)) intervals",
            driveMode: .time,
            segments: [
                Segment(kind: .run, end: .duration(run)),
                Segment(kind: .walk, end: .duration(walk))
            ],
            repeatCount: repeatCount,
            zones: zones,
            hrResponse: response,
            advisories: Advisories(
                heartRateGuard: HeartRateGuard(zone: 2),
                distanceSplits: .every(1, units)
            ),
            units: units
        )
    }

    /// Distance-driven alternation, e.g. run half a mile, walk a quarter.
    public static func distanceIntervals(
        run: Double,
        walk: Double,
        unit: DistanceUnit,
        repeatCount: Int? = nil,
        zones: HeartRateZones,
        response: HRResponseProfile = .default
    ) -> WorkoutPlan {
        WorkoutPlan(
            name: "\(Format.trimmed(run))/\(Format.trimmed(walk)) \(unit.abbreviation) intervals",
            driveMode: .distance,
            segments: [
                Segment(kind: .run, end: .distance(meters: unit.meters(fromUnits: run))),
                Segment(kind: .walk, end: .distance(meters: unit.meters(fromUnits: walk)))
            ],
            repeatCount: repeatCount,
            zones: zones,
            hrResponse: response,
            advisories: Advisories(heartRateGuard: HeartRateGuard(zone: 2)),
            units: unit
        )
    }
}
