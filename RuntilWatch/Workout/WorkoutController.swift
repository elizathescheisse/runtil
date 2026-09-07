import Foundation
import Observation
import RuntilCore

/// Ties a plan, a metric source, the cue engine, and the haptic player together.
///
/// Deliberately thin: all the interesting decisions live in `CueEngine`, which is pure and
/// tested. This layer only moves data between the sensors, the engine, and the wrist.
@MainActor
@Observable
final class WorkoutController {

    enum State: Equatable {
        case idle
        case running
        case paused
        case finished
        case failed(title: String, message: String)
    }

    private(set) var state: State = .idle
    private(set) var engine: CueEngine?
    private(set) var latestTick: Tick?
    private(set) var elapsed: TimeInterval = 0

    let haptics = HapticPlayer()

    /// True when driven by `SimulatedMetricSource`, which surfaces the cue log in the UI —
    /// the simulator has no heart rate sensor and no working haptics, so the log is the
    /// only way to see what the engine decided.
    private(set) var isSimulated = false

    private var source: MetricSource?
    private var consumeTask: Task<Void, Never>?

    // MARK: Live readouts

    var currentSegment: Segment? { engine?.currentSegment }
    var heartRate: Int? { latestTick?.heartRate }
    var projectedHeartRate: Int? { engine?.projectedHeartRate }
    var distance: Double { latestTick?.totalDistance ?? 0 }
    var rollingPace: Double? { engine?.rollingPace }
    var plan: WorkoutPlan? { engine?.plan }

    /// Seconds spent in the current segment.
    var timeInSegment: TimeInterval {
        guard let engine else { return 0 }
        return elapsed - engine.segmentStartElapsed
    }

    /// Countdown for timed segments; nil when the segment ends on something else.
    var timeRemainingInSegment: TimeInterval? {
        guard let segment = currentSegment, case .duration(let total) = segment.end else { return nil }
        return max(0, total - timeInSegment)
    }

    /// What the lag looks like measured against *this* run, once there's enough to say.
    var measuredLagSuggestion: TimeInterval? {
        guard let engine, engine.lagObservations.count >= 2 else { return nil }
        return engine.lagObservations.suggestedLagSeconds
    }

    // MARK: Lifecycle

    func start(plan: WorkoutPlan, simulated: Bool) async {
        let engine = CueEngine(plan: plan)
        self.engine = engine
        self.isSimulated = simulated
        haptics.reset()

        var source: MetricSource
        if simulated {
            let simulation = SimulatedMetricSource()
            // Close the loop: the simulated body responds to what the plan is asking for.
            simulation.currentEffortIsRunning = { [weak engine] in
                engine?.currentSegment?.kind.isEffort ?? true
            }
            source = simulation
        } else {
            source = LiveMetricSource(savesToHealth: plan.savesToHealth)
        }

        // Another app can seize the watch's single workout session mid-run, which ends
        // ours — so the failure has to be explained on screen, not swallowed.
        source.onFailure = { [weak self] failure in
            Task { @MainActor in
                self?.state = .failed(title: failure.title, message: failure.message)
            }
        }
        self.source = source

        do {
            try await source.start()
        } catch let error as LiveMetricSource.SourceError where error == .anotherWorkoutRunning {
            state = .failed(
                title: SourceFailure.anotherSessionRunning.title,
                message: SourceFailure.anotherSessionRunning.message
            )
            return
        } catch {
            state = .failed(title: "Couldn't start", message: error.localizedDescription)
            return
        }

        state = .running
        consume(from: source, engine: engine)
    }

    private func consume(from source: MetricSource, engine: CueEngine) {
        consumeTask?.cancel()
        consumeTask = Task { [weak self] in
            for await tick in source.ticks {
                guard let self, !Task.isCancelled else { return }
                guard self.state == .running else { continue }

                self.latestTick = tick
                self.elapsed = tick.elapsed

                for cue in engine.advance(tick) {
                    self.haptics.play(cue, elapsed: tick.elapsed)
                    if case .workoutComplete = cue { await self.finish() }
                }
            }
        }
    }

    func pause() {
        guard state == .running else { return }
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        state = .running
    }

    /// Ends the current segment early — the whole of a `.manual` plan, and an override for
    /// every other mode.
    func skipSegment() {
        guard let engine, state == .running else { return }
        for cue in engine.skipSegment(at: elapsed, totalDistance: distance) {
            haptics.play(cue, elapsed: elapsed)
        }
    }

    func finish() async {
        consumeTask?.cancel()
        consumeTask = nil
        await source?.stop()
        await source?.finish()
        source = nil
        state = .finished
    }

    func reset() {
        engine = nil
        latestTick = nil
        elapsed = 0
        state = .idle
        haptics.reset()
    }
}
