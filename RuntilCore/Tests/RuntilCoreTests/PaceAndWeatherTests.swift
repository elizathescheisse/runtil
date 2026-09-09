import XCTest
@testable import RuntilCore

final class PaceBandTests: XCTestCase {

    func testTargetAndToleranceRoundTripThroughMiles() {
        let band = PaceBand.perUnit(target: 9 * 60 + 30, tolerance: 20, unit: .miles)
        XCTAssertEqual(band.target(in: .miles), 570, accuracy: 0.01)
        XCTAssertEqual(band.tolerance(in: .miles), 20, accuracy: 0.01)
    }

    func testDefaultToleranceIsTwentySecondsPerMile() {
        let band = PaceBand.perUnit(target: 9 * 60, unit: .miles)
        XCTAssertEqual(band.tolerance(in: .miles), 20, accuracy: 0.01)
    }

    func testRangeIsSymmetricAroundTarget() {
        let band = PaceBand.perUnit(target: 600, tolerance: 30, unit: .miles)
        XCTAssertEqual(band.range.lowerBound * DistanceUnit.miles.metersPerUnit, 570, accuracy: 0.01)
        XCTAssertEqual(band.range.upperBound * DistanceUnit.miles.metersPerUnit, 630, accuracy: 0.01)
    }

    func testToleranceConvertsBetweenUnits() {
        // The same 20 seconds is a *tighter* constraint per mile than per kilometre,
        // because a mile is longer — so its per-metre tolerance is smaller.
        let perMile = PaceBand.perUnit(target: 600, tolerance: 20, unit: .miles)
        let perKm = PaceBand.perUnit(target: 600, tolerance: 20, unit: .kilometers)
        XCTAssertLessThan(perMile.toleranceSecondsPerMeter, perKm.toleranceSecondsPerMeter)
    }

    func testRangeNeverGoesNegative() {
        let band = PaceBand(targetSecondsPerMeter: 0.01, toleranceSecondsPerMeter: 5)
        XCTAssertGreaterThanOrEqual(band.range.lowerBound, 0)
    }
}

final class PaceCalibrationTests: XCTestCase {

    private let target = PaceBand.perUnit(target: 9 * 60, tolerance: 20, unit: .miles)

    /// Pace samples in seconds per metre, expressed in seconds per mile for readability.
    private func samples(perMile: [Double]) -> [Double] {
        perMile.map { $0 / DistanceUnit.miles.metersPerUnit }
    }

    func testSuggestsAWiderBandWhenTheRunWasConsistentlyOutside() {
        // Ran 8:30–9:40 against a ±20s band. Needs about ±40s.
        let observed = samples(perMile: stride(from: 510.0, through: 580.0, by: 1.0).map { $0 })
        let suggestion = PaceCalibration.suggest(observed: observed, band: target, cueCount: 14)

        XCTAssertNotNil(suggestion)
        guard let suggestion else { return }
        XCTAssertTrue(suggestion.isWorthOffering)
        XCTAssertGreaterThan(suggestion.suggestedTolerance, suggestion.currentTolerance)
        let suggestedPerMile = suggestion.suggestedTolerance * DistanceUnit.miles.metersPerUnit
        XCTAssertEqual(suggestedPerMile, 37, accuracy: 8)
    }

    func testDoesNotOfferWhenTheBandWasAlreadyFine() {
        // Held 8:55–9:05 against a ±20s band, with barely any cues.
        let observed = samples(perMile: stride(from: 535.0, through: 545.0, by: 0.5).map { $0 })
        let suggestion = PaceCalibration.suggest(observed: observed, band: target, cueCount: 1)

        XCTAssertNotNil(suggestion)
        XCTAssertFalse(suggestion?.isWorthOffering ?? true, "a band that worked shouldn't be widened")
    }

    func testOneTrafficLightDoesNotStretchTheBand() {
        // A steady run plus a handful of near-stationary samples. Using min/max would
        // widen the band to minutes; percentiles must ignore the stop.
        var observed = samples(perMile: Array(repeating: 540.0, count: 200))
        observed += samples(perMile: Array(repeating: 1800.0, count: 5))

        let suggestion = PaceCalibration.suggest(observed: observed, band: target, cueCount: 6)
        guard let suggestion else { return XCTFail("expected a suggestion") }

        let suggestedPerMile = suggestion.suggestedTolerance * DistanceUnit.miles.metersPerUnit
        XCTAssertLessThan(suggestedPerMile, 120, "a stop must not define the band")
    }

    func testNeedsEnoughDataToBeWorthTrusting() {
        let observed = samples(perMile: [540, 545, 550])
        XCTAssertNil(PaceCalibration.suggest(observed: observed, band: target, cueCount: 2))
    }

    func testFewCuesMeansNoNagEvenIfWider() {
        // The band was technically tight, but it only fired twice — not worth a prompt.
        let observed = samples(perMile: stride(from: 500.0, through: 600.0, by: 1.0).map { $0 })
        let suggestion = PaceCalibration.suggest(observed: observed, band: target, cueCount: 2)
        XCTAssertFalse(suggestion?.isWorthOffering ?? true)
    }

    func testPercentileInterpolates() {
        let values = [0.0, 10.0]
        XCTAssertEqual(PaceCalibration.percentile(values, 0.5), 5, accuracy: 0.001)
        XCTAssertEqual(PaceCalibration.percentile(values, 0.0), 0, accuracy: 0.001)
        XCTAssertEqual(PaceCalibration.percentile(values, 1.0), 10, accuracy: 0.001)
    }
}

final class WeatherTests: XCTestCase {

    func testParsesOpenMeteoResponse() throws {
        let json = """
        {"latitude":51.5,"longitude":-0.12,
         "current":{"time":"2026-09-08T11:00","temperature_2m":18.4,"relative_humidity_2m":62}}
        """.data(using: .utf8)!

        let weather = try WeatherLookup.parse(json)
        XCTAssertEqual(weather.temperatureCelsius, 18.4, accuracy: 0.01)
        // HealthKit wants a fraction, the API reports whole percent.
        XCTAssertEqual(weather.relativeHumidity, 0.62, accuracy: 0.001)
    }

    func testHumidityIsClampedToAFraction() throws {
        let json = """
        {"current":{"temperature_2m":10,"relative_humidity_2m":140}}
        """.data(using: .utf8)!
        XCTAssertEqual(try WeatherLookup.parse(json).relativeHumidity, 1.0, accuracy: 0.001)
    }

    func testFahrenheitConversion() {
        XCTAssertEqual(WeatherSnapshot(temperatureCelsius: 0, relativeHumidity: 0.5).temperatureFahrenheit, 32, accuracy: 0.01)
        XCTAssertEqual(WeatherSnapshot(temperatureCelsius: 20, relativeHumidity: 0.5).temperatureFahrenheit, 68, accuracy: 0.01)
    }

    func testMalformedResponseThrows() {
        XCTAssertThrowsError(try WeatherLookup.parse(Data("not json".utf8)))
        XCTAssertThrowsError(try WeatherLookup.parse(Data("{}".utf8)))
    }

    func testParsesDewPointWhenPresent() throws {
        let json = """
        {"current":{"temperature_2m":24.0,"relative_humidity_2m":70,"dew_point_2m":18.1}}
        """.data(using: .utf8)!
        XCTAssertEqual(try WeatherLookup.parse(json).dewPointCelsius ?? 0, 18.1, accuracy: 0.01)
    }

    func testFallsBackToDerivedDewPointForOlderRuns() throws {
        // A response — or a saved run — without dew point still yields one.
        let json = """
        {"current":{"temperature_2m":24.0,"relative_humidity_2m":70}}
        """.data(using: .utf8)!
        let weather = try WeatherLookup.parse(json)
        XCTAssertNil(weather.dewPointCelsius)
        // 24°C at 70% RH is about 18°C dew point.
        XCTAssertEqual(weather.effectiveDewPointCelsius, 18.1, accuracy: 0.6)
    }
}

final class RunningComfortTests: XCTestCase {

    /// The distinction that motivates using dew point at all.
    func testHotAndDryIsEasierThanCoolerAndMuggy() {
        // 32°C desert air at 20% humidity — hot, but the sweat evaporates.
        let hotDry = WeatherSnapshot(temperatureCelsius: 32, relativeHumidity: 0.20)
        // 26°C at 85% — six degrees cooler and considerably worse to run in.
        let warmMuggy = WeatherSnapshot(temperatureCelsius: 26, relativeHumidity: 0.85)

        XCTAssertLessThan(hotDry.effectiveDewPointCelsius, warmMuggy.effectiveDewPointCelsius)
        XCTAssertLessThan(
            RunningComfort.allCases.firstIndex(of: hotDry.comfort)!,
            RunningComfort.allCases.firstIndex(of: warmMuggy.comfort)!,
            "the cooler, muggier day should grade as harder"
        )
    }

    func testRelativeHumidityAloneWouldGetItBackwards() {
        // Both 90% relative humidity. One is a crisp winter morning, the other a swamp —
        // which is exactly why relative humidity is the wrong number to grade on.
        let coldDamp = WeatherSnapshot(temperatureCelsius: 5, relativeHumidity: 0.90)
        let warmDamp = WeatherSnapshot(temperatureCelsius: 25, relativeHumidity: 0.90)

        XCTAssertEqual(coldDamp.relativeHumidity, warmDamp.relativeHumidity)
        XCTAssertEqual(coldDamp.comfort, .ideal)
        // 25°C at 90% is a ~23°C dew point — several bands worse, on an identical
        // humidity reading. That gap is the whole argument for grading on dew point.
        XCTAssertEqual(warmDamp.comfort, .difficult)
        XCTAssertGreaterThan(
            warmDamp.effectiveDewPointCelsius - coldDamp.effectiveDewPointCelsius,
            15
        )
    }

    func testKnownDewPointValues() {
        // Reference points: at 100% humidity dew point equals air temperature.
        XCTAssertEqual(
            WeatherSnapshot.dewPoint(temperatureCelsius: 20, relativeHumidity: 1.0),
            20, accuracy: 0.2
        )
        // 20°C at 50% is about 9.3°C.
        XCTAssertEqual(
            WeatherSnapshot.dewPoint(temperatureCelsius: 20, relativeHumidity: 0.50),
            9.3, accuracy: 0.5
        )
        // 30°C at 60% is about 21.4°C.
        XCTAssertEqual(
            WeatherSnapshot.dewPoint(temperatureCelsius: 30, relativeHumidity: 0.60),
            21.4, accuracy: 0.5
        )
    }

    func testBandBoundaries() {
        XCTAssertEqual(RunningComfort(dewPointCelsius: 5), .ideal)
        XCTAssertEqual(RunningComfort(dewPointCelsius: 12), .comfortable)
        XCTAssertEqual(RunningComfort(dewPointCelsius: 16), .noticeable)
        XCTAssertEqual(RunningComfort(dewPointCelsius: 19), .uncomfortable)
        XCTAssertEqual(RunningComfort(dewPointCelsius: 22), .difficult)
        XCTAssertEqual(RunningComfort(dewPointCelsius: 26), .oppressive)
    }

    func testZeroHumidityDoesNotProduceInfinity() {
        // log(0) is undefined; the guard must keep this finite.
        let value = WeatherSnapshot.dewPoint(temperatureCelsius: 20, relativeHumidity: 0)
        XCTAssertTrue(value.isFinite)
    }
}
