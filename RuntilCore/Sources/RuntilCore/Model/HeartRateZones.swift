import Foundation

/// Heart rate zone boundaries, expressible three different ways.
///
/// Whichever method you choose, everything downstream consumes plain BPM ranges via
/// `range(forZone:)`. That keeps the engine ignorant of how the numbers were derived and
/// lets the editor show you the resulting BPM live as you switch methods.
public struct HeartRateZones: Codable, Hashable, Sendable {

    public enum Method: Codable, Hashable, Sendable {
        /// Explicit BPM edges you type in. `edges` holds the 6 boundaries that
        /// delimit 5 zones: [z1lo, z2lo, z3lo, z4lo, z5lo, z5hi].
        case direct(edges: [Int])

        /// Classic percentage-of-max model. Zone n spans `percentages[n-1]...percentages[n]`
        /// of max HR. Default breakpoints are 50/60/70/80/90/100.
        case percentMax(maxHR: Int, percentages: [Double] = HeartRateZones.defaultPercentages)

        /// Karvonen / heart rate reserve: resting + (max − resting) × percentage.
        /// More personalized than plain %max because it accounts for your resting HR.
        case karvonen(maxHR: Int, restingHR: Int, percentages: [Double] = HeartRateZones.defaultPercentages)
    }

    public static let defaultPercentages: [Double] = [0.50, 0.60, 0.70, 0.80, 0.90, 1.00]

    public var method: Method

    public init(method: Method) {
        self.method = method
    }

    /// A reasonable starting point for someone who hasn't measured anything:
    /// age-estimated max HR via the Tanaka formula, which fits observed data better
    /// than the older 220−age rule, especially past 40.
    public static func estimated(age: Int) -> HeartRateZones {
        HeartRateZones(method: .percentMax(maxHR: tanakaMaxHR(age: age)))
    }

    /// Tanaka et al. (2001): HRmax = 208 − 0.7 × age.
    public static func tanakaMaxHR(age: Int) -> Int {
        Int((208.0 - 0.7 * Double(age)).rounded())
    }

    /// The 6 BPM edges delimiting the 5 zones, ascending.
    public var edges: [Int] {
        switch method {
        case .direct(let edges):
            return edges

        case .percentMax(let maxHR, let percentages):
            return percentages.map { Int((Double(maxHR) * $0).rounded()) }

        case .karvonen(let maxHR, let restingHR, let percentages):
            let reserve = Double(maxHR - restingHR)
            return percentages.map { Int((Double(restingHR) + reserve * $0).rounded()) }
        }
    }

    /// BPM range for a zone, 1...5. Clamped, so an out-of-range zone returns the
    /// nearest valid one rather than trapping.
    public func range(forZone zone: Int) -> ClosedRange<Int> {
        let e = edges
        guard e.count >= 2 else { return 0...0 }
        let index = min(max(zone, 1), e.count - 1) - 1
        let lower = e[index]
        let upper = e[index + 1]
        return lower...max(lower, upper)
    }

    /// Which zone a given heart rate falls in, or nil if below zone 1 / above zone 5.
    public func zone(for bpm: Int) -> Int? {
        let e = edges
        guard e.count >= 2, bpm >= e.first!, bpm <= e.last! else { return nil }
        for index in 0..<(e.count - 1) where bpm <= e[index + 1] {
            return index + 1
        }
        return e.count - 1
    }
}
