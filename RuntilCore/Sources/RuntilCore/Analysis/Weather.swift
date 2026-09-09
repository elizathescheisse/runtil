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

    public init(temperatureCelsius: Double, relativeHumidity: Double) {
        self.temperatureCelsius = temperatureCelsius
        self.relativeHumidity = relativeHumidity
    }

    public var temperatureFahrenheit: Double {
        temperatureCelsius * 9 / 5 + 32
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
            URLQueryItem(name: "current", value: "temperature_2m,relative_humidity_2m")
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
            }
            let current: Current
        }

        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw LookupError.badResponse
        }
        return WeatherSnapshot(
            temperatureCelsius: decoded.current.temperature_2m,
            // The API reports whole percent; HealthKit wants a fraction.
            relativeHumidity: max(0, min(1, decoded.current.relative_humidity_2m / 100))
        )
    }
}
