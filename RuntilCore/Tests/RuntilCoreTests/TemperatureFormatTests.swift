import XCTest
@testable import RuntilCore

final class TemperatureFormatTests: XCTestCase {

    /// Digits only, so the assertions don't depend on whether a locale puts a space before
    /// the degree sign or which degree glyph it picks.
    private func digits(_ string: String) -> String {
        string.filter { $0.isNumber || $0 == "-" }
    }

    func testTemperatureFollowsTheLocaleRatherThanBeingHardcoded() {
        XCTAssertEqual(digits(Format.temperature(celsius: 21, locale: Locale(identifier: "en_US"))), "70")
        XCTAssertEqual(digits(Format.temperature(celsius: 21, locale: Locale(identifier: "en_GB"))), "21")
        XCTAssertTrue(Format.temperature(celsius: 21, locale: Locale(identifier: "en_US")).contains("F"))
        XCTAssertTrue(Format.temperature(celsius: 21, locale: Locale(identifier: "en_GB")).contains("C"))
    }

    func testAnExplicitTemperaturePreferenceBeatsTheRegionDefault() {
        // iOS exposes this as its own switch under Language & Region, separate from the
        // region itself — so a US runner who has chosen Celsius must get Celsius.
        let usCelsius = Format.temperature(celsius: 21, locale: Locale(identifier: "en_US-u-mu-celsius"))
        XCTAssertEqual(digits(usCelsius), "21")
        XCTAssertTrue(usCelsius.contains("C"))

        let ukFahrenheit = Format.temperature(celsius: 21, locale: Locale(identifier: "en_GB-u-mu-fahrenhe"))
        XCTAssertEqual(digits(ukFahrenheit), "70")
        XCTAssertTrue(ukFahrenheit.contains("F"))
    }

    func testRoundsToWholeDegrees() {
        // A run summary has no use for tenths, and "68.36°F" reads as false precision from
        // a forecast for the nearest weather station.
        XCTAssertEqual(digits(Format.temperature(celsius: 20.2, locale: Locale(identifier: "en_US"))), "68")
        XCTAssertEqual(digits(Format.temperature(celsius: 20.2, locale: Locale(identifier: "en_GB"))), "20")
    }

    func testBelowFreezingKeepsItsSign() {
        let cold = Format.temperature(celsius: -5, locale: Locale(identifier: "en_GB"))
        XCTAssertTrue(cold.contains("-") || cold.contains("−"), "got \(cold)")
        XCTAssertEqual(digits(Format.temperature(celsius: -5, locale: Locale(identifier: "en_US"))), "23")
    }
}
