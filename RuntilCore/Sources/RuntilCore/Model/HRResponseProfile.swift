import Foundation

/// How *your* heart rate responds to a change in effort.
///
/// There is no correct one-size-fits-all value here. Response lag varies with fitness,
/// age, heat, hydration, caffeine, sleep, and medication — beta blockers in particular
/// blunt the response dramatically. So every number below is a user-editable setting with
/// a defensible default, not a hardcoded constant.
///
/// `lagSeconds` is not a fudge factor. The engine measures your heart rate *slope* and
/// projects it forward by this much to decide when to cue:
///
///     projectedHR = currentHR + slope × lagSeconds
///
/// So climbing hard toward your ceiling buzzes earlier than drifting up gently, which is
/// what you actually want out on the road.
public struct HRResponseProfile: Codable, Hashable, Sendable {

    /// How long your heart rate trails a change in effort. Default 25s is mid-range for a
    /// recreational runner; trained athletes respond faster, beta blockers much slower.
    /// The post-run summary measures this from your own data and offers to update it.
    public var lagSeconds: TimeInterval

    /// Static safety buffer in BPM. Cue this far before the actual zone edge, on top of
    /// whatever the slope projection contributes.
    public var approachMargin: Int

    /// Consecutive qualifying samples required before a cue fires. Heart rate readings are
    /// noisy — a single spike shouldn't send you walking.
    public var confirmSamples: Int

    /// Minimum time between repeats of the same advisory, so the watch nudges you rather
    /// than nagging continuously for a mile.
    public var cooldown: TimeInterval

    /// Explicit anti-thrash floor for HR-driven segments. When nil, derived from
    /// `lagSeconds` via `effectiveMinSegmentDuration` — raising your lag automatically
    /// widens the floor unless you override it.
    public var minSegmentDuration: TimeInterval?

    /// Hard ceiling on an HR-driven segment, so a trigger that never fires can't strand you.
    public var maxSegmentDuration: TimeInterval

    public init(
        lagSeconds: TimeInterval = 25,
        approachMargin: Int = 5,
        confirmSamples: Int = 3,
        cooldown: TimeInterval = 45,
        minSegmentDuration: TimeInterval? = nil,
        maxSegmentDuration: TimeInterval = 300
    ) {
        self.lagSeconds = lagSeconds
        self.approachMargin = approachMargin
        self.confirmSamples = confirmSamples
        self.cooldown = cooldown
        self.minSegmentDuration = minSegmentDuration
        self.maxSegmentDuration = maxSegmentDuration
    }

    public static let `default` = HRResponseProfile()

    /// The floor actually applied. An explicit override wins; otherwise it tracks your lag,
    /// because a segment shorter than your response time can't produce a meaningful reading.
    public var effectiveMinSegmentDuration: TimeInterval {
        if let explicit = minSegmentDuration { return explicit }
        return max(30, lagSeconds + 5)
    }

    /// Window over which HR slope is measured. Long enough to reject sensor noise, short
    /// enough to still be responsive — one lag period, bounded to a sane range.
    public var slopeWindow: TimeInterval {
        min(max(lagSeconds, 15), 45)
    }
}

/// A single observed transition, used to calibrate `lagSeconds` from real runs.
public struct LagObservation: Codable, Hashable, Sendable {
    /// Elapsed time in the workout when effort changed (a run/walk boundary).
    public var effortChangedAt: TimeInterval
    /// When heart rate visibly turned in response — the inflection point.
    public var heartRateRespondedAt: TimeInterval
    public var fromKind: SegmentKind
    public var toKind: SegmentKind

    public var measuredLag: TimeInterval { heartRateRespondedAt - effortChangedAt }

    public init(
        effortChangedAt: TimeInterval,
        heartRateRespondedAt: TimeInterval,
        fromKind: SegmentKind,
        toKind: SegmentKind
    ) {
        self.effortChangedAt = effortChangedAt
        self.heartRateRespondedAt = heartRateRespondedAt
        self.fromKind = fromKind
        self.toKind = toKind
    }
}

extension Array where Element == LagObservation {
    /// Median measured lag — median rather than mean because a single missed inflection
    /// produces a wild outlier that would drag an average badly.
    public var suggestedLagSeconds: TimeInterval? {
        let lags = map(\.measuredLag).filter { $0 > 0 && $0 < 180 }.sorted()
        guard !lags.isEmpty else { return nil }
        let mid = lags.count / 2
        return lags.count.isMultiple(of: 2) ? (lags[mid - 1] + lags[mid]) / 2 : lags[mid]
    }
}
