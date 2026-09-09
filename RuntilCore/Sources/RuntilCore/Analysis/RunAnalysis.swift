import Foundation

/// Post-run maths: elevation gain, splits, and time spent in each heart rate zone.
///
/// Pure functions over plain arrays, deliberately knowing nothing about HealthKit. The
/// awkward parts here — GPS altitude noise, interpolating a split boundary that falls
/// between two samples — are exactly the things you cannot check by looking at a chart
/// and squinting, so they live where they can be tested.
public enum RunAnalysis {

    // MARK: - Elevation

    /// Total metres climbed.
    ///
    /// Two filters, and both are needed. Raw altitude wanders by a metre or two even
    /// standing still, so naively summing positive deltas turns a flat run into a mountain.
    /// A threshold alone doesn't save you either: noise of ±1.5 m swings 3 m peak to peak
    /// and sails straight past a 2 m threshold. So the series is smoothed first, which
    /// collapses that alternation to near-flat, and only then thresholded.
    ///
    /// Smoothing rounds off genuine peaks slightly, so a sharp summit reads a metre or two
    /// low. That's the right trade: under-reporting a real hill by 2 m is a far smaller lie
    /// than inventing 27 m on the flat.
    ///
    /// - Parameters:
    ///   - threshold: metres of change before a move counts. 2 m suits Apple Watch's
    ///     barometric altimeter; phone-only GPS altitude is coarser and wants more.
    ///   - smoothingRadius: samples either side to average. At 1 Hz, 2 is about 5 seconds —
    ///     enough to kill sensor noise, short enough to keep real terrain.
    public static func elevationGain(
        altitudes: [Double],
        threshold: Double = 2.0,
        smoothingRadius: Int = 2
    ) -> Double {
        guard altitudes.count > 1 else { return 0 }

        let smoothed = movingAverage(altitudes, radius: smoothingRadius)

        // Hysteresis: track the running extreme and only bank a climb once a descent of
        // `threshold` confirms the peak was real. Banking each rise as it crosses the
        // threshold instead would discard the leftover below it — losing up to a
        // threshold's worth of genuine climb on every hill.
        var gain = 0.0
        var lastExtreme = smoothed[0]
        var candidate = smoothed[0]
        var rising = true

        for altitude in smoothed.dropFirst() {
            if rising {
                if altitude >= candidate {
                    candidate = altitude
                } else if candidate - altitude >= threshold {
                    gain += max(0, candidate - lastExtreme)
                    lastExtreme = candidate
                    candidate = altitude
                    rising = false
                }
            } else {
                if altitude <= candidate {
                    candidate = altitude
                } else if altitude - candidate >= threshold {
                    lastExtreme = candidate
                    candidate = altitude
                    rising = true
                }
            }
        }

        // A run that ends mid-climb still climbed.
        if rising, candidate > lastExtreme { gain += candidate - lastExtreme }
        return gain
    }

    /// Centred moving average.
    ///
    /// The window must stay *symmetric*, shrinking to whatever fits on the narrower side —
    /// clipping only the overhanging end averages a point with its successors alone, which
    /// drags the first reading up a climb and the last one down, quietly losing real
    /// elevation at both ends. A symmetric window leaves a straight line untouched.
    static func movingAverage(_ values: [Double], radius: Int) -> [Double] {
        guard radius > 0, values.count > 2 * radius else { return values }
        let lastIndex = values.count - 1
        return values.indices.map { index in
            let usable = min(radius, index, lastIndex - index)
            guard usable > 0 else { return values[index] }
            let span = (index - usable)...(index + usable)
            return values[span].reduce(0, +) / Double(span.count)
        }
    }

    // MARK: - Splits

    public struct Split: Equatable, Sendable, Identifiable {
        /// 1 for the first split, 2 for the second, and so on.
        public let index: Int
        /// Distance covered by this split. Equal to the split length except the final
        /// partial one, which is kept so a 5.3-mile run doesn't silently lose 0.3 miles.
        public let distanceMeters: Double
        public let duration: TimeInterval
        public let isPartial: Bool
        public var averageHeartRate: Int?

        public var id: Int { index }

        /// Seconds per metre, comparable with `Tick.instantPace` and `Format.pace`.
        public var secondsPerMeter: Double {
            distanceMeters > 0 ? duration / distanceMeters : 0
        }
    }

    /// Cuts a run into splits of `every` metres.
    ///
    /// - Parameter samples: cumulative distance over time, ascending by elapsed.
    public static func splits(
        samples: [(elapsed: TimeInterval, distance: Double)],
        every: Double
    ) -> [Split] {
        guard every > 0, samples.count > 1 else { return [] }
        let sorted = samples.sorted { $0.elapsed < $1.elapsed }
        guard let total = sorted.last?.distance, total > 0 else { return [] }

        var result: [Split] = []
        var previousBoundaryTime = sorted.first?.elapsed ?? 0
        var index = 1

        while Double(index) * every <= total {
            let boundary = Double(index) * every
            let time = elapsed(atDistance: boundary, in: sorted)
            result.append(
                Split(
                    index: index,
                    distanceMeters: every,
                    duration: time - previousBoundaryTime,
                    isPartial: false
                )
            )
            previousBoundaryTime = time
            index += 1
        }

        // Whatever's left over. Reported separately so its slower pace — it's shorter, not
        // slower — can be shown as partial rather than compared like a full split.
        let covered = Double(index - 1) * every
        let remainder = total - covered
        if remainder > every * 0.05, let last = sorted.last {
            result.append(
                Split(
                    index: index,
                    distanceMeters: remainder,
                    duration: last.elapsed - previousBoundaryTime,
                    isPartial: true
                )
            )
        }
        return result
    }

    /// Linear interpolation between the two samples bracketing a distance, so a split
    /// boundary landing between GPS fixes doesn't get rounded to whichever is nearer.
    ///
    /// `previous` has to advance on every sample, not only on the ones past the target.
    /// Filtering the loop leaves it pinned to the first sample, which interpolates from
    /// the start of the whole run instead of from the boundary's neighbour — right by
    /// coincidence at constant pace, and increasingly wrong the more the pace varied.
    static func elapsed(
        atDistance target: Double,
        in samples: [(elapsed: TimeInterval, distance: Double)]
    ) -> TimeInterval {
        guard var previous = samples.first else { return 0 }

        for sample in samples {
            if sample.distance >= target {
                let span = sample.distance - previous.distance
                guard span > 0 else { return sample.elapsed }
                let fraction = (target - previous.distance) / span
                return previous.elapsed + (sample.elapsed - previous.elapsed) * fraction
            }
            previous = sample
        }
        return samples.last?.elapsed ?? 0
    }

    // MARK: - Segments

    /// One finished segment with the numbers filled in.
    public struct SegmentSummary: Equatable, Sendable, Identifiable {
        /// Position in the run, counting from one. A plan repeated eight times has eight
        /// segment 0s, and only the order tells them apart.
        public let ordinal: Int
        public let kind: SegmentKind
        public let start: TimeInterval
        public let duration: TimeInterval
        public let distanceMeters: Double
        public let averageHeartRate: Int?
        public let maxHeartRate: Int?

        public var id: Int { ordinal }

        /// Seconds per metre, comparable with `Tick.instantPace` and `Format.pace`.
        ///
        /// Nil rather than zero when the segment covered no ground: a walk recorded
        /// indoors has no pace, and showing 0:00/mi would read as impossibly fast.
        public var secondsPerMeter: Double? {
            guard distanceMeters > 1, duration > 0 else { return nil }
            return duration / distanceMeters
        }
    }

    /// Fills in distance and heart rate for segment boundaries recorded during the run.
    ///
    /// Boundaries are all that gets saved; everything else is derived here from the samples
    /// HealthKit already holds. That keeps what's written during a run tiny, and means a
    /// run recorded before this existed gains nothing but loses nothing either.
    ///
    /// - Parameters:
    ///   - segments: start/end elapsed times, in order.
    ///   - heartRate: bpm over elapsed time.
    ///   - distances: cumulative metres over elapsed time.
    public static func segmentBreakdown(
        segments: [(kind: SegmentKind, start: TimeInterval, end: TimeInterval)],
        heartRate: [(elapsed: TimeInterval, bpm: Int)],
        distances: [(elapsed: TimeInterval, distance: Double)]
    ) -> [SegmentSummary] {
        let sortedDistances = distances.sorted { $0.elapsed < $1.elapsed }

        return segments.enumerated().map { position, segment in
            // Half-open, so a reading landing exactly on a boundary belongs to the segment
            // starting there and not to both. The last segment takes its closing sample,
            // which otherwise falls off the end of the run entirely.
            let isLast = position == segments.count - 1
            let within = heartRate.filter {
                $0.elapsed >= segment.start && (isLast ? $0.elapsed <= segment.end : $0.elapsed < segment.end)
            }
            let beats = within.map(\.bpm)

            let covered: Double
            if sortedDistances.count > 1 {
                covered = max(
                    0,
                    distance(atElapsed: segment.end, in: sortedDistances)
                        - distance(atElapsed: segment.start, in: sortedDistances)
                )
            } else {
                covered = 0
            }

            return SegmentSummary(
                ordinal: position + 1,
                kind: segment.kind,
                start: segment.start,
                duration: max(0, segment.end - segment.start),
                distanceMeters: covered,
                averageHeartRate: beats.isEmpty ? nil : Int((Double(beats.reduce(0, +)) / Double(beats.count)).rounded()),
                maxHeartRate: beats.max()
            )
        }
    }

    /// Cumulative distance at a moment, interpolated between the fixes either side.
    ///
    /// The mirror of `elapsed(atDistance:)`. A segment boundary lands wherever your heart
    /// rate or the clock put it, which is almost never exactly on a GPS fix — rounding to
    /// the nearer one would hand a second or two of distance to whichever segment happened
    /// to be adjacent.
    static func distance(
        atElapsed target: TimeInterval,
        in samples: [(elapsed: TimeInterval, distance: Double)]
    ) -> Double {
        guard var previous = samples.first else { return 0 }
        if target <= previous.elapsed { return previous.distance }

        for sample in samples {
            if sample.elapsed >= target {
                let span = sample.elapsed - previous.elapsed
                guard span > 0 else { return sample.distance }
                let fraction = (target - previous.elapsed) / span
                return previous.distance + (sample.distance - previous.distance) * fraction
            }
            previous = sample
        }
        return samples.last?.distance ?? 0
    }

    // MARK: - Heart rate zones

    public struct ZoneTime: Equatable, Sendable, Identifiable {
        /// 1–5, or 0 for readings below zone 1.
        public let zone: Int
        public let seconds: TimeInterval
        public var id: Int { zone }
    }

    /// How long was spent in each zone.
    ///
    /// Each sample owns the time until the next one, which is the only honest reading of a
    /// sampled signal — the watch tells you your heart rate *now*, not for a span.
    ///
    /// - Parameter maxGap: samples further apart than this are treated as a dropout and
    ///   contribute nothing, so a lost sensor doesn't silently credit ten minutes to
    ///   whatever zone you happened to be in when it cut out.
    public static func timeInZones(
        samples: [(elapsed: TimeInterval, bpm: Int)],
        zones: HeartRateZones,
        maxGap: TimeInterval = 30
    ) -> [ZoneTime] {
        guard samples.count > 1 else { return [] }
        let sorted = samples.sorted { $0.elapsed < $1.elapsed }

        var totals: [Int: TimeInterval] = [:]
        for (sample, next) in zip(sorted, sorted.dropFirst()) {
            let span = next.elapsed - sample.elapsed
            guard span > 0, span <= maxGap else { continue }
            let zone = zones.zone(for: sample.bpm) ?? 0
            totals[zone, default: 0] += span
        }

        return totals
            .map { ZoneTime(zone: $0.key, seconds: $0.value) }
            .sorted { $0.zone < $1.zone }
    }

    /// Average heart rate over a time window, for labelling a split.
    public static func averageHeartRate(
        samples: [(elapsed: TimeInterval, bpm: Int)],
        from start: TimeInterval,
        to end: TimeInterval
    ) -> Int? {
        let window = samples.filter { $0.elapsed >= start && $0.elapsed <= end }
        guard !window.isEmpty else { return nil }
        return Int((Double(window.map(\.bpm).reduce(0, +)) / Double(window.count)).rounded())
    }
}
