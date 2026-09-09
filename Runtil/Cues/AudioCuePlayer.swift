import Foundation
import AVFoundation
import RuntilCore

/// Speaks and chimes cues through whatever you're listening on.
///
/// On the phone this is the *primary* channel, not a fallback. Background audio is fully
/// supported by iOS, whereas background haptics are not — and a buzz through a zipped
/// pocket is easy to miss anyway, while a tone in your headphones is not.
///
/// Segment changes are spoken ("Run", "Walk") because there's nothing to learn and no
/// ambiguity at the moment it matters most. Advisories are tones, so you aren't nagged
/// with chatter every time your pace drifts.
@MainActor
final class AudioCuePlayer {

    private let engine = AVAudioEngine()
    private let toneNode = AVAudioPlayerNode()
    private let speech = AVSpeechSynthesizer()
    private var isConfigured = false

    var spokenCuesEnabled = true
    var tonesEnabled = true

    /// Sets up an audio session that keeps working with the screen off and ducks your
    /// music rather than stopping it.
    func activate() throws {
        guard !isConfigured else { return }

        let session = AVAudioSession.sharedInstance()
        // A2DP only, deliberately. The other Bluetooth option is HFP — the mono
        // call profile — and allowing it lets iOS route a run's audio there, dropping
        // your music to phone-call quality for the sake of saying "Walk".
        try session.setCategory(
            .playback,
            mode: .spokenAudio,
            options: [.mixWithOthers, .duckOthers, .allowBluetoothA2DP]
        )
        try session.setActive(true)

        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        engine.attach(toneNode)
        engine.connect(toneNode, to: engine.mainMixerNode, format: format)
        try engine.start()
        toneNode.play()

        isConfigured = true
    }

    func deactivate() {
        speech.stopSpeaking(at: .immediate)
        toneNode.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isConfigured = false
    }

    func play(_ cue: Cue, units: DistanceUnit) {
        switch cue {
        case .beginSegment(let kind, _, _):
            say(kind.spokenCue)

        case .workoutComplete:
            say("Done")

        case .approachingZoneCeiling:
            say("Ease up")

        case .approachingZoneFloor:
            say("Pick it up")

        // Descending pair — "you're above your target".
        case .paceTooFast:
            chime([880, 660])

        // Ascending pair — "you're below it".
        case .paceTooSlow:
            chime([660, 880])

        case .distanceSplit(let index, let meters):
            let value = units.units(fromMeters: meters)
            say("\(Format.trimmed(value)) \(units == .miles ? "miles" : "kilometres")")
            _ = index

        case .segmentEndingSoon:
            chime([740], duration: 0.08)

        case .thresholdCrossed(let bpm, let rising):
            say("\(bpm) \(rising ? "and climbing" : "and falling")")
        }
    }

    private func say(_ text: String) {
        guard spokenCuesEnabled else { return }
        speech.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        // Slightly brisk: a cue you're still listening to when you should already be
        // running is worse than one that's over quickly.
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        utterance.postUtteranceDelay = 0
        speech.speak(utterance)
    }

    /// Plays a short sequence of pure tones, synthesised rather than shipped as files so
    /// the vocabulary can be tuned without touching assets.
    private func chime(_ frequencies: [Double], duration: TimeInterval = 0.12) {
        guard tonesEnabled, isConfigured else { return }
        for (index, frequency) in frequencies.enumerated() {
            guard let buffer = Self.tone(frequency: frequency, duration: duration) else { continue }
            let when: AVAudioTime? = index == 0
                ? nil
                : AVAudioTime(sampleTime: AVAudioFramePosition(Double(index) * duration * 44_100),
                              atRate: 44_100)
            toneNode.scheduleBuffer(buffer, at: when, options: [], completionHandler: nil)
        }
    }

    /// A sine with a short fade in and out — a raw square-edged tone clicks unpleasantly
    /// in headphones.
    private static func tone(frequency: Double, duration: TimeInterval) -> AVAudioPCMBuffer? {
        let sampleRate = 44_100.0
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let samples = buffer.floatChannelData?[0]
        else { return nil }

        buffer.frameLength = frameCount
        let fade = Int(sampleRate * 0.01)

        for frame in 0..<Int(frameCount) {
            let phase = 2.0 * .pi * frequency * Double(frame) / sampleRate
            var amplitude = 0.35
            if frame < fade {
                amplitude *= Double(frame) / Double(fade)
            } else if frame > Int(frameCount) - fade {
                amplitude *= Double(Int(frameCount) - frame) / Double(fade)
            }
            samples[frame] = Float(sin(phase) * amplitude)
        }
        return buffer
    }
}

private extension SegmentKind {
    /// What gets spoken at a transition. Short enough to land before you've taken two
    /// more strides.
    var spokenCue: String {
        switch self {
        case .run: return "Run"
        case .walk: return "Walk"
        case .warmup: return "Warm up"
        case .recover: return "Recover"
        case .cooldown: return "Cool down"
        }
    }
}
