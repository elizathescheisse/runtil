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
    private var cueSequence = 0
    private var lastCue: Cue?

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

    /// Whether the pace band was set too tight, judged against what this run actually did.
    /// Reported for the effort segment, which is the one being paced.
    var paceSuggestion: (kind: SegmentKind, suggestion: PaceCalibration.Suggestion)? {
        guard let engine, let target = engine.plan.advisories.paceTarget else { return nil }
        for (kind, observed) in engine.paceObservations {
            guard let band = target.bandsByKind[kind] else { continue }
            let suggestion = PaceCalibration.suggest(
                observed: observed,
                band: band,
                cueCount: engine.paceCueCounts[kind] ?? 0
            )
            if let suggestion, suggestion.isWorthOffering { return (kind, suggestion) }
        }
        return nil
    }

    /// What the lag looks like measured against *this* run, once there's enough to say.
    var measuredLagSuggestion: TimeInterval? {
        guard let engine, engine.lagObservations.count >= 2 else { return nil }
        return engine.lagObservations.suggestedLagSeconds
    }

    // MARK: Lifecycle

    /// True while a workout session is live, including paused.
    var isActive: Bool {
        state == .running || state == .paused
    }

    /// Whether the phone is receiving a live copy. Surfaced because mirroring failing
    /// silently is indistinguishable from the phone app simply not being open, and the
    /// two want completely different fixes.
    var isMirroringToPhone: Bool {
        (source as? LiveMetricSource)?.isMirroring ?? false
    }

    func start(plan: WorkoutPlan, simulated: Bool) async {
        // Starting a second run over a live one would orphan the first session, which
        // keeps holding the watch's only workout slot with no way to reach it.
        guard !isActive else { return }

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
                    if self.lastCue == nil || cue.priority >= (self.lastCue?.priority ?? 0) {
                        self.lastCue = cue
                        self.cueSequence += 1
                    }
                    if case .workoutComplete = cue { await self.finish() }
                }
                self.mirrorToPhone()
            }
        }
    }

    /// Sends the phone a snapshot of the run, if it's listening.
    ///
    /// Once per tick, and entirely optional — the watch holds the session, reads the
    /// sensors and plays the cues regardless of whether a phone is anywhere nearby.
    private func mirrorToPhone() {
        guard let live = source as? LiveMetricSource, let engine, let plan else { return }
        live.mirror(
            MirroredState(
                planName: plan.name,
                elapsed: elapsed,
                segmentKind: currentSegment?.kind,
                cycle: engine.cycle,
                timeInSegment: timeInSegment,
                timeRemainingInSegment: timeRemainingInSegment,
                heartRate: heartRate,
                projectedHeartRate: projectedHeartRate,
                distanceMeters: distance,
                paceSecondsPerMeter: rollingPace,
                units: plan.units,
                lastCueSummary: lastCue?.summary,
                lastCue: lastCue,
                cueSequence: cueSequence,
                isFinished: state == .finished
            )
        )
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

        // Marked finished up front. Saving a workout involves several awaits on HealthKit,
        // and gating the screen on them means one slow call leaves you staring at a run
        // you already ended, pressing a button that appears to do nothing.
        state = .finished

        let finishing = source
        source = nil
        await finishing?.stop()
        await finishing?.finish()
    }

    func reset() {
        engine = nil
        latestTick = nil
        elapsed = 0
        state = .idle
        haptics.reset()
    }
}
