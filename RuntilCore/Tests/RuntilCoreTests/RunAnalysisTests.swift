import XCTest
@testable import RuntilCore

private let testZones = HeartRateZones(method: .direct(edges: [100, 120, 140, 160, 175, 190]))

final class ElevationTests: XCTestCase {

    /// Altitudes are sampled at roughly 1 Hz on a real run, so a hill spans tens of
    /// samples. Tests use that density — compressing a hill into four points would make
    /// the smoothing look destructive when on real data it isn't.

    func testFlatRunWithNoiseReportsNoClimb() {
        // The bug this exists to prevent: altitude wanders even standing still, and
        // summing positive deltas turns a flat run into a mountain. Note ±1.5m swings 3m
        // peak to peak, so a 2m threshold alone does NOT catch this — smoothing is what
        // makes it work.
        let noisy = (0..<200).map { i in 100.0 + (i % 2 == 0 ? 1.5 : -1.5) }
        XCTAssertEqual(RunAnalysis.elevationGain(altitudes: noisy), 0, accuracy: 0.5)
    }

    func testFlatRunWithRandomNoiseReportsNoClimb() {
        // Alternating noise is the easy case; random wander is what a sensor actually does.
        var generator = SystemRandomNumberGenerator()
        let noisy = (0..<300).map { _ in 100.0 + Double.random(in: -1.5...1.5, using: &generator) }
        XCTAssertLessThan(RunAnalysis.elevationGain(altitudes: noisy), 5.0)
    }

    func testSteadyClimbIsCounted() {
        // 50m over 100 samples. A symmetric moving average leaves a straight line
        // untouched, so this should come back exact.
        let climb = (0...100).map { 100.0 + Double($0) * 0.5 }
        XCTAssertEqual(RunAnalysis.elevationGain(altitudes: climb), 50, accuracy: 0.5)
    }

    func testDescentDoesNotSubtractFromGain() {
        // Up 50, back down 50. Gain is 50, not 0 — this measures ascent, not net change.
        let up = (0...100).map { 100.0 + Double($0) * 0.5 }
        let down = (1...100).map { 150.0 - Double($0) * 0.5 }
        // Smoothing rounds the summit, so a metre or two of slack is expected and correct.
        XCTAssertEqual(RunAnalysis.elevationGain(altitudes: up + down), 50, accuracy: 2.0)
    }

    func testRollingCourseCountsEachClimb() {
        // Three 10m hills, each spanning 40 samples.
        var rolling: [Double] = []
        for _ in 0..<3 {
            rolling += (0..<20).map { 100.0 + Double($0) * 0.5 }
            rolling += (0..<20).map { 110.0 - Double($0) * 0.5 }
        }
        XCTAssertEqual(RunAnalysis.elevationGain(altitudes: rolling), 30, accuracy: 3.0)
    }

    func testRealClimbSurvivesRealisticNoise() {
        // The case that matters: a genuine 40m climb measured by a noisy sensor. Filtering
        // must not throw away the signal along with the noise.
        var generator = SystemRandomNumberGenerator()
        let climb = (0...200).map { index in
            100.0 + Double(index) * 0.2 + Double.random(in: -1.5...1.5, using: &generator)
        }
        XCTAssertEqual(RunAnalysis.elevationGain(altitudes: climb), 40, accuracy: 6.0)
    }

    func testDegenerateInput() {
        XCTAssertEqual(RunAnalysis.elevationGain(altitudes: []), 0)
        XCTAssertEqual(RunAnalysis.elevationGain(altitudes: [100]), 0)
    }

    func testThresholdGovernsReversalsNotTotalClimb() {
        // A clean monotonic climb contains no reversals to reject, so the threshold must
        // not change it. Five metres of climbing is five metres however suspicious you
        // are of the sensor — the threshold is about noise, not about gradient.
        let clean = (0...100).map { 100.0 + Double($0) * 0.05 }   // 5m over 100 samples
        XCTAssertEqual(RunAnalysis.elevationGain(altitudes: clean, threshold: 2.0), 5, accuracy: 0.5)
        XCTAssertEqual(RunAnalysis.elevationGain(altitudes: clean, threshold: 20.0), 5, accuracy: 0.5)
    }

    func testLargerThresholdMergesSmallDips() {
        // A climb interrupted by a small dip. A tight threshold treats it as two climbs
        // and counts the re-ascent; a loose one reads the dip as noise and counts the net
        // rise once. That difference is what the threshold actually controls.
        var course = (0..<40).map { 100.0 + Double($0) * 0.5 }    // 100 → 119.5
        course += (0..<12).map { 120.0 - Double($0) * 0.4 }       // dip ≈ 4.5m
        course += (0..<40).map { 115.5 + Double($0) * 0.5 }       // → 135

        let tight = RunAnalysis.elevationGain(altitudes: course, threshold: 2.0)
        let loose = RunAnalysis.elevationGain(altitudes: course, threshold: 12.0)
        XCTAssertGreaterThan(tight, loose, "a tight threshold should count the re-ascent")
        XCTAssertEqual(loose, 35, accuracy: 2.0, "a loose threshold sees one climb of ~35m")
    }

    func testSmoothingPreservesAStraightLine() {
        let line = (0...50).map { Double($0) }
        let smoothed = RunAnalysis.movingAverage(line, radius: 2)
        for (original, result) in zip(line, smoothed) {
            XCTAssertEqual(original, result, accuracy: 0.001)
        }
    }
}

final class SplitTests: XCTestCase {

    /// A steady 3 m/s run, sampled every second.
    private func steadyRun(seconds: Int, speed: Double = 3.0) -> [(elapsed: TimeInterval, distance: Double)] {
        (0...seconds).map { (TimeInterval($0), Double($0) * speed) }
    }

    func testEvenSplitsAtSteadyPace() {
        let samples = steadyRun(seconds: 1200)          // 3600 m
        let splits = RunAnalysis.splits(samples: samples, every: 1000)

        XCTAssertEqual(splits.filter { !$0.isPartial }.count, 3)
        for split in splits where !split.isPartial {
            // 1000m at 3 m/s is 333.3s.
            XCTAssertEqual(split.duration, 1000.0 / 3.0, accuracy: 0.5)
        }
    }

    func testFinalPartialSplitIsKeptAndFlagged() {
        let samples = steadyRun(seconds: 500)           // 1500 m
        let splits = RunAnalysis.splits(samples: samples, every: 1000)

        XCTAssertEqual(splits.count, 2)
        XCTAssertFalse(splits[0].isPartial)
        XCTAssertTrue(splits[1].isPartial, "the leftover 500m must not be silently dropped")
        XCTAssertEqual(splits[1].distanceMeters, 500, accuracy: 1)
    }

    func testBoundaryIsInterpolatedBetweenSamples() {
        // Sparse samples 10s apart, so the 1000m mark falls between two of them. Rounding
        // to the nearer sample would be off by up to 15 seconds.
        let sparse: [(elapsed: TimeInterval, distance: Double)] =
            stride(from: 0, through: 600, by: 10).map { (TimeInterval($0), Double($0) * 3.0) }
        let splits = RunAnalysis.splits(samples: sparse, every: 1000)

        XCTAssertEqual(splits[0].duration, 1000.0 / 3.0, accuracy: 1.0)
    }

    func testNegativeSplitShowsUp() {
        // First km slow, second km fast. The point of splits is seeing this.
        var samples: [(elapsed: TimeInterval, distance: Double)] = []
        var distance = 0.0
        for second in 0...800 {
            distance += second < 400 ? 2.5 : 3.5
            samples.append((TimeInterval(second), distance))
        }
        let splits = RunAnalysis.splits(samples: samples, every: 1000)
        XCTAssertGreaterThan(splits.count, 1)
        XCTAssertLessThan(splits[1].duration, splits[0].duration)
    }

    func testDegenerateInput() {
        XCTAssertTrue(RunAnalysis.splits(samples: [], every: 1000).isEmpty)
        XCTAssertTrue(RunAnalysis.splits(samples: steadyRun(seconds: 10), every: 0).isEmpty)
        // A run shorter than one split yields only the partial.
        let short = RunAnalysis.splits(samples: steadyRun(seconds: 100), every: 1000)
        XCTAssertEqual(short.count, 1)
        XCTAssertTrue(short[0].isPartial)
    }
}

final class ZoneTimeTests: XCTestCase {

    func testTimeIsAttributedToTheRightZones() {
        // 60s at 130 (zone 2), then 60s at 150 (zone 3).
        var samples: [(elapsed: TimeInterval, bpm: Int)] = []
        for second in 0..<60 { samples.append((TimeInterval(second), 130)) }
        for second in 60...120 { samples.append((TimeInterval(second), 150)) }

        let zones = RunAnalysis.timeInZones(samples: samples, zones: testZones)
        let zone2 = zones.first { $0.zone == 2 }?.seconds ?? 0
        let zone3 = zones.first { $0.zone == 3 }?.seconds ?? 0

        XCTAssertEqual(zone2, 60, accuracy: 1.5)
        XCTAssertEqual(zone3, 60, accuracy: 1.5)
    }

    func testSensorDropoutIsNotCreditedToAZone() {
        // Two samples ten minutes apart. Without a gap limit the first would be credited
        // with ten minutes in zone 2 that nobody measured.
        let samples: [(elapsed: TimeInterval, bpm: Int)] = [(0, 130), (600, 130)]
        let zones = RunAnalysis.timeInZones(samples: samples, zones: testZones)
        XCTAssertTrue(zones.isEmpty, "a 10-minute gap is a dropout, not 10 minutes of data")
    }

    func testBelowZoneOneIsReportedAsZoneZero() {
        let samples: [(elapsed: TimeInterval, bpm: Int)] = (0...30).map { (TimeInterval($0), 80) }
        let zones = RunAnalysis.timeInZones(samples: samples, zones: testZones)
        XCTAssertEqual(zones.first?.zone, 0)
    }

    func testUnsortedInputIsHandled() {
        let shuffled: [(elapsed: TimeInterval, bpm: Int)] =
            (0...60).map { (TimeInterval($0), 130) }.shuffled()
        let zones = RunAnalysis.timeInZones(samples: shuffled, zones: testZones)
        XCTAssertEqual(zones.first { $0.zone == 2 }?.seconds ?? 0, 60, accuracy: 1.5)
    }

    func testAverageHeartRateOverAWindow() {
        let samples: [(elapsed: TimeInterval, bpm: Int)] =
            (0...100).map { (TimeInterval($0), 100 + $0) }
        XCTAssertEqual(RunAnalysis.averageHeartRate(samples: samples, from: 0, to: 10), 105)
        XCTAssertNil(RunAnalysis.averageHeartRate(samples: samples, from: 500, to: 600))
    }
}
