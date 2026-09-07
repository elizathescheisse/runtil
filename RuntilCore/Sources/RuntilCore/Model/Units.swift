import Foundation

/// Distance unit used for display, splits, and pace targets.
///
/// Everything inside the engine is metric — meters and seconds. This type exists
/// only at the edges: parsing what the user typed, and formatting what they read.
public enum DistanceUnit: String, Codable, CaseIterable, Sendable {
    case miles
    case kilometers

    public var metersPerUnit: Double {
        switch self {
        case .miles: return 1609.344
        case .kilometers: return 1000
        }
    }

    /// Short suffix for pace, e.g. the "mi" in 9:30 /mi.
    public var abbreviation: String {
        switch self {
        case .miles: return "mi"
        case .kilometers: return "km"
        }
    }

    public func meters(fromUnits value: Double) -> Double { value * metersPerUnit }
    public func units(fromMeters meters: Double) -> Double { meters / metersPerUnit }
}
