import Foundation
import CoreHaptics
import UIKit
import Observation
import RuntilCore

/// Renders cues on the phone: audio first, haptics alongside.
///
/// The phone has far richer haptics than the watch — Core Haptics gives real waveform
/// control instead of nine fixed taps. But it stops when the app is suspended
/// (`CHHapticEngineStoppedReasonApplicationSuspended` is documented as exactly that), so
/// haptics are treated as a bonus for when the phone is in your hand, and audio carries
/// the run.
@MainActor
@Observable
final class PhoneCuePlayer {

    private(set) var log: [CueLogEntry] = []
    var hapticsEnabled = true

    private let audio = AudioCuePlayer()
    private var engine: CHHapticEngine?
    private var lastPlayed: Date = .distantPast
    private var lastPriority: Int = .min

    /// Minimum silence between cues, so two never blur together.
    private let minimumGap: TimeInterval = 1.2

    var spokenCuesEnabled: Bool {
        get { audio.spokenCuesEnabled }
        set { audio.spokenCuesEnabled = newValue }
    }

    var tonesEnabled: Bool {
        get { audio.tonesEnabled }
        set { audio.tonesEnabled = newValue }
    }

    func activate() throws {
        try audio.activate()
        startHapticEngine()
    }

    func deactivate() {
        audio.deactivate()
        engine?.stop()
        engine = nil
    }

    /// Bound to the app's audio session rather than its own, which is what gives haptics
    /// any chance of surviving a screen lock. Undocumented territory, so nothing depends
    /// on it working — audio is what actually carries the cue.
    private func startHapticEngine() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            let engine = try CHHapticEngine(audioSession: .sharedInstance())
            engine.playsHapticsOnly = true
            engine.isAutoShutdownEnabled = false
            // The engine stops on backgrounding and on audio interruptions; restart it so
            // haptics resume when the phone comes back to hand.
            engine.stoppedHandler = { _ in
                Task { @MainActor [weak self] in self?.restartHapticEngine() }
            }
            engine.resetHandler = { [weak engine] in try? engine?.start() }
            try engine.start()
            self.engine = engine
        } catch {
            self.engine = nil
        }
    }

    private func restartHapticEngine() {
        try? engine?.start()
    }

    func play(_ cue: Cue, elapsed: TimeInterval, units: DistanceUnit) {
        // Same rule as the watch: a cue arriving on top of a more important one is
        // dropped, never queued, because two cues a second apart can't be told apart.
        let sinceLast = Date().timeIntervalSince(lastPlayed)
        if sinceLast < minimumGap, cue.priority <= lastPriority {
            record(cue, elapsed: elapsed, played: false)
            return
        }

        lastPlayed = Date()
        lastPriority = cue.priority
        record(cue, elapsed: elapsed, played: true)

        audio.play(cue, units: units)
        if hapticsEnabled { vibrate(for: cue) }
    }

    /// Mirrors the watch's rhythm vocabulary — rising for effort, falling for ease,
    /// triples for pace — so the two apps feel like the same thing.
    private func vibrate(for cue: Cue) {
        let beats: [(intensity: Float, sharpness: Float, offset: TimeInterval)]

        switch cue {
        case .beginSegment(let kind, _, _) where kind.isEffort:
            beats = [(1.0, 0.5, 0), (1.0, 0.8, 0.18), (1.0, 1.0, 0.34)]
        case .beginSegment:
            beats = [(1.0, 1.0, 0), (1.0, 0.7, 0.18), (0.9, 0.4, 0.34)]
        case .approachingZoneCeiling:
            beats = [(1.0, 0.9, 0), (1.0, 0.9, 0.3)]
        case .approachingZoneFloor:
            beats = [(0.7, 0.4, 0), (0.7, 0.4, 0.3)]
        case .paceTooFast:
            beats = [(0.8, 0.9, 0), (0.8, 0.6, 0.12), (0.8, 0.3, 0.24)]
        case .paceTooSlow:
            beats = [(0.8, 0.3, 0), (0.8, 0.6, 0.12), (0.8, 0.9, 0.24)]
        case .distanceSplit:
            beats = [(0.9, 0.7, 0), (0.6, 0.5, 0.22)]
        case .segmentEndingSoon:
            beats = [(0.5, 0.6, 0)]
        case .thresholdCrossed:
            beats = [(0.8, 0.7, 0)]
        case .workoutComplete:
            beats = [(1.0, 0.3, 0), (1.0, 0.6, 0.2), (1.0, 1.0, 0.4)]
        }

        let events = beats.map { beat in
            CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: beat.intensity),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: beat.sharpness)
                ],
                relativeTime: beat.offset
            )
        }

        do {
            let pattern = try CHHapticPattern(events: events, parameters: [])
            let player = try engine?.makePlayer(with: pattern)
            try player?.start(atTime: CHHapticTimeImmediate)
        } catch {
            // Core Haptics is a bonus channel; if it fails the audio cue still landed.
        }
    }

    private func record(_ cue: Cue, elapsed: TimeInterval, played: Bool) {
        log.append(CueLogEntry(elapsed: elapsed, summary: cue.summary, played: played))
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    func reset() {
        log.removeAll()
        lastPlayed = .distantPast
        lastPriority = .min
    }
}

struct CueLogEntry: Identifiable, Hashable {
    let id = UUID()
    let elapsed: TimeInterval
    let summary: String
    let played: Bool
}
