import Foundation

/// What you're meant to be doing during a segment.
public enum SegmentKind: String, Codable, CaseIterable, Hashable, Sendable {
    case warmup
    case run
    case walk
    case recover
    case cooldown

    public var displayName: String {
        switch self {
        case .warmup: return "Warm up"
        case .run: return "Run"
        case .walk: return "Walk"
        case .recover: return "Recover"
        case .cooldown: return "Cool down"
        }
    }

    /// Whether this is an effort segment. Used to pick the right pace target and to
    /// decide which direction an HR advisory should nudge you.
    public var isEffort: Bool {
        switch self {
        case .run, .warmup: return true
        case .walk, .recover, .cooldown: return false
        }
    }
}

/// The trigger that ends a segment.
///
/// This is the pivot the whole app turns on. "Run 90 seconds", "run half a mile", and
/// "run until you near the top of Zone 2" are the same state machine with a different
/// case here — which is why timed intervals, distance splits, and HR-driven run/walk
/// don't need three separate implementations.
public enum SegmentEnd: Codable, Hashable, Sendable {
    case duration(TimeInterval)
    case distance(meters: Double)
    case heartRateAtOrAbove(bpm: Int)
    case heartRateAtOrBelow(bpm: Int)
    case manual

    /// The drive mode a segment ending this way belongs to.
    public var driveMode: DriveMode {
        switch self {
        case .duration: return .time
        case .distance: return .distance
        case .heartRateAtOrAbove, .heartRateAtOrBelow: return .heartRate
        case .manual: return .manual
        }
    }
}

public struct Segment: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var kind: SegmentKind
    public var end: SegmentEnd

    /// Anti-thrash floor. A segment will not end before this much time has passed, even
    /// if its trigger is already satisfied. Matters most for heart-rate triggers: HR lags
    /// effort, so without a floor you flip run/walk/run every few seconds at the boundary.
    public var minDuration: TimeInterval?

    /// Safety ceiling. Forces the segment to end even if the trigger never fires — so a
    /// heart rate that never climbs into range doesn't strand you running forever.
    public var maxDuration: TimeInterval?

    public init(
        id: UUID = UUID(),
        kind: SegmentKind,
        end: SegmentEnd,
        minDuration: TimeInterval? = nil,
        maxDuration: TimeInterval? = nil
    ) {
        self.id = id
        self.kind = kind
        self.end = end
        self.minDuration = minDuration
        self.maxDuration = maxDuration
    }
}
