import XCTest
@testable import RuntilCore

/// Drives an engine through a synthetic run and collects everything it emits.
private struct Recorder {
    var cues: [(elapsed: TimeInterval, cue: Cue)] = []

    var kinds: [SegmentKind] {
        cues.compactMap { if case .beginSegment(let kind, _, _) = $0.cue { return kind } else { return nil } }
    }

    func times(matching predicate: (Cue) -> Bool) -> [TimeInterval] {
        cues.filter { predicate($0.cue) }.map(\.elapsed)
    }

    func contains(_ predicate: (Cue) -> Bool) -> Bool {
        cues.contains { predicate($0.cue) }
    }
}

/// Runs `seconds` of workout, asking the caller for heart rate / pace at each tick.
@discardableResult
private func simulate(
    engine: CueEngine,
    seconds: Int,
    metersPerSecond: (Int, SegmentKind?) -> Double = { _, kind in (kind?.isEffort ?? true) ? 3.0 : 1.4 },
    heartRate: (Int, SegmentKind?) -> Int?
) -> Recorder {
    var recorder = Recorder()
    var distance = 0.0

    for second in 0...seconds {
        let kind = engine.currentSegment?.kind
        let speed = metersPerSecond(second, kind)
        if second > 0 { distance += speed }

        let tick = Tick(
            elapsed: TimeInterval(second),
            totalDistance: distance,
            heartRate: heartRate(second, kind),
            instantPace: speed > 0 ? 1.0 / speed : nil
        )
        for cue in engine.advance(tick) {
            recorder.cues.append((TimeInterval(second), cue))
        }
    }
    return recorder
}

private let testZones = HeartRateZones(method: .direct(edges: [100, 120, 140, 160, 175, 190]))

final class TimedIntervalTests: XCTestCase {

    /// The 90s run / 60s walk pattern from the original ask.
    func testNinetySixtyAlternatesOnSchedule() {
        let plan = WorkoutPlan.timedIntervals(run: 90, walk: 60, repeatCount: 3, zones: testZones)
        let engine = CueEngine(plan: plan)

        let recorder = simulate(engine: engine, seconds: 500) { _, _ in 130 }

        // Expect run at 0, walk at 90, run at 150, walk at 240, run at 300, walk at 390.
        let starts = recorder.cues.compactMap { entry -> (TimeInterval, SegmentKind)? in
            if case .beginSegment(let kind, _, _) = entry.cue { return (entry.elapsed, kind) }
            return nil
        }
        XCTAssertEqual(starts.map(\.1), [.run, .walk, .run, .walk, .run, .walk])
        XCTAssertEqual(starts.map(\.0), [0, 90, 150, 240, 300, 390])
    }

    func testRepeatCountEndsTheWorkout() {
        let plan = WorkoutPlan.timedIntervals(run: 60, walk: 30, repeatCount: 2, zones: testZones)
        let engine = CueEngine(plan: plan)

        let recorder = simulate(engine: engine, seconds: 400) { _, _ in 130 }

        XCTAssertTrue(recorder.contains { $0 == .workoutComplete })
        XCTAssertTrue(engine.isFinished)
        // Two full cycles of run+walk, and no third run.
        XCTAssertEqual(recorder.kinds, [.run, .walk, .run, .walk])
    }

    func testCountdownFiresOncePerSecondBeforeTransition() {
        let plan = WorkoutPlan.timedIntervals(run: 60, walk: 30, repeatCount: 1, zones: testZones)
        let engine = CueEngine(plan: plan)

        let recorder = simulate(engine: engine, seconds: 90) { _, _ in 130 }

        let countdowns = recorder.cues.compactMap { entry -> Int? in
            if case .segmentEndingSoon(let s) = entry.cue { return s } else { return nil }
        }
        XCTAssertEqual(countdowns.prefix(3).sorted(), [1, 2, 3])
    }

    func testNilHeartRateDoesNotBlockTimedPlan() {
        // A watch that never reports HR should still run a time-driven plan correctly.
        let plan = WorkoutPlan.timedIntervals(run: 30, walk: 20, repeatCount: 2, zones: testZones)
        let engine = CueEngine(plan: plan)

        let recorder = simulate(engine: engine, seconds: 120) { _, _ in nil }

        XCTAssertEqual(recorder.kinds, [.run, .walk, .run, .walk])
    }
}

final class HeartRateDrivenTests: XCTestCase {

    /// Zone 2 here is 120–140. Heart rate rises while running and falls while walking,
    /// which is the behaviour the whole plan depends on.
    private func makeEngine(response: HRResponseProfile = .default) -> CueEngine {
        CueEngine(plan: .zoneTwoRunWalk(zones: testZones, response: response))
    }

    func testRunSwitchesToWalkBeforeReachingTheCeiling() {
        let engine = makeEngine()
        var bpm = 110.0

        let recorder = simulate(engine: engine, seconds: 600) { _, kind in
            bpm += (kind?.isEffort ?? true) ? 0.35 : -0.30
            bpm = min(max(bpm, 95), 175)
            return Int(bpm)
        }

        XCTAssertEqual(recorder.kinds.prefix(3), [.run, .walk, .run])

        // The point of projecting HR forward: we switch to walking *before* actually
        // hitting 140, not after overshooting it.
        let ceiling = testZones.range(forZone: 2).upperBound
        XCTAssertLessThan(bpm, Double(ceiling) + 5)
    }

    func testMinDurationPreventsThrashAtTheBoundary() {
        // Heart rate parked right at the Zone 2 ceiling — the pathological case that
        // would otherwise flip run/walk/run every tick.
        let response = HRResponseProfile(lagSeconds: 25, minSegmentDuration: 30)
        let engine = makeEngine(response: response)

        var noise = 0
        let recorder = simulate(engine: engine, seconds: 300) { _, _ in
            noise += 1
            return 140 + (noise % 3) - 1   // 139/140/141, hovering on the line
        }

        let transitions = recorder.kinds.count
        // 300s with a 30s floor can produce at most ~10 transitions; unguarded this
        // would be in the hundreds.
        XCTAssertLessThanOrEqual(transitions, 12)
        XCTAssertGreaterThan(transitions, 1, "should still make progress, not freeze")
    }

    func testMaxDurationRescuesASegmentWhoseTriggerNeverFires() {
        // Heart rate flat at 105 — never reaches the Zone 2 ceiling, so without a
        // ceiling on segment length the runner would run forever.
        let response = HRResponseProfile(maxSegmentDuration: 120)
        let engine = makeEngine(response: response)

        let recorder = simulate(engine: engine, seconds: 400) { _, _ in 105 }

        XCTAssertGreaterThanOrEqual(recorder.kinds.count, 3)
        let runStarts = recorder.times { if case .beginSegment(.walk, _, _) = $0 { return true }; return false }
        XCTAssertEqual(runStarts.first, 120, "should force a switch at the max duration")
    }

    func testFasterClimbTriggersTheSwitchEarlier() {
        // Same ceiling, two different rates of climb. The steeper one should be cued
        // sooner, because the projection sees it coming.
        func firstWalk(slopePerSecond: Double) -> TimeInterval? {
            let engine = makeEngine(response: HRResponseProfile(lagSeconds: 25, minSegmentDuration: 10))
            var bpm = 115.0
            let recorder = simulate(engine: engine, seconds: 400) { _, kind in
                bpm += (kind?.isEffort ?? true) ? slopePerSecond : -0.3
                return Int(min(max(bpm, 95), 180))
            }
            return recorder.times { if case .beginSegment(.walk, _, _) = $0 { return true }; return false }.first
        }

        let fast = firstWalk(slopePerSecond: 0.5)
        let slow = firstWalk(slopePerSecond: 0.2)
        XCTAssertNotNil(fast); XCTAssertNotNil(slow)
        XCTAssertLessThan(fast!, slow!)
    }

    func testLagProfileIsHonoured() {
        // A runner with a long lag should be switched earlier (in HR terms) than one
        // with a short lag, because more projection is applied.
        func heartRateAtFirstWalk(lag: TimeInterval) -> Int? {
            let engine = makeEngine(response: HRResponseProfile(lagSeconds: lag, minSegmentDuration: 10))
            var bpm = 115.0
            var hrAtSwitch: Int?
            var last = 0
            for second in 0...400 {
                let kind = engine.currentSegment?.kind
                bpm += (kind?.isEffort ?? true) ? 0.3 : -0.3
                last = Int(min(max(bpm, 95), 180))
                for cue in engine.advance(Tick(elapsed: TimeInterval(second), totalDistance: Double(second) * 3, heartRate: last)) {
                    if case .beginSegment(.walk, _, _) = cue, hrAtSwitch == nil { hrAtSwitch = last }
                }
            }
            return hrAtSwitch
        }

        let longLag = heartRateAtFirstWalk(lag: 40)
        let shortLag = heartRateAtFirstWalk(lag: 5)
        XCTAssertNotNil(longLag); XCTAssertNotNil(shortLag)
        XCTAssertLessThan(longLag!, shortLag!, "a longer lag should cue at a lower measured HR")
    }

    func testNoTransitionBeforeAnyHeartRateArrives() {
        // HR-driven plan with a sensor that never reports: only the max-duration
        // safety net should move things along, never a phantom trigger.
        let engine = makeEngine(response: HRResponseProfile(maxSegmentDuration: 999))
        let recorder = simulate(engine: engine, seconds: 300) { _, _ in nil }
        XCTAssertEqual(recorder.kinds, [.run], "should stay in the opening segment")
    }
}

final class EffortConfirmationTests: XCTestCase {

    /// A plan that repeats its segment cue until pace confirms the change.
    private func plan(repeatAfter: TimeInterval = 10, maxRepeats: Int = 3) -> WorkoutPlan {
        var plan = WorkoutPlan.timedIntervals(run: 120, walk: 120, repeatCount: 2, zones: testZones)
        plan.advisories.effortConfirmation = EffortConfirmation(
            repeatAfter: repeatAfter,
            maxRepeats: maxRepeats
        )
        return plan
    }

    private func startCues(_ recorder: Recorder, kind: SegmentKind) -> [TimeInterval] {
        recorder.times { cue in
            if case .beginSegment(let k, _, _) = cue { return k == kind }
            return false
        }
    }

    /// A repeat is a `beginSegment` carrying an index and cycle already seen — that's what
    /// distinguishes "the walk segment started" from "you still haven't started walking",
    /// and it's robust to however the timeline happens to fall.
    private func repeatCount(_ recorder: Recorder) -> Int {
        var seen = Set<String>()
        var repeats = 0
        for entry in recorder.cues {
            guard case .beginSegment(let kind, let index, let cycle) = entry.cue else { continue }
            let key = "\(kind)-\(index)-\(cycle)"
            if seen.contains(key) { repeats += 1 } else { seen.insert(key) }
        }
        return repeats
    }

    func testNoRepeatWhenYouActuallyComply() {
        // Runs when told to run, walks when told to walk.
        let engine = CueEngine(plan: plan())
        let recorder = simulate(engine: engine, seconds: 300) { _, _ in 130 }

        XCTAssertEqual(repeatCount(recorder), 0, "complying should never be nagged")
        XCTAssertFalse(startCues(recorder, kind: .run).isEmpty)
    }

    func testRepeatsWhenYouKeepRunningThroughAWalkCue() {
        // Ignores the walk cue and keeps running at 3 m/s throughout.
        let engine = CueEngine(plan: plan())
        let recorder = simulate(
            engine: engine,
            seconds: 300,
            metersPerSecond: { _, _ in 3.0 }
        ) { _, _ in 130 }

        XCTAssertGreaterThan(repeatCount(recorder), 0, "should nag when the walk never happens")
    }

    func testRepeatsAreBounded() {
        // Never complies at all. The nagging has to stop regardless.
        let engine = CueEngine(plan: plan(repeatAfter: 5, maxRepeats: 2))
        let recorder = simulate(
            engine: engine,
            seconds: 240,
            metersPerSecond: { _, _ in 3.0 }
        ) { _, _ in 130 }

        // Each segment may nag at most twice, so a run this length can't exceed a handful.
        XCTAssertLessThanOrEqual(repeatCount(recorder), 6, "nagging must be bounded")
        XCTAssertGreaterThan(repeatCount(recorder), 0)
    }

    func testSilentWithoutPaceData() {
        // Indoors, no GPS. Repeating a cue nobody can satisfy is worse than missing one.
        let engine = CueEngine(plan: plan())
        var recorder = Recorder()
        for second in 0...300 {
            let tick = Tick(elapsed: TimeInterval(second), totalDistance: 0,
                            heartRate: 130, instantPace: nil)
            for cue in engine.advance(tick) { recorder.cues.append((TimeInterval(second), cue)) }
        }
        XCTAssertEqual(repeatCount(recorder), 0, "no pace means no nagging")
    }

    func testComplianceIsJudgedFromSegmentStartNotARollingWindow() {
        // The bug this guards: a 25s rolling window straddles the transition, so ten
        // seconds into a walk it is still mostly running — and would nag someone who is
        // walking perfectly well.
        let engine = CueEngine(plan: plan(repeatAfter: 10))
        let recorder = simulate(engine: engine, seconds: 200) { _, _ in 130 }
        XCTAssertEqual(repeatCount(recorder), 0)
    }

    /// Runs a plan and reports, per second, whether the screen would be showing the big
    /// RUN / WALK prompt.
    private func promptTimeline(
        engine: CueEngine,
        seconds: Int,
        metersPerSecond: (Int, SegmentKind?) -> Double
    ) -> [Bool] {
        var timeline: [Bool] = []
        var distance = 0.0
        for second in 0...seconds {
            let speed = metersPerSecond(second, engine.currentSegment?.kind)
            if second > 0 { distance += speed }
            _ = engine.advance(
                Tick(elapsed: TimeInterval(second), totalDistance: distance,
                     heartRate: 130, instantPace: speed > 0 ? 1.0 / speed : nil)
            )
            timeline.append(engine.isPromptingEffortChange)
        }
        return timeline
    }

    func testPromptAppearsAtTheCueAndClearsOnceYouComply() {
        let engine = CueEngine(plan: plan())
        let timeline = promptTimeline(engine: engine, seconds: 60) { _, kind in
            (kind?.isEffort ?? true) ? 3.0 : 1.4
        }

        XCTAssertTrue(timeline[0], "the opening cue should put RUN on screen")
        // Pace needs a few samples before it can confirm anything, but not many.
        XCTAssertFalse(timeline[15], "running should clear the prompt promptly")
        XCTAssertFalse(
            timeline[16...60].contains(true),
            "a compliant runner should never see the prompt again mid-segment"
        )
    }

    func testPromptReappearsAtTheNextSegment() {
        // 120s run then 120s walk, complying with both.
        let engine = CueEngine(plan: plan())
        let timeline = promptTimeline(engine: engine, seconds: 200) { _, kind in
            (kind?.isEffort ?? true) ? 3.0 : 1.4
        }
        XCTAssertTrue(timeline[120], "the walk cue should put WALK on screen")
        XCTAssertTrue(
            timeline[121...135].contains(false),
            "and it should clear again once you're walking"
        )
    }

    func testPromptGivesUpWhenYouNeverComply() {
        // Keeps running straight through the walk cue. The word must not sit there for
        // the rest of the segment — an instruction nobody is going to follow, or a
        // threshold that's simply wrong for this person, has to time out like the nagging.
        let engine = CueEngine(plan: plan(repeatAfter: 5, maxRepeats: 2))
        let timeline = promptTimeline(engine: engine, seconds: 200) { _, _ in 3.0 }

        XCTAssertTrue(timeline[120], "the walk cue should still show")
        XCTAssertFalse(timeline[119 + 5 * 3 + 2], "and should give up on schedule")
    }

    func testPromptClearsWithoutPaceData() {
        // Indoors: nothing can ever confirm. Bounded by the same window.
        let engine = CueEngine(plan: plan(repeatAfter: 5, maxRepeats: 2))
        var timeline: [Bool] = []
        for second in 0...60 {
            _ = engine.advance(Tick(elapsed: TimeInterval(second), totalDistance: 0,
                                    heartRate: 130, instantPace: nil))
            timeline.append(engine.isPromptingEffortChange)
        }
        XCTAssertTrue(timeline[0])
        XCTAssertFalse(timeline[30], "no pace must not mean a permanent instruction")
    }

    func testThresholdClassifiesPaces() {
        let confirmation = EffortConfirmation()
        // 3 m/s is running; 1.4 m/s is walking.
        XCTAssertEqual(confirmation.matchesEffort(.run, pace: 1.0 / 3.0), true)
        XCTAssertEqual(confirmation.matchesEffort(.walk, pace: 1.0 / 3.0), false)
        XCTAssertEqual(confirmation.matchesEffort(.walk, pace: 1.0 / 1.4), true)
        XCTAssertEqual(confirmation.matchesEffort(.run, pace: 1.0 / 1.4), false)
        XCTAssertNil(confirmation.matchesEffort(.run, pace: nil))
        XCTAssertNil(confirmation.matchesEffort(.run, pace: 0))
    }
}

final class AdvisoryTests: XCTestCase {

    func testDistanceSplitsFireEveryHalfMile() {
        var plan = WorkoutPlan.timedIntervals(run: 600, walk: 600, repeatCount: 1, zones: testZones)
        plan.advisories.distanceSplits = .every(0.5, .miles)
        let engine = CueEngine(plan: plan)

        // 3 m/s for 1200s ≈ 3600 m ≈ 2.24 miles → 4 half-mile splits.
        let recorder = simulate(engine: engine, seconds: 1200, metersPerSecond: { _, _ in 3.0 }) { _, _ in 130 }

        let splits = recorder.cues.compactMap { entry -> Int? in
            if case .distanceSplit(let index, _) = entry.cue { return index } else { return nil }
        }
        XCTAssertEqual(splits, [1, 2, 3, 4])
    }

    func testHeartRateGuardRespectsConfirmationStreakAndCooldown() {
        var plan = WorkoutPlan.timedIntervals(run: 600, walk: 60, repeatCount: 1, zones: testZones)
        plan.advisories.heartRateGuard = HeartRateGuard(zone: 2)
        plan.hrResponse = HRResponseProfile(lagSeconds: 10, approachMargin: 5, confirmSamples: 3, cooldown: 45)
        let engine = CueEngine(plan: plan)

        // Pinned just under the ceiling for the whole run — a naive implementation
        // would buzz every single second.
        let recorder = simulate(engine: engine, seconds: 300) { _, _ in 138 }

        let warnings = recorder.times { if case .approachingZoneCeiling = $0 { return true }; return false }
        XCTAssertFalse(warnings.isEmpty, "should warn at least once")
        // 300s at a 45s cooldown allows ~7 at most.
        XCTAssertLessThanOrEqual(warnings.count, 8)
        for (a, b) in zip(warnings, warnings.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b - a, 45, "cooldown must be respected")
        }
    }

    func testHeartRateGuardStaysQuietOnHeartRateDrivenPlans() {
        // The transition already says "change effort"; a second cue would be noise.
        let engine = CueEngine(plan: .zoneTwoRunWalk(zones: testZones))
        let recorder = simulate(engine: engine, seconds: 300) { _, _ in 138 }

        XCTAssertFalse(recorder.contains { if case .approachingZoneCeiling = $0 { return true }; return false })
    }

    func testPaceCuesRespectGracePeriod() {
        var plan = WorkoutPlan.timedIntervals(run: 600, walk: 60, repeatCount: 1, zones: testZones)
        plan.advisories.paceTarget = PaceTarget(
            bandsByKind: [.run: .perUnit(target: 9 * 60, tolerance: 60, unit: .miles)],
            window: 10,
            cooldown: 30,
            graceAfterSegmentStart: 20
        )
        let engine = CueEngine(plan: plan)

        // ~5:22/mi — far too fast for an 8–10:00 band.
        let recorder = simulate(engine: engine, seconds: 200, metersPerSecond: { _, _ in 5.0 }) { _, _ in 130 }

        let tooFast = recorder.times { if case .paceTooFast = $0 { return true }; return false }
        XCTAssertFalse(tooFast.isEmpty)
        XCTAssertGreaterThanOrEqual(tooFast.first!, 20, "must not scold during the grace period")
    }

    func testMissingGPSProducesNoPaceCues() {
        var plan = WorkoutPlan.timedIntervals(run: 600, walk: 60, repeatCount: 1, zones: testZones)
        plan.advisories.paceTarget = PaceTarget(
            bandsByKind: [.run: .perUnit(target: 9 * 60, tolerance: 60, unit: .miles)]
        )
        let engine = CueEngine(plan: plan)

        var recorder = Recorder()
        for second in 0...200 {
            let tick = Tick(elapsed: TimeInterval(second), totalDistance: 0, heartRate: 130, instantPace: nil)
            for cue in engine.advance(tick) { recorder.cues.append((TimeInterval(second), cue)) }
        }

        XCTAssertFalse(recorder.contains {
            if case .paceTooFast = $0 { return true }
            if case .paceTooSlow = $0 { return true }
            return false
        })
    }

    func testThresholdCrossingFiresOnceInEachDirection() {
        var plan = WorkoutPlan.timedIntervals(run: 600, walk: 600, repeatCount: 1, zones: testZones)
        plan.advisories.thresholdCrossings = [150]
        plan.advisories.heartRateGuard = nil
        let engine = CueEngine(plan: plan)

        // Up through 150 and back down again.
        let recorder = simulate(engine: engine, seconds: 400) { second, _ in
            second < 200 ? 120 + second / 4 : 170 - (second - 200) / 4
        }

        let crossings = recorder.cues.compactMap { entry -> Bool? in
            if case .thresholdCrossed(_, let rising) = entry.cue { return rising } else { return nil }
        }
        XCTAssertEqual(crossings, [true, false])
    }

    func testHigherPriorityCueSortsFirstOnCollision() {
        var plan = WorkoutPlan.timedIntervals(run: 30, walk: 30, repeatCount: 4, zones: testZones)
        plan.advisories.distanceSplits = DistanceSplits(everyMeters: 90)  // lands on a boundary
        let engine = CueEngine(plan: plan)

        var sawBoundaryFirst = false
        for second in 0...200 {
            // 3 m/s against 30s segments puts a 90 m split exactly on every boundary.
            let distance = 3.0 * Double(second)
            let cues = engine.advance(Tick(elapsed: TimeInterval(second), totalDistance: distance, heartRate: 130))
            if cues.count > 1, case .beginSegment = cues[0] { sawBoundaryFirst = true }
            // Whatever else happens, the list must be ordered by descending priority.
            XCTAssertEqual(cues.map(\.priority), cues.map(\.priority).sorted(by: >))
        }
        XCTAssertTrue(sawBoundaryFirst, "a segment boundary must outrank a split on the same tick")
    }
}

final class LagCalibrationTests: XCTestCase {

    func testMeasuresLagFromObservedHeartRateResponse() {
        // Heart rate that genuinely lags effort by ~20s, then responds.
        let plan = WorkoutPlan.timedIntervals(run: 120, walk: 120, repeatCount: 3, zones: testZones)
        let engine = CueEngine(plan: plan)

        var bpm = 120.0
        var pendingDirection = 1.0
        var switchSecond = -1000

        _ = simulate(engine: engine, seconds: 700) { second, kind in
            let wanted = (kind?.isEffort ?? true) ? 1.0 : -1.0
            if wanted != pendingDirection { pendingDirection = wanted; switchSecond = second }
            // Only start moving 20s after the effort actually changed.
            if second - switchSecond >= 20 { bpm += pendingDirection * 0.25 }
            bpm = min(max(bpm, 110), 165)
            return Int(bpm)
        }

        let suggested = engine.lagObservations.suggestedLagSeconds
        XCTAssertNotNil(suggested, "should measure at least one response")
        if let suggested {
            XCTAssertGreaterThan(suggested, 5)
            XCTAssertLessThan(suggested, 60)
        }
    }

    func testMedianIgnoresASingleWildOutlier() {
        let observations = [
            LagObservation(effortChangedAt: 0, heartRateRespondedAt: 22, fromKind: .run, toKind: .walk),
            LagObservation(effortChangedAt: 100, heartRateRespondedAt: 124, fromKind: .walk, toKind: .run),
            LagObservation(effortChangedAt: 200, heartRateRespondedAt: 226, fromKind: .run, toKind: .walk),
            LagObservation(effortChangedAt: 300, heartRateRespondedAt: 475, fromKind: .walk, toKind: .run)
        ]
        let suggested = observations.suggestedLagSeconds
        XCTAssertNotNil(suggested)
        XCTAssertEqual(suggested!, 25, accuracy: 3, "median should reject the 175s outlier")
    }
}

final class HeartRateMeasurementTests: XCTestCase {

    func testEightBitValue() {
        // flags 0x00: 8-bit value, contact not supported.
        let reading = HeartRateMeasurement.parse([0x00, 0x8A])
        XCTAssertEqual(reading?.bpm, 138)
        XCTAssertFalse(reading?.isPoorContact ?? true)
    }

    func testSixteenBitValueIsLittleEndian() {
        // flags 0x01: 16-bit. 0x008A little-endian is 138, not 0x8A00.
        XCTAssertEqual(HeartRateMeasurement.parse([0x01, 0x8A, 0x00])?.bpm, 138)
    }

    func testEightBitPacketIsNotMisreadAsSixteen() {
        // The bug this guards: assuming a width instead of reading the flag. An 8-bit
        // packet read as 16-bit would pull in whatever byte follows.
        let eight = HeartRateMeasurement.parse([0x00, 0x64, 0xFF])
        XCTAssertEqual(eight?.bpm, 100, "must stop after one byte when the flag says 8-bit")
    }

    func testPoorContactOnlyWhenSupportedAndAbsent() {
        // 0x04 = contact supported, bit 1 clear = no contact detected.
        XCTAssertTrue(HeartRateMeasurement.parse([0x04, 0x8A])?.isPoorContact ?? false)
        // 0x06 = supported and detected.
        XCTAssertFalse(HeartRateMeasurement.parse([0x06, 0x8A])?.isPoorContact ?? true)
        // 0x00 = can't tell. A strap that doesn't report contact must not look fallen off.
        XCTAssertFalse(HeartRateMeasurement.parse([0x00, 0x8A])?.isPoorContact ?? true)
    }

    func testRejectsMalformedAndImpossiblePackets() {
        XCTAssertNil(HeartRateMeasurement.parse([]), "empty")
        XCTAssertNil(HeartRateMeasurement.parse([0x00]), "flags only")
        XCTAssertNil(HeartRateMeasurement.parse([0x01, 0x8A]), "16-bit flag, one byte")
        XCTAssertNil(HeartRateMeasurement.parse([0x00, 0x00]), "0 bpm")
        XCTAssertNil(HeartRateMeasurement.parse([0x01, 0xFF, 0xFF]), "65535 bpm")
    }

    func testIgnoresTrailingOptionalFields() {
        // Straps often append energy expended and RR intervals; the heart rate is still
        // the leading field and must parse regardless of what follows.
        let withExtras = HeartRateMeasurement.parse([0x18, 0x8A, 0x10, 0x00, 0x2C, 0x01])
        XCTAssertEqual(withExtras?.bpm, 138)
    }
}

final class PlanMergeTests: XCTestCase {

    private func plan(_ name: String, id: UUID, modified: Date) -> WorkoutPlan {
        var p = WorkoutPlan.timedIntervals(run: 60, walk: 60, zones: testZones)
        p.id = id
        p.name = name
        p.modifiedAt = modified
        return p
    }

    func testWristEditSurvivesAPhonePush() {
        // The whole point: a tweak made on the watch must not be silently overwritten by
        // the phone's next sync.
        let id = UUID()
        let now = Date()
        let onWatch = plan("Edited on wrist", id: id, modified: now)
        let onPhone = plan("Stale", id: id, modified: now.addingTimeInterval(-600))

        let merged = PlanMerge.merge(incoming: [onPhone], local: [onWatch])
        XCTAssertEqual(merged.map(\.name), ["Edited on wrist"])
    }

    func testNewerPhoneEditWins() {
        let id = UUID()
        let now = Date()
        let onWatch = plan("Old wrist edit", id: id, modified: now.addingTimeInterval(-600))
        let onPhone = plan("Fresh from phone", id: id, modified: now)

        let merged = PlanMerge.merge(incoming: [onPhone], local: [onWatch])
        XCTAssertEqual(merged.map(\.name), ["Fresh from phone"])
    }

    func testPhoneDeletionsPropagate() {
        // The phone owns the library, so a plan it no longer lists should disappear even
        // if the watch still has a copy.
        let keep = plan("Keep", id: UUID(), modified: Date())
        let deleted = plan("Deleted on phone", id: UUID(), modified: Date())

        let merged = PlanMerge.merge(incoming: [keep], local: [keep, deleted])
        XCTAssertEqual(merged.map(\.name), ["Keep"])
    }

    func testNewPhonePlansArrive() {
        let existing = plan("Existing", id: UUID(), modified: Date())
        let fresh = plan("Brand new", id: UUID(), modified: Date())

        let merged = PlanMerge.merge(incoming: [existing, fresh], local: [existing])
        XCTAssertEqual(merged.count, 2)
        XCTAssertTrue(merged.contains { $0.name == "Brand new" })
    }

    func testEmptyPushDoesNotWipeTheWatch() {
        // A failed encode or a first-run race must not read as "delete everything".
        let mine = plan("Mine", id: UUID(), modified: Date())
        XCTAssertEqual(PlanMerge.merge(incoming: [], local: [mine]).map(\.name), ["Mine"])
    }

    func testLegacyPlanWithoutTimestampLosesToAnEdit() throws {
        // A plan saved before modifiedAt existed decodes as .distantPast, so any real
        // edit beats it rather than the other way round.
        let id = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "name": "Legacy",
          "driveMode": "time",
          "segments": [],
          "zones": { "method": { "direct": { "edges": [100,120,140,160,175,190] } } }
        }
        """.data(using: .utf8)!
        let legacy = try JSONDecoder().decode(WorkoutPlan.self, from: json)
        XCTAssertEqual(legacy.modifiedAt, .distantPast)

        let edited = plan("Edited", id: id, modified: Date())
        XCTAssertEqual(PlanMerge.merge(incoming: [legacy], local: [edited]).map(\.name), ["Edited"])
    }
}

final class ZoneTests: XCTestCase {

    func testDirectEdgesAreUsedVerbatim() {
        let zones = HeartRateZones(method: .direct(edges: [100, 120, 140, 160, 175, 190]))
        XCTAssertEqual(zones.range(forZone: 2), 120...140)
        XCTAssertEqual(zones.zone(for: 130), 2)
    }

    func testPercentMaxMatchesHandCalculation() {
        let zones = HeartRateZones(method: .percentMax(maxHR: 190))
        XCTAssertEqual(zones.range(forZone: 2), 114...133)   // 60–70% of 190
    }

    func testKarvonenAccountsForRestingHeartRate() {
        // Reserve 130; zone 2 = 60–70% of reserve above resting.
        let zones = HeartRateZones(method: .karvonen(maxHR: 190, restingHR: 60))
        XCTAssertEqual(zones.range(forZone: 2), 138...151)
    }

    func testKarvonenSitsHigherThanPercentMaxForTheSameRunner() {
        // A well-known property worth pinning down: ignoring resting HR underestimates zones.
        let percent = HeartRateZones(method: .percentMax(maxHR: 190)).range(forZone: 2)
        let karvonen = HeartRateZones(method: .karvonen(maxHR: 190, restingHR: 60)).range(forZone: 2)
        XCTAssertGreaterThan(karvonen.lowerBound, percent.lowerBound)
    }

    func testTanakaEstimate() {
        XCTAssertEqual(HeartRateZones.tanakaMaxHR(age: 40), 180)
    }

    func testOutOfRangeZoneIsClampedNotCrashed() {
        let zones = HeartRateZones(method: .direct(edges: [100, 120, 140, 160, 175, 190]))
        XCTAssertEqual(zones.range(forZone: 99), 175...190)
        XCTAssertEqual(zones.range(forZone: 0), 100...120)
        XCTAssertNil(zones.zone(for: 40))
    }
}

final class ProfileAndFormatTests: XCTestCase {

    func testMinSegmentDurationTracksLagUnlessOverridden() {
        XCTAssertEqual(HRResponseProfile(lagSeconds: 25).effectiveMinSegmentDuration, 30)
        XCTAssertEqual(HRResponseProfile(lagSeconds: 60).effectiveMinSegmentDuration, 65)
        XCTAssertEqual(
            HRResponseProfile(lagSeconds: 60, minSegmentDuration: 15).effectiveMinSegmentDuration,
            15,
            "an explicit override must win"
        )
    }

    func testPlanSurvivesACodableRoundTrip() throws {
        let plan = WorkoutPlan.zoneTwoRunWalk(
            zones: HeartRateZones(method: .karvonen(maxHR: 190, restingHR: 55)),
            response: HRResponseProfile(lagSeconds: 33)
        )
        let data = try JSONEncoder().encode(plan)
        let decoded = try JSONDecoder().decode(WorkoutPlan.self, from: data)
        XCTAssertEqual(decoded, plan)
        XCTAssertEqual(decoded.hrResponse.lagSeconds, 33)
    }

    func testPlanDecodesWhenNewerFieldsAreMissing() throws {
        // A library written before a field existed must still load, defaulting the missing
        // value rather than throwing and wiping every saved plan.
        let json = """
        {
          "id": "5E9B1C1A-0000-4000-8000-000000000001",
          "name": "Legacy",
          "driveMode": "time",
          "segments": [],
          "zones": { "method": { "direct": { "edges": [100,120,140,160,175,190] } } }
        }
        """.data(using: .utf8)!

        let plan = try JSONDecoder().decode(WorkoutPlan.self, from: json)
        XCTAssertEqual(plan.name, "Legacy")
        XCTAssertTrue(plan.savesToHealth, "should default to saving")
        XCTAssertEqual(plan.units, .miles)
        XCTAssertEqual(plan.hrResponse, .default)
    }

    func testSavesToHealthSurvivesRoundTrip() throws {
        var plan = WorkoutPlan.timedIntervals(run: 60, walk: 60, zones: testZones)
        plan.savesToHealth = false
        let decoded = try JSONDecoder().decode(
            WorkoutPlan.self,
            from: try JSONEncoder().encode(plan)
        )
        XCTAssertFalse(decoded.savesToHealth)
    }

    func testPaceFormatting() {
        let nineThirtyPerMile = (9 * 60 + 30) / 1609.344
        XCTAssertEqual(Format.pace(secondsPerMeter: nineThirtyPerMile, unit: .miles), "9:30 /mi")
        XCTAssertEqual(Format.pace(secondsPerMeter: nil, unit: .miles), "--:-- /mi")
        // A near-stationary reading is noise, not a pace.
        XCTAssertEqual(Format.pace(secondsPerMeter: 5.0, unit: .miles), "--:-- /mi")
    }

    func testDurationFormatting() {
        XCTAssertEqual(Format.duration(90), "1:30")
        XCTAssertEqual(Format.duration(3862), "1:04:22")
        XCTAssertEqual(Format.compactDuration(90), "1:30")
        XCTAssertEqual(Format.compactDuration(120), "2m")
        XCTAssertEqual(Format.compactDuration(45), "45s")
    }
}
