import Foundation
import Observation
import UIKit
import RuntilCore

/// Runs a plan on the phone.
///
/// Structurally identical to the watch controller, which is the point: `CueEngine` doesn't
/// know or care which device it's on, so only the sensors and the cue output differ.
@MainActor
@Observable
final class PhoneWorkoutController {

    enum State: Equatable {
        case idle, running, paused, finished
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var engine: CueEngine?
    private(set) var latestTick: Tick?
    private(set) var elapsed: TimeInterval = 0

    let cues = PhoneCuePlayer()
    let monitor = HeartRateMonitor()

    private var source: PhoneMetricSource?
    private var consumeTask: Task<Void, Never>?

    var currentSegment: Segment? { engine?.currentSegment }
    var plan: WorkoutPlan? { engine?.plan }
    var heartRate: Int? { latestTick?.heartRate }
    var distance: Double { latestTick?.totalDistance ?? 0 }
    var rollingPace: Double? { engine?.rollingPace }

    var timeInSegment: TimeInterval {
        guard let engine else { return 0 }
        return elapsed - engine.segmentStartElapsed
    }

    var timeRemainingInSegment: TimeInterval? {
        guard let segment = currentSegment, case .duration(let total) = segment.end else { return nil }
        return max(0, total - timeInSegment)
    }

    /// Heart-rate plans need a paired monitor on the phone — there's no sensor otherwise.
    func canRun(_ plan: WorkoutPlan) -> Bool {
        plan.driveMode != .heartRate || monitor.state.isConnected
    }

    func start(plan: WorkoutPlan) async {
        let engine = CueEngine(plan: plan)
        self.engine = engine
        cues.reset()

        do {
            try cues.activate()
        } catch {
            state = .failed("Couldn't start audio: \(error.localizedDescription)")
            return
        }

        // The run has to survive the screen locking, which it does through background
        // location — but only while the app is actually running, so the idle timer stays
        // off whenever the phone is in hand.
        UIApplication.shared.isIdleTimerDisabled = true

        let source = PhoneMetricSource(
            monitor: monitor.state.isConnected ? monitor : nil,
            savesToHealth: plan.savesToHealth
        )
        source.onFailure = { [weak self] message in
            Task { @MainActor in self?.state = .failed(message) }
        }
        self.source = source

        do {
            try await source.start()
        } catch {
            state = .failed(error.localizedDescription)
            return
        }

        state = .running
        consume(from: source, engine: engine, units: plan.units)
    }

    private func consume(from source: PhoneMetricSource, engine: CueEngine, units: DistanceUnit) {
        consumeTask?.cancel()
        consumeTask = Task { [weak self] in
            for await tick in source.ticks {
                guard let self, !Task.isCancelled else { return }
                guard self.state == .running else { continue }

                self.latestTick = tick
                self.elapsed = tick.elapsed

                for cue in engine.advance(tick) {
                    self.cues.play(cue, elapsed: tick.elapsed, units: units)
                    if case .workoutComplete = cue { await self.finish() }
                }
            }
        }
    }

    func pause() { if state == .running { state = .paused } }
    func resume() { if state == .paused { state = .running } }

    func skipSegment() {
        guard let engine, state == .running, let plan else { return }
        for cue in engine.skipSegment(at: elapsed, totalDistance: distance) {
            cues.play(cue, elapsed: elapsed, units: plan.units)
        }
    }

    func finish() async {
        consumeTask?.cancel()
        consumeTask = nil

        // The run usually ends mid-interval, so the segment you were in has to be closed
        // by hand or it never reaches the breakdown at all.
        if let engine, let tick = latestTick {
            engine.closeOpenSegment(at: tick.elapsed, totalDistance: tick.totalDistance)
        }

        await source?.stop()
        await source?.finish(segments: engine?.segmentLog ?? [])
        source = nil
        cues.deactivate()
        UIApplication.shared.isIdleTimerDisabled = false
        state = .finished
    }

    func reset() {
        engine = nil
        latestTick = nil
        elapsed = 0
        state = .idle
        cues.reset()
    }
}
