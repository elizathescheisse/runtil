import Foundation

/// Display formatting. Kept here so the watch and phone render identical strings.
public enum Format {

    /// "9:07" / "1:04:22"
    public static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded())
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    /// "90s" / "1:30" — compact enough for a plan name.
    public static func compactDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        return total % 60 == 0 ? "\(total / 60)m" : String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Seconds-per-meter rendered as pace, e.g. "9:30 /mi".
    public static func pace(secondsPerMeter: Double?, unit: DistanceUnit) -> String {
        guard let secondsPerMeter, secondsPerMeter.isFinite, secondsPerMeter > 0 else {
            return "--:-- /\(unit.abbreviation)"
        }
        let perUnit = secondsPerMeter * unit.metersPerUnit
        // Above ~30 min/mi the reading is noise, not a pace worth showing.
        guard perUnit < 1800 else { return "--:-- /\(unit.abbreviation)" }
        return "\(duration(perUnit)) /\(unit.abbreviation)"
    }

    /// "1.25 mi"
    public static func distance(meters: Double, unit: DistanceUnit, decimals: Int = 2) -> String {
        let value = unit.units(fromMeters: meters)
        return String(format: "%.\(decimals)f %@", value, unit.abbreviation)
    }

    /// Drops a pointless trailing ".0" so plan names read "1/0.25 mi", not "1.0/0.25 mi".
    public static func trimmed(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%g", value)
    }
}
