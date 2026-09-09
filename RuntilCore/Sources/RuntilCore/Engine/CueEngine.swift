import Foundation

/// Turns a stream of `Tick`s into a stream of `Cue`s.
///
/// Deterministic and self-contained: no clocks, no I/O, no framework imports. The same tick
/// sequence always produces the same cue sequence, which is what lets a whole run be tested
/// in milliseconds on a Mac instead of only verified out on the road.
public final class CueEngine {

    // MARK: Observable state (for the live UI)

    public private(set) var segmentIndex: Int = 0
    public private(set) var cycle: Int = 0
    public private(set) var isFinished = false
    public private(set) var segmentStartElapsed: TimeInterval = 0
    public private(set) var segmentStartDistance: Double = 0
    public private(set) var lagObservations: [LagObservation] = []

    /// Rolling pace recorded during segments a pace band applied to, so the summary can
    /// tell you what you actually ran rather than asking you to remember.
    public private(set) var paceObservations: [SegmentKind: [Double]] = [:]
    /// How often each kind's band was breached, muted or not.
    public private(set) var paceCueCounts: [SegmentKind: Int] = [:]

    /// Altitudes, for elevation gain. Fed in by the caller since GPS lives outside here.
    public private(set) var altitudes: [Double] = []

    public func recordAltitude(_ metres: Double) {
        altitudes.append(metres)
    }

    /// Heart rate projected forward by your response lag. This is the number the engine
    /// actually makes decisions on — surfaced so the UI can show it alongside the raw BPM.
    public private(set) var projectedHeartRate: Int?
    public private(set) var heartRateSlope: Double = 0   // bpm per second
    public private(set) var rollingPace: Double?         // seconds per meter
    private var lastElapsed: TimeInterval = 0

    /// Whether the runner is still being asked to change effort and hasn't yet.
    ///
    /// Drives a large RUN / WALK prompt on the watch. Haptic rhythm has to be learned, and
    /// until it is, a glance should answer "what am I meant to be doing" without decoding
    /// anything — so the screen says it in a word for as long as the question is live.
    ///
    /// Bounded, so a run with no pace data doesn't sit under a permanent instruction: it
    /// clears the moment your pace confirms the change, or when the nagging would have
    /// given up anyway.
    public var isPromptingEffortChange: Bool {
        guard !effortConfirmed, currentSegment != nil else { return false }
        let window: TimeInterval
        if let confirmation = plan.advisories.effortConfirmation {
            window = confirmation.repeatAfter * Double(confirmation.maxRepeats + 1)
        } else {
            window = 12
        }
        return (lastElapsed - segmentStartElapsed) < window
    }

    public let plan: WorkoutPlan

    // MARK: Private state

    private var heartRateHistory: [(elapsed: TimeInterval, bpm: Int)] = []
    private var paceHistory: [(elapsed: TimeInterval, pace: Double)] = []
    private var lastCueElapsed: [CueChannel: TimeInterval] = [:]
    private var ceilingStreak = 0
    private var floorStreak = 0
    private var lastSplitIndex = 0
    private var previousHeartRate: Int?
    private var emittedCountdowns: Set<Int> = []
    private var started = false
    private var effortRepeats = 0
    private var lastEffortRepeatAt: TimeInterval = 0
    private var effortConfirmed = false

    /// A transition we're still waiting on a heart-rate response for, used to calibrate lag.
    private var pendingLagProbe: (at: TimeInterval, from: SegmentKind, to: SegmentKind)?

    /// Cue families that share a cooldown budget.
    private enum CueChannel: Hashable {
        case zoneCeiling, zoneFloor, pace, threshold(Int)
    }

    public init(plan: WorkoutPlan) {
        self.plan = plan
    }

    // MARK: - Derived

    public var currentSegment: Segment? {
        plan.segments.indices.contains(segmentIndex) ? plan.segments[segmentIndex] : nil
    }

    private var response: HRResponseProfile { plan.hrResponse }

    /// Average pace since the current segment began.
    ///
    /// The ordinary rolling pace spans a fixed window that straddles the transition, so ten
    /// seconds into a walk it is still mostly made of running — judging compliance on that
    /// would nag you for not walking while you are, in fact, walking.
    ///
    /// Returns nil until there are enough samples to mean anything.
    private var paceSinceSegmentStart: Double? {
        let samples = paceHistory.filter { $0.elapsed >= segmentStartElapsed }
        guard samples.count >= 5 else { return nil }
        return samples.map(\.pace).reduce(0, +) / Double(samples.count)
    }

    /// Physiologically plausible ceiling on HR slope. Guards against a sensor glitch
    /// projecting an absurd heart rate and triggering a spurious transition.
    private static let maxPlausibleSlope: Double = 0.5   // bpm/sec == 30 bpm/min

    // MARK: - Main entry point

    /// Advance the state machine by one sample. Returns any cues to play, highest priority
    /// first; callers may take just the first if they can only render one.
    public func advance(_ tick: Tick) -> [Cue] {
        guard !isFinished else { return [] }

        var cues: [Cue] = []

        // The very first tick opens the first segment.
        if !started {
            started = true
            segmentStartElapsed = tick.elapsed
            segmentStartDistance = tick.totalDistance
            if let segment = currentSegment {
                cues.append(.beginSegment(kind: segment.kind, index: segmentIndex, cycle: cycle))
            }
        }

        ingest(tick)

        guard let segment = currentSegment else {
            isFinished = true
            return cues + [.workoutComplete]
        }

        // A transition supersedes the advisories that describe how you're doing *within*
        // a segment — pace, HR guard, countdown — so those are skipped entirely.
        //
        // Splits are the exception: they still have to be accounted for on this tick, or a
        // split landing on a boundary would be deferred to the next second and buzz you
        // twice a second apart. Reported here and dropped by priority downstream instead.
        if shouldEndSegment(segment, tick: tick) {
            cues.append(contentsOf: splitCues(tick))
            cues.append(contentsOf: endSegment(from: segment, tick: tick))
            previousHeartRate = tick.heartRate
            return cues.sorted { $0.priority > $1.priority }
        }

        cues.append(contentsOf: advisories(for: segment, tick: tick))
        previousHeartRate = tick.heartRate
        return cues.sorted { $0.priority > $1.priority }
    }

    // MARK: - Sampling

    private func ingest(_ tick: Tick) {
        if let bpm = tick.heartRate {
            heartRateHistory.append((tick.elapsed, bpm))
            let cutoff = tick.elapsed - response.slopeWindow
            heartRateHistory.removeAll { $0.elapsed < cutoff }
            heartRateSlope = Self.slope(of: heartRateHistory)
            let clamped = min(max(heartRateSlope, -Self.maxPlausibleSlope), Self.maxPlausibleSlope)
            projectedHeartRate = Int((Double(bpm) + clamped * response.lagSeconds).rounded())
        }

        if let pace = tick.instantPace, pace.isFinite, pace > 0 {
            paceHistory.append((tick.elapsed, pace))
        }
        // Kept long enough to serve both consumers: the pace-target window, and
        // compliance measured from the start of the current segment.
        let paceWindow = plan.advisories.paceTarget?.window ?? 25
        let cutoff = min(tick.elapsed - paceWindow, segmentStartElapsed)
        paceHistory.removeAll { $0.elapsed < cutoff }
        rollingPace = paceHistory.isEmpty
            ? nil
            : paceHistory.map(\.pace).reduce(0, +) / Double(paceHistory.count)

        lastElapsed = tick.elapsed
        observeLagResponse(at: tick.elapsed)
    }

    /// Least-squares slope in bpm/sec. Regression rather than first-to-last difference
    /// because two endpoint samples are exactly the ones a sensor glitch corrupts.
    private static func slope(of samples: [(elapsed: TimeInterval, bpm: Int)]) -> Double {
        guard samples.count >= 3 else { return 0 }
        let n = Double(samples.count)
        let meanX = samples.map(\.elapsed).reduce(0, +) / n
        let meanY = samples.map { Double($0.bpm) }.reduce(0, +) / n
        var num = 0.0, den = 0.0
        for s in samples {
            let dx = s.elapsed - meanX
            num += dx * (Double(s.bpm) - meanY)
            den += dx * dx
        }
        guard den > 0 else { return 0 }
        return num / den
    }

    // MARK: - Segment transitions

    private func shouldEndSegment(_ segment: Segment, tick: Tick) -> Bool {
        let inSegment = tick.elapsed - segmentStartElapsed
        let covered = tick.totalDistance - segmentStartDistance
        let isHeartRateDriven = segment.end.driveMode == .heartRate

        // Hard ceiling first: a trigger that never fires must not strand the runner.
        let maxDuration = segment.maxDuration ?? (isHeartRateDriven ? response.maxSegmentDuration : nil)
        if let maxDuration, inSegment >= maxDuration { return true }

        // Anti-thrash floor. HR-driven segments default to the profile's floor, which
        // tracks your lag; other modes have no implicit floor.
        let minDuration = segment.minDuration ?? (isHeartRateDriven ? response.effectiveMinSegmentDuration : 0)
        guard inSegment >= minDuration else { return false }

        switch segment.end {
        case .duration(let target):
            return inSegment >= target

        case .distance(let target):
            return covered >= target

        // "Run until you get *close* to the top of Zone 2" — hence the margin, and hence
        // projecting the heart rate forward rather than waiting for it to actually arrive.
        case .heartRateAtOrAbove(let target):
            guard let projected = projectedHeartRate else { return false }
            return projected >= target - response.approachMargin

        case .heartRateAtOrBelow(let target):
            guard let projected = projectedHeartRate else { return false }
            return projected <= target + response.approachMargin

        case .manual:
            return false
        }
    }

    /// End the current segment and open the next, wrapping and counting cycles.
    private func endSegment(from segment: Segment, tick: Tick) -> [Cue] {
        startLagProbe(leaving: segment, at: tick.elapsed)

        segmentIndex += 1
        if segmentIndex >= plan.segments.count {
            segmentIndex = 0
            cycle += 1
            if let limit = plan.repeatCount, cycle >= limit {
                isFinished = true
                return [.workoutComplete]
            }
        }

        segmentStartElapsed = tick.elapsed
        segmentStartDistance = tick.totalDistance
        ceilingStreak = 0
        floorStreak = 0
        effortRepeats = 0
        lastEffortRepeatAt = tick.elapsed
        effortConfirmed = false
        emittedCountdowns.removeAll()
        if plan.advisories.distanceSplits?.scope == .perSegment { lastSplitIndex = 0 }

        guard let next = currentSegment else {
            isFinished = true
            return [.workoutComplete]
        }
        return [.beginSegment(kind: next.kind, index: segmentIndex, cycle: cycle)]
    }

    /// Ends the current segment early on a user tap. Drives `.manual` plans, and lets you
    /// override any other mode mid-run.
    public func skipSegment(at elapsed: TimeInterval, totalDistance: Double) -> [Cue] {
        guard !isFinished, let segment = currentSegment else { return [] }
        return endSegment(from: segment, tick: Tick(elapsed: elapsed, totalDistance: totalDistance))
    }

    // MARK: - Advisories

    private func advisories(for segment: Segment, tick: Tick) -> [Cue] {
        var cues: [Cue] = []
        let inSegment = tick.elapsed - segmentStartElapsed

        updateEffortConfirmation(segment)
        cues.append(contentsOf: effortConfirmationCues(segment, tick: tick, inSegment: inSegment))
        cues.append(contentsOf: countdownCues(segment, inSegment: inSegment))
        cues.append(contentsOf: heartRateCues(segment, tick: tick))
        cues.append(contentsOf: thresholdCues(tick))
        cues.append(contentsOf: paceCues(segment, tick: tick, inSegment: inSegment))
        cues.append(contentsOf: splitCues(tick))
        return cues
    }

    /// Notices compliance as soon as the pace agrees.
    ///
    /// Checked every tick rather than only when a repeat falls due, so the on-screen
    /// prompt clears the moment you start running instead of lingering until the next
    /// scheduled nag.
    private func updateEffortConfirmation(_ segment: Segment) {
        guard !effortConfirmed, let confirmation = plan.advisories.effortConfirmation else { return }
        if confirmation.matchesEffort(segment.kind, pace: paceSinceSegmentStart) == true {
            effortConfirmed = true
        }
    }

    /// Repeats "start running" or "start walking" until your pace shows you did.
    ///
    /// One buzz is indistinguishable from a text message arriving, so a missed cue means a
    /// missed interval. Repeating removes the ambiguity: if it's still going, it meant you.
    ///
    /// Stops the moment the pace matches — and stops after a bounded number of repeats
    /// regardless, because a treadmill, a lost fix, or a badly set threshold must not turn
    /// into buzzing for the whole segment.
    private func effortConfirmationCues(
        _ segment: Segment,
        tick: Tick,
        inSegment: TimeInterval
    ) -> [Cue] {
        guard let confirmation = plan.advisories.effortConfirmation,
              !effortConfirmed,
              effortRepeats < confirmation.maxRepeats,
              inSegment >= confirmation.repeatAfter,
              tick.elapsed - lastEffortRepeatAt >= confirmation.repeatAfter
        else { return [] }

        // Unknown means indoors or a GPS fix that hasn't settled. Repeating a cue nobody
        // can satisfy is worse than missing one, so silence is the right answer.
        guard let matches = confirmation.matchesEffort(segment.kind, pace: paceSinceSegmentStart) else {
            return []
        }
        if matches {
            effortConfirmed = true
            return []
        }

        effortRepeats += 1
        lastEffortRepeatAt = tick.elapsed
        return [.beginSegment(kind: segment.kind, index: segmentIndex, cycle: cycle)]
    }

    private func countdownCues(_ segment: Segment, inSegment: TimeInterval) -> [Cue] {
        guard case .duration(let target) = segment.end else { return [] }
        let remaining = Int((target - inSegment).rounded())
        guard (1...3).contains(remaining), !emittedCountdowns.contains(remaining) else { return [] }
        emittedCountdowns.insert(remaining)
        return [.segmentEndingSoon(seconds: remaining)]
    }

    private func heartRateCues(_ segment: Segment, tick: Tick) -> [Cue] {
        guard let guardConfig = plan.advisories.heartRateGuard,
              let bpm = tick.heartRate,
              let projected = projectedHeartRate
        else { return [] }

        // In an HR-driven plan the transition itself already tells you to change effort;
        // a second buzz saying the same thing would just be noise.
        guard plan.driveMode != .heartRate else { return [] }

        let zone = plan.zones.range(forZone: guardConfig.zone)
        var cues: [Cue] = []

        if guardConfig.watchCeiling, segment.kind.isEffort,
           projected >= zone.upperBound - response.approachMargin {
            ceilingStreak += 1
            if ceilingStreak >= response.confirmSamples,
               passesCooldown(.zoneCeiling, at: tick.elapsed) {
                mark(.zoneCeiling, at: tick.elapsed)
                cues.append(.approachingZoneCeiling(bpm: bpm, ceiling: zone.upperBound))
            }
        } else {
            ceilingStreak = 0
        }

        if guardConfig.watchFloor, !segment.kind.isEffort,
           projected <= zone.lowerBound + response.approachMargin {
            floorStreak += 1
            if floorStreak >= response.confirmSamples,
               passesCooldown(.zoneFloor, at: tick.elapsed) {
                mark(.zoneFloor, at: tick.elapsed)
                cues.append(.approachingZoneFloor(bpm: bpm, floor: zone.lowerBound))
            }
        } else {
            floorStreak = 0
        }

        return cues
    }

    private func thresholdCues(_ tick: Tick) -> [Cue] {
        guard let bpm = tick.heartRate, let previous = previousHeartRate else { return [] }
        return plan.advisories.thresholdCrossings.compactMap { threshold in
            let rising = previous < threshold && bpm >= threshold
            let falling = previous > threshold && bpm <= threshold
            guard rising || falling, passesCooldown(.threshold(threshold), at: tick.elapsed) else { return nil }
            mark(.threshold(threshold), at: tick.elapsed)
            return .thresholdCrossed(bpm: threshold, rising: rising)
        }
    }

    private func paceCues(_ segment: Segment, tick: Tick, inSegment: TimeInterval) -> [Cue] {
        guard let target = plan.advisories.paceTarget,
              let band = target.bandsByKind[segment.kind],
              let pace = rollingPace,
              inSegment >= target.graceAfterSegmentStart
        else { return [] }

        // Recorded whether or not a cue fires, and regardless of cooldown — the summary
        // needs the pace actually held, not just the moments it was out of range.
        paceObservations[segment.kind, default: []].append(pace)

        guard passesCooldown(.pace, at: tick.elapsed) else { return [] }

        // Lower seconds-per-metre means faster.
        let range = band.range
        if pace < range.lowerBound {
            mark(.pace, at: tick.elapsed)
            paceCueCounts[segment.kind, default: 0] += 1
            return [.paceTooFast(secondsPerMeter: pace)]
        }
        if pace > range.upperBound {
            mark(.pace, at: tick.elapsed)
            paceCueCounts[segment.kind, default: 0] += 1
            return [.paceTooSlow(secondsPerMeter: pace)]
        }
        return []
    }

    private func splitCues(_ tick: Tick) -> [Cue] {
        guard let splits = plan.advisories.distanceSplits, splits.everyMeters > 0 else { return [] }
        let measured = splits.scope == .total
            ? tick.totalDistance
            : tick.totalDistance - segmentStartDistance
        let index = Int(measured / splits.everyMeters)
        guard index > lastSplitIndex else { return [] }
        lastSplitIndex = index
        return [.distanceSplit(index: index, meters: Double(index) * splits.everyMeters)]
    }

    // MARK: - Cooldowns

    private func passesCooldown(_ channel: CueChannel, at elapsed: TimeInterval) -> Bool {
        guard let last = lastCueElapsed[channel] else { return true }
        let window: TimeInterval
        switch channel {
        case .pace: window = plan.advisories.paceTarget?.cooldown ?? 30
        default: window = response.cooldown
        }
        return elapsed - last >= window
    }

    private func mark(_ channel: CueChannel, at elapsed: TimeInterval) {
        lastCueElapsed[channel] = elapsed
    }

    // MARK: - Lag self-calibration

    /// Note that effort just changed, so we can time how long the heart takes to answer.
    private func startLagProbe(leaving segment: Segment, at elapsed: TimeInterval) {
        let nextIndex = (segmentIndex + 1) % max(plan.segments.count, 1)
        guard plan.segments.indices.contains(nextIndex) else { return }
        let next = plan.segments[nextIndex]
        guard next.kind.isEffort != segment.kind.isEffort else { return }
        pendingLagProbe = (elapsed, segment.kind, next.kind)
    }

    /// Watch for the heart rate to turn in the direction the new effort implies. The delay
    /// between the effort change and that inflection is a direct measurement of your lag.
    private func observeLagResponse(at elapsed: TimeInterval) {
        guard let probe = pendingLagProbe else { return }

        // Give up rather than record a bogus outlier if the response never shows.
        if elapsed - probe.at > 180 {
            pendingLagProbe = nil
            return
        }

        let steppedUp = probe.to.isEffort && heartRateSlope > 0.05
        let steppedDown = !probe.to.isEffort && heartRateSlope < -0.05
        guard steppedUp || steppedDown else { return }

        lagObservations.append(
            LagObservation(
                effortChangedAt: probe.at,
                heartRateRespondedAt: elapsed,
                fromKind: probe.from,
                toKind: probe.to
            )
        )
        pendingLagProbe = nil
    }
}
