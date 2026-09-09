import Foundation
import WatchKit
import Observation
import RuntilCore

/// One entry in the on-screen cue log.
struct CueLogEntry: Identifiable, Hashable {
    let id = UUID()
    let elapsed: TimeInterval
    let summary: String
    let haptic: String
    let played: Bool
}

/// Plays haptic phrases one at a time, resolving collisions by priority.
///
/// Two phrases back to back are indistinguishable on the wrist, and watchOS coalesces
/// rapid `play(_:)` calls anyway — so a cue arriving during another one is *dropped* rather
/// than queued, unless it outranks what's playing, in which case it preempts. Queueing
/// would deliver a burst of taps whose meaning you couldn't decode.
@MainActor
@Observable
final class HapticPlayer {

    /// Everything the engine emitted, whether or not it reached the wrist. In the
    /// simulator `WKInterfaceDevice.play` does nothing, so this log *is* the output —
    /// it's how the full state machine gets verified without going for a run.
    private(set) var log: [CueLogEntry] = []

    /// Set false to run silently (previews, or a user who wants the screen only).
    var hapticsEnabled = true

    /// Silences pace nudges for the rest of the run, without touching segment changes.
    ///
    /// The mid-run escape hatch for a band that turns out too tight. Deliberately a mute
    /// and not an editor: at mile three you know the cues are wrong but not what number
    /// would be right, and that decision is better made afterwards from the summary.
    /// Muted cues are still logged, so the summary can still say how often it fired.
    var paceCuesMuted = false

    private var currentTask: Task<Void, Never>?
    private var currentPriority: Int = .min
    private var lastFinished: Date = .distantPast

    /// Minimum silence between phrases, so two cues never blur into one.
    private let minimumGap: TimeInterval = 1.2

    func play(_ cue: Cue, elapsed: TimeInterval) {
        let pattern = HapticPattern.pattern(for: cue)

        if paceCuesMuted, cue.isPaceCue {
            record(cue, pattern: pattern, elapsed: elapsed, played: false)
            return
        }

        // A repeated segment cue is the point, not noise — it fires seconds apart and
        // must never be mistaken for a collision and dropped.
        let isSegmentCue: Bool = { if case .beginSegment = cue { return true }; return false }()

        // Something higher-priority is mid-phrase: drop this one entirely.
        if currentTask != nil, !isSegmentCue, cue.priority <= currentPriority {
            record(cue, pattern: pattern, elapsed: elapsed, played: false)
            return
        }

        // Too soon after the last phrase, and not important enough to crowd it.
        let sinceLast = Date().timeIntervalSince(lastFinished)
        if currentTask == nil, sinceLast < minimumGap, cue.priority < Cue.beginSegment(kind: .run, index: 0, cycle: 0).priority {
            record(cue, pattern: pattern, elapsed: elapsed, played: false)
            return
        }

        currentTask?.cancel()
        currentPriority = cue.priority
        record(cue, pattern: pattern, elapsed: elapsed, played: true)

        currentTask = Task { [weak self] in
            await self?.run(pattern)
            guard let self, !Task.isCancelled else { return }
            self.lastFinished = Date()
            self.currentPriority = .min
            self.currentTask = nil
        }
    }

    private func run(_ pattern: HapticPattern) async {
        let device = WKInterfaceDevice.current()
        for beat in pattern.beats {
            guard !Task.isCancelled else { return }
            if hapticsEnabled { device.play(beat.type) }
            if beat.gap > 0 {
                try? await Task.sleep(for: .seconds(beat.gap))
            }
        }
    }

    private func record(_ cue: Cue, pattern: HapticPattern, elapsed: TimeInterval, played: Bool) {
        log.append(
            CueLogEntry(
                elapsed: elapsed,
                summary: cue.summary,
                haptic: pattern.describedAs,
                played: played
            )
        )
        // Keep the log bounded; a long run would otherwise grow without limit.
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    func reset() {
        currentTask?.cancel()
        currentTask = nil
        currentPriority = .min
        log.removeAll()
    }

    /// Lets the settings screen preview a phrase so you can learn the vocabulary indoors.
    func preview(_ cue: Cue) {
        currentTask?.cancel()
        currentTask = nil
        currentPriority = .min
        play(cue, elapsed: 0)
    }
}
