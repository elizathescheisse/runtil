import Foundation
import WatchKit
import RuntilCore

/// A haptic phrase: a short sequence of system taps with gaps between them.
///
/// watchOS gives us exactly nine fixed haptics and no way to author custom waveforms —
/// Core Haptics is iOS-only. So the entire vocabulary below is built out of *rhythm*:
/// rising versus falling, doubles versus triples. Those distinctions survive being felt
/// through a sleeve mid-run, which subtle amplitude differences would not.
struct HapticPattern {

    struct Beat {
        let type: WKHapticType
        /// Pause after this beat before the next one.
        let gap: TimeInterval
    }

    let beats: [Beat]
    /// Human-readable rendering, shown in the cue log and used in the simulator where
    /// `WKInterfaceDevice.play` is a silent no-op.
    let describedAs: String

    init(_ beats: [Beat], describedAs: String) {
        self.beats = beats
        self.describedAs = describedAs
    }

    /// Total wall-clock time this phrase occupies.
    var duration: TimeInterval {
        beats.dropLast().reduce(0) { $0 + $1.gap }
    }
}

extension HapticPattern {

    static func pattern(for cue: Cue) -> HapticPattern {
        switch cue {

        // Rising, with a leading .start — "go".
        case .beginSegment(let kind, _, _) where kind.isEffort:
            return HapticPattern([
                Beat(type: .start, gap: 0.25),
                Beat(type: .directionUp, gap: 0.15),
                Beat(type: .directionUp, gap: 0)
            ], describedAs: "start · up · up")

        // Falling, with a leading .stop — "ease off".
        case .beginSegment:
            return HapticPattern([
                Beat(type: .stop, gap: 0.25),
                Beat(type: .directionDown, gap: 0.15),
                Beat(type: .directionDown, gap: 0)
            ], describedAs: "stop · down · down")

        // Two firm taps. Deliberately the most attention-grabbing phrase in the set.
        case .approachingZoneCeiling:
            return HapticPattern([
                Beat(type: .failure, gap: 0.35),
                Beat(type: .failure, gap: 0)
            ], describedAs: "failure ×2")

        case .approachingZoneFloor:
            return HapticPattern([
                Beat(type: .retry, gap: 0.35),
                Beat(type: .retry, gap: 0)
            ], describedAs: "retry ×2")

        case .paceTooFast:
            return HapticPattern([
                Beat(type: .directionDown, gap: 0.12),
                Beat(type: .directionDown, gap: 0.12),
                Beat(type: .directionDown, gap: 0)
            ], describedAs: "down ×3 fast")

        case .paceTooSlow:
            return HapticPattern([
                Beat(type: .directionUp, gap: 0.12),
                Beat(type: .directionUp, gap: 0.12),
                Beat(type: .directionUp, gap: 0)
            ], describedAs: "up ×3 fast")

        // One announcing tap, then a click per unit — so you can count a split without
        // looking. Capped, because past about four you stop counting and start guessing.
        case .distanceSplit(let index, _):
            let clicks = min(index, 4)
            var beats = [Beat(type: .notification, gap: 0.4)]
            beats += (0..<clicks).map { Beat(type: .click, gap: $0 == clicks - 1 ? 0 : 0.22) }
            return HapticPattern(beats, describedAs: "notification · click ×\(clicks)")

        case .segmentEndingSoon:
            return HapticPattern([Beat(type: .click, gap: 0)], describedAs: "click")

        case .thresholdCrossed(_, let rising):
            return HapticPattern([
                Beat(type: rising ? .directionUp : .directionDown, gap: 0.2),
                Beat(type: .notification, gap: 0)
            ], describedAs: rising ? "up · notification" : "down · notification")

        case .workoutComplete:
            return HapticPattern([
                Beat(type: .success, gap: 0.4),
                Beat(type: .success, gap: 0)
            ], describedAs: "success ×2")
        }
    }
}
