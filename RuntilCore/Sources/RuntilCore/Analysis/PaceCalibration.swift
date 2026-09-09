import Foundation

/// Works out, after the fact, whether a pace band was set too tight.
///
/// Same idea as heart-rate lag calibration: the decision needs a number, and the only
/// place that number honestly exists is in the run you just did. Deciding mid-stride at
/// 160 bpm is guessing; deciding afterwards with the spread in front of you isn't.
public enum PaceCalibration {

    public struct Suggestion: Equatable, Sendable {
        /// How often the band was breached.
        public let cueCount: Int
        /// The pace actually held, seconds per metre, with outliers trimmed.
        public let observedRange: ClosedRange<Double>
        /// Tolerance that would have covered `coverage` of the run, seconds per metre.
        public let suggestedTolerance: Double
        public let currentTolerance: Double

        /// Only worth interrupting someone for if it's meaningfully wider and the cues
        /// were actually a nuisance.
        public var isWorthOffering: Bool {
            cueCount >= 4 && suggestedTolerance > currentTolerance * 1.25
        }
    }

    /// - Parameters:
    ///   - observed: rolling pace samples during segments the band applied to, s/m.
    ///   - coverage: fraction of the run the suggested band should contain. 0.9 leaves the
    ///     genuinely off-pace tenth still cueing — the point is to stop nagging, not to
    ///     widen the band until it can never fire.
    public static func suggest(
        observed: [Double],
        band: PaceBand,
        cueCount: Int,
        coverage: Double = 0.9
    ) -> Suggestion? {
        let usable = observed.filter { $0.isFinite && $0 > 0 }
        guard usable.count >= 20 else { return nil }

        // Percentiles rather than min/max: one stop at a traffic light would otherwise
        // stretch the band wide enough to be useless.
        let sorted = usable.sorted()
        let tail = (1 - coverage) / 2
        let low = percentile(sorted, tail)
        let high = percentile(sorted, 1 - tail)

        // Distance from the target that covers the run, taken from the wider side so the
        // band is symmetric around the pace actually being aimed at.
        let needed = max(
            abs(high - band.targetSecondsPerMeter),
            abs(band.targetSecondsPerMeter - low)
        )

        return Suggestion(
            cueCount: cueCount,
            observedRange: low...high,
            suggestedTolerance: needed,
            currentTolerance: band.toleranceSecondsPerMeter
        )
    }

    static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        guard sorted.count > 1 else { return sorted[0] }
        let position = fraction * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let weight = position - Double(lower)
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }
}
