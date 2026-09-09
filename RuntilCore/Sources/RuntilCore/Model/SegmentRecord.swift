import Foundation

/// One segment as it actually happened, rather than as the plan described it.
///
/// A plan says "run until the top of Zone 2"; what you want to see afterwards is that this
/// particular run lasted 2:14, covered 380 m, and averaged 147 bpm. Heart-rate and manual
/// plans have no fixed segment lengths at all, so without a record of the real boundaries
/// there is nothing to line the numbers up against.
public struct SegmentRecord: Equatable, Hashable, Sendable, Identifiable {
    public let kind: SegmentKind
    /// Position within the plan's segment list.
    public let index: Int
    /// Which time through the plan this was, counting from zero.
    public let cycle: Int
    public let start: TimeInterval
    public let end: TimeInterval
    public let startDistance: Double
    public let endDistance: Double

    public init(
        kind: SegmentKind,
        index: Int,
        cycle: Int,
        start: TimeInterval,
        end: TimeInterval,
        startDistance: Double,
        endDistance: Double
    ) {
        self.kind = kind
        self.index = index
        self.cycle = cycle
        self.start = start
        self.end = end
        self.startDistance = startDistance
        self.endDistance = endDistance
    }

    public var id: String { "\(cycle)-\(index)-\(start)" }
    public var duration: TimeInterval { max(0, end - start) }
    public var distance: Double { max(0, endDistance - startDistance) }

    /// Where this sits in the run as a whole — the number to show, since a plan repeated
    /// eight times has eight segment 0s and only their order tells them apart.
    public func ordinal(in records: [SegmentRecord]) -> Int {
        (records.firstIndex(of: self) ?? 0) + 1
    }
}
