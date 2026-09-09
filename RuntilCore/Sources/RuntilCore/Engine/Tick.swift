import Foundation

/// One sample of the world, delivered to the engine roughly once a second.
///
/// Deliberately dumb: no dates, no device types, nothing to mock. This is what makes the
/// engine testable — a run is just an array of these.
public struct Tick: Hashable, Sendable {
    /// Seconds since the workout started.
    public var elapsed: TimeInterval
    /// Total distance so far, meters.
    public var totalDistance: Double
    /// Latest heart rate, or nil before the first reading arrives.
    public var heartRate: Int?
    /// Instantaneous pace in seconds per meter, or nil without a usable GPS fix.
    public var instantPace: Double?

    public init(
        elapsed: TimeInterval,
        totalDistance: Double = 0,
        heartRate: Int? = nil,
        instantPace: Double? = nil
    ) {
        self.elapsed = elapsed
        self.totalDistance = totalDistance
        self.heartRate = heartRate
        self.instantPace = instantPace
    }
}

/// Something the runner should be told about.
public enum Cue: Hashable, Sendable {
    /// A new segment just started — the main event.
    case beginSegment(kind: SegmentKind, index: Int, cycle: Int)
    /// Countdown before a timed segment ends.
    case segmentEndingSoon(seconds: Int)
    /// Heart rate is projected to reach the top of the target zone.
    case approachingZoneCeiling(bpm: Int, ceiling: Int)
    /// Heart rate is projected to fall below the bottom of the target zone.
    case approachingZoneFloor(bpm: Int, floor: Int)
    case thresholdCrossed(bpm: Int, rising: Bool)
    case paceTooFast(secondsPerMeter: Double)
    case paceTooSlow(secondsPerMeter: Double)
    case distanceSplit(index: Int, meters: Double)
    case workoutComplete

    /// Higher wins when several cues land on the same tick.
    ///
    /// Two haptic patterns played back to back are indistinguishable on the wrist, and
    /// watchOS coalesces rapid calls anyway — so colliding cues are resolved by dropping
    /// the lower-priority one rather than queueing it.
    public var priority: Int {
        switch self {
        case .workoutComplete: return 100
        case .beginSegment: return 90
        case .approachingZoneCeiling: return 80
        case .approachingZoneFloor: return 75
        case .segmentEndingSoon: return 70
        case .thresholdCrossed: return 60
        case .distanceSplit: return 50
        case .paceTooFast, .paceTooSlow: return 40
        }
    }

    /// Pace nudges can be silenced mid-run independently of everything else, since a band
    /// set too tight is the cue most likely to turn into noise.
    public var isPaceCue: Bool {
        switch self {
        case .paceTooFast, .paceTooSlow: return true
        default: return false
        }
    }

    /// Short line for the on-screen cue log.
    public var summary: String {
        switch self {
        case .beginSegment(let kind, _, let cycle):
            return "\(kind.displayName) (lap \(cycle + 1))"
        case .segmentEndingSoon(let seconds):
            return "\(seconds)…"
        case .approachingZoneCeiling(let bpm, let ceiling):
            return "Ease up — \(bpm) approaching \(ceiling)"
        case .approachingZoneFloor(let bpm, let floor):
            return "Pick it up — \(bpm) nearing \(floor)"
        case .thresholdCrossed(let bpm, let rising):
            return "Crossed \(bpm) \(rising ? "↑" : "↓")"
        case .paceTooFast:
            return "Too fast"
        case .paceTooSlow:
            return "Too slow"
        case .distanceSplit(let index, _):
            return "Split \(index)"
        case .workoutComplete:
            return "Done"
        }
    }
}
