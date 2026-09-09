import XCTest
@testable import RuntilCore

final class SegmentRecordingTests: XCTestCase {

    private let zones = HeartRateZones(method: .direct(edges: [100, 120, 140, 160, 175, 190]))

    /// Feeds a plan a run at a steady speed and returns the engine.
    private func run(plan: WorkoutPlan, seconds: Int, metersPerSecond: Double) -> CueEngine {
        let engine = CueEngine(plan: plan)
        var distance = 0.0
        for second in 0...seconds {
            if second > 0 { distance += metersPerSecond }
            _ = engine.advance(
                Tick(elapsed: TimeInterval(second), totalDistance: distance,
                     heartRate: 130, instantPace: 1.0 / metersPerSecond)
            )
        }
        return engine
    }

    func testEverySegmentIsLoggedWithItsOwnBoundaries() {
        let plan = WorkoutPlan.timedIntervals(run: 60, walk: 30, repeatCount: 2, zones: zones)
        let engine = run(plan: plan, seconds: 180, metersPerSecond: 2.0)

        XCTAssertEqual(engine.segmentLog.map(\.kind), [.run, .walk, .run, .walk])
        XCTAssertEqual(engine.segmentLog.map(\.start), [0, 60, 90, 150])
        XCTAssertEqual(engine.segmentLog.map(\.cycle), [0, 0, 1, 1])
        // Distance is taken from the tick, so it reflects what was actually covered.
        XCTAssertEqual(engine.segmentLog[0].distance, 120, accuracy: 0.001)
        XCTAssertEqual(engine.segmentLog[1].distance, 60, accuracy: 0.001)
    }

    func testEndingMidSegmentStillRecordsThePartYouDid() {
        // Stopping a run halfway through an interval is the normal way runs end. Losing
        // that segment entirely would drop real minutes off the breakdown.
        let plan = WorkoutPlan.timedIntervals(run: 60, walk: 30, repeatCount: 10, zones: zones)
        let engine = run(plan: plan, seconds: 100, metersPerSecond: 2.0)
        XCTAssertEqual(engine.segmentLog.count, 2, "two boundaries have passed")

        engine.closeOpenSegment(at: 100, totalDistance: 200)
        XCTAssertEqual(engine.segmentLog.count, 3)
        XCTAssertEqual(engine.segmentLog.last?.kind, .run)
        XCTAssertEqual(engine.segmentLog.last?.start, 90)
        XCTAssertEqual(engine.segmentLog.last?.end, 100)
    }

    func testClosingTwiceDoesNotDoubleCount() {
        // The caller can't easily tell whether the plan closed the segment itself.
        let plan = WorkoutPlan.timedIntervals(run: 60, walk: 30, repeatCount: 10, zones: zones)
        let engine = run(plan: plan, seconds: 100, metersPerSecond: 2.0)
        engine.closeOpenSegment(at: 100, totalDistance: 200)
        engine.closeOpenSegment(at: 100, totalDistance: 200)
        XCTAssertEqual(engine.segmentLog.count, 3)
    }

    func testSkippingASegmentRecordsItsRealLength() {
        let plan = WorkoutPlan.timedIntervals(run: 600, walk: 600, repeatCount: 2, zones: zones)
        let engine = CueEngine(plan: plan)
        _ = engine.advance(Tick(elapsed: 0, totalDistance: 0, heartRate: 130, instantPace: 0.5))
        _ = engine.advance(Tick(elapsed: 20, totalDistance: 40, heartRate: 130, instantPace: 0.5))
        _ = engine.skipSegment(at: 20, totalDistance: 40)

        XCTAssertEqual(engine.segmentLog.count, 1)
        XCTAssertEqual(engine.segmentLog[0].duration, 20)
        XCTAssertEqual(engine.segmentLog[0].distance, 40, accuracy: 0.001)
    }
}

final class SegmentBreakdownTests: XCTestCase {

    private func distances(seconds: Int, metersPerSecond: Double) -> [(elapsed: TimeInterval, distance: Double)] {
        (0...seconds).map { (TimeInterval($0), Double($0) * metersPerSecond) }
    }

    func testDistanceAndHeartRateAreAttributedToTheRightSegment() {
        let heartRate: [(elapsed: TimeInterval, bpm: Int)] =
            (0...120).map { (TimeInterval($0), $0 < 60 ? 150 : 110) }

        let summaries = RunAnalysis.segmentBreakdown(
            segments: [(.run, 0, 60), (.walk, 60, 120)],
            heartRate: heartRate,
            distances: distances(seconds: 120, metersPerSecond: 2.0)
        )

        XCTAssertEqual(summaries.count, 2)
        XCTAssertEqual(summaries[0].kind, .run)
        XCTAssertEqual(summaries[0].distanceMeters, 120, accuracy: 0.001)
        XCTAssertEqual(summaries[0].averageHeartRate, 150)
        XCTAssertEqual(summaries[1].averageHeartRate, 110)
        XCTAssertEqual(summaries[1].distanceMeters, 120, accuracy: 0.001)
        XCTAssertEqual(summaries[0].ordinal, 1)
        XCTAssertEqual(summaries[1].ordinal, 2)
    }

    func testABoundaryReadingIsCountedOnceNotTwice() {
        // The reading at the boundary belongs to the segment starting there. Counting it
        // in both drags the average of the segment that just ended toward the new effort.
        let summaries = RunAnalysis.segmentBreakdown(
            segments: [(.run, 0, 60), (.walk, 60, 120)],
            heartRate: (0...120).map { (TimeInterval($0), $0 < 60 ? 150 : 110) },
            distances: distances(seconds: 120, metersPerSecond: 2.0)
        )
        XCTAssertEqual(summaries[0].averageHeartRate, 150, "the run's average is untouched by the walk")
        XCTAssertEqual(summaries[1].averageHeartRate, 110)
    }

    func testDistanceIsInterpolatedBetweenFixes() {
        // Boundaries land where heart rate or the clock put them, not on a GPS fix.
        // Rounding to the nearer fix hands a second of distance to the wrong segment.
        let samples: [(elapsed: TimeInterval, distance: Double)] = [(0, 0), (10, 30), (20, 60)]
        XCTAssertEqual(RunAnalysis.distance(atElapsed: 5, in: samples), 15, accuracy: 0.001)
        XCTAssertEqual(RunAnalysis.distance(atElapsed: 15, in: samples), 45, accuracy: 0.001)
        // Outside the range, clamp rather than extrapolate.
        XCTAssertEqual(RunAnalysis.distance(atElapsed: -5, in: samples), 0, accuracy: 0.001)
        XCTAssertEqual(RunAnalysis.distance(atElapsed: 99, in: samples), 60, accuracy: 0.001)
    }

    func testPaceIsUnknownRatherThanZeroWithoutDistance() {
        // A treadmill run has segments and heart rates but no GPS. "0:00 /mi" reads as
        // impossibly fast; nothing at all reads as what it is.
        let summaries = RunAnalysis.segmentBreakdown(
            segments: [(.run, 0, 60)],
            heartRate: [(0, 150), (30, 152), (60, 148)],
            distances: []
        )
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries[0].distanceMeters, 0)
        XCTAssertNil(summaries[0].secondsPerMeter)
        XCTAssertEqual(summaries[0].averageHeartRate, 150)
        XCTAssertEqual(summaries[0].maxHeartRate, 152)
    }

    func testSegmentWithNoHeartRateSamplesReportsNone() {
        let summaries = RunAnalysis.segmentBreakdown(
            segments: [(.run, 0, 60), (.walk, 60, 120)],
            heartRate: [(0, 150), (30, 150)],
            distances: distances(seconds: 120, metersPerSecond: 2.0)
        )
        XCTAssertEqual(summaries[0].averageHeartRate, 150)
        XCTAssertNil(summaries[1].averageHeartRate)
        XCTAssertNil(summaries[1].maxHeartRate)
    }
}
