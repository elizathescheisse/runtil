import Foundation

/// Conditions at the start of a run, recorded onto the workout.
///
/// Worth having because it explains runs that felt wrong: heart rate for a given pace
/// climbs sharply in heat and humidity, so a Zone 2 run on a muggy day is genuinely
/// slower and it isn't a loss of fitness.
public struct WeatherSnapshot: Codable, Hashable, Sendable {
    public var temperatureCelsius: Double
    /// 0...1, matching the unit HealthKit expects for workout humidity metadata.
    public var relativeHumidity: Double
    /// Absolute moisture in the air. Optional because older saved runs predate it, and
    /// because it can be recovered from the other two — see `effectiveDewPointCelsius`.
    public var dewPointCelsius: Double?

    public init(
        temperatureCelsius: Double,
        relativeHumidity: Double,
        dewPointCelsius: Double? = nil
    ) {
        self.temperatureCelsius = temperatureCelsius
        self.relativeHumidity = relativeHumidity
        self.dewPointCelsius = dewPointCelsius
    }

    public var temperatureFahrenheit: Double {
        temperatureCelsius * 9 / 5 + 32
    }

    /// Measured dew point when it's there, derived when it isn't — so runs saved before
    /// this existed still get a reading.
    public var effectiveDewPointCelsius: Double {
        dewPointCelsius ?? Self.dewPoint(
            temperatureCelsius: temperatureCelsius,
            relativeHumidity: relativeHumidity
        )
    }

    /// Magnus-Tetens approximation. Accurate to a few tenths of a degree over the range
    /// anyone actually runs in.
    public static func dewPoint(temperatureCelsius t: Double, relativeHumidity rh: Double) -> Double {
        let b = 17.62, c = 243.12
        let humidity = min(max(rh, 0.001), 1.0)   // ln(0) is undefined
        let gamma = log(humidity) + (b * t) / (c + t)
        return (c * gamma) / (b - gamma)
    }

    public var comfort: RunningComfort {
        RunningComfort(dewPointCelsius: effectiveDewPointCelsius)
    }
}

/// How hard the air itself makes a run.
///
/// Graded on dew point rather than relative humidity, because relative humidity is a
/// fraction of what the air *could* hold at that temperature — 90% at 5°C is bone dry,
/// 90% at 25°C is a swamp. Dew point is absolute moisture, so it compares across days.
///
/// It's also the number that predicts a slowdown: above roughly 15°C dew point, sweat
/// evaporates poorly, so you shed heat by pushing blood to the skin instead of the muscles
/// and your heart rate climbs at the same pace. Which is precisely why a Zone 2 run gets
/// slower in muggy weather without anything being wrong with your fitness.
///
/// Bands follow the thresholds distance runners have used for decades.
public enum RunningComfort: String, Codable, Sendable, CaseIterable {
    case ideal
    case comfortable
    case noticeable
    case uncomfortable
    case difficult
    case oppressive

    public init(dewPointCelsius: Double) {
        switch dewPointCelsius {
        case ..<10: self = .ideal
        case ..<15.5: self = .comfortable
        case ..<18: self = .noticeable
        case ..<21: self = .uncomfortable
        case ..<24: self = .difficult
        default: self = .oppressive
        }
    }

    public var label: String {
        switch self {
        case .ideal: return "Ideal"
        case .comfortable: return "Comfortable"
        case .noticeable: return "Slightly humid"
        case .uncomfortable: return "Humid"
        case .difficult: return "Very humid"
        case .oppressive: return "Oppressive"
        }
    }

    /// What to expect, in terms of the thing the runner will actually notice.
    public var effect: String {
        switch self {
        case .ideal: return "Air won't hold you back."
        case .comfortable: return "Barely noticeable."
        case .noticeable: return "Slightly harder than it looks."
        case .uncomfortable: return "Expect a higher heart rate for the same pace."
        case .difficult: return "Pace will drop at the same effort. Ease off."
        case .oppressive: return "Hard to shed heat. Slow down and drink more."
        }
    }
}

/// Fetches current conditions from Open-Meteo.
///
/// Open-Meteo rather than WeatherKit: WeatherKit's entitlement requires a paid developer
/// membership, and this needs to work on a free personal team. It's also keyless, so
/// there's no secret to leak in a public repo.
public enum WeatherLookup {

    public enum LookupError: Error {
        case badResponse
    }

    public static func current(latitude: Double, longitude: Double) async throws -> WeatherSnapshot {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,relative_humidity_2m,dew_point_2m")
        ]
        guard let url = components.url else { throw LookupError.badResponse }

        var request = URLRequest(url: url)
        // A run shouldn't wait on the weather. If it's slow, we go without.
        request.timeoutInterval = 8

        let (data, _) = try await URLSession.shared.data(for: request)
        return try parse(data)
    }

    /// Split out from the network call so the decoding is testable without a connection.
    public static func parse(_ data: Data) throws -> WeatherSnapshot {
        struct Response: Decodable {
            struct Current: Decodable {
                let temperature_2m: Double
                let relative_humidity_2m: Double
                // Optional so a response missing it still parses; the Magnus fallback
                // covers the gap.
                let dew_point_2m: Double?
            }
            let current: Current
        }

        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw LookupError.badResponse
        }
        return WeatherSnapshot(
            temperatureCelsius: decoded.current.temperature_2m,
            // The API reports whole percent; HealthKit wants a fraction.
            relativeHumidity: max(0, min(1, decoded.current.relative_humidity_2m / 100)),
            dewPointCelsius: decoded.current.dew_point_2m
        )
    }
}
