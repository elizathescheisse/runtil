import Foundation

/// A snapshot of a run in progress, sent from the watch to the phone.
///
/// Kept small on purpose. `sendToRemoteWorkoutSession` allows 100 KB per 10 seconds, and
/// this goes once a second, so there's plenty of headroom — but the payload is also the
/// thing that must never delay a cue, so it stays a flat struct with no history in it.
///
/// The watch remains the source of truth throughout: it holds the session, reads the
/// sensors, decides the cues and buzzes. The phone is a display.
public struct MirroredState: Codable, Hashable, Sendable {
    public var planName: String
    public var elapsed: TimeInterval
    public var segmentKind: SegmentKind?
    public var cycle: Int
    public var timeInSegment: TimeInterval
    public var timeRemainingInSegment: TimeInterval?
    public var heartRate: Int?
    public var projectedHeartRate: Int?
    public var distanceMeters: Double
    public var paceSecondsPerMeter: Double?
    public var units: DistanceUnit
    /// The most recent cue, so the phone can show — and speak — what your wrist was
    /// just told.
    public var lastCueSummary: String?
    public var lastCue: Cue?
    /// Increments once per cue. Snapshots arrive every second carrying the same last cue,
    /// so without this the phone would repeat "Run" until the next segment.
    public var cueSequence: Int
    public var isFinished: Bool

    public init(
        planName: String,
        elapsed: TimeInterval,
        segmentKind: SegmentKind?,
        cycle: Int,
        timeInSegment: TimeInterval,
        timeRemainingInSegment: TimeInterval?,
        heartRate: Int?,
        projectedHeartRate: Int?,
        distanceMeters: Double,
        paceSecondsPerMeter: Double?,
        units: DistanceUnit,
        lastCueSummary: String?,
        lastCue: Cue? = nil,
        cueSequence: Int = 0,
        isFinished: Bool
    ) {
        self.planName = planName
        self.elapsed = elapsed
        self.segmentKind = segmentKind
        self.cycle = cycle
        self.timeInSegment = timeInSegment
        self.timeRemainingInSegment = timeRemainingInSegment
        self.heartRate = heartRate
        self.projectedHeartRate = projectedHeartRate
        self.distanceMeters = distanceMeters
        self.paceSecondsPerMeter = paceSecondsPerMeter
        self.units = units
        self.lastCueSummary = lastCueSummary
        self.lastCue = lastCue
        self.cueSequence = cueSequence
        self.isFinished = isFinished
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    /// Returns nil rather than throwing: a payload from a newer build shouldn't take the
    /// receiving app down, it should just be ignored until the next one arrives a second
    /// later.
    public static func decoded(from data: Data) -> MirroredState? {
        try? JSONDecoder().decode(MirroredState.self, from: data)
    }
}
