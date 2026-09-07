import Foundation
import RuntilCore

/// Where `Tick`s come from.
///
/// Two implementations: HealthKit + CoreLocation on a real wrist, and a scripted simulation
/// for the simulator, which has neither a heart rate sensor nor working haptics. Everything
/// above this protocol is identical in both cases, so what gets verified at a desk is the
/// same code that runs on a run.
protocol MetricSource: AnyObject {
    var ticks: AsyncStream<Tick> { get }

    /// Called when the source dies mid-run rather than at start — most importantly when
    /// another app takes over the watch's single workout session.
    var onFailure: ((SourceFailure) -> Void)? { get set }

    func start() async throws
    func stop() async
    /// Saves the workout where the source supports it; a no-op for the simulation.
    func finish() async
}

/// A failure worth explaining to the runner in words, rather than a raw error string.
struct SourceFailure {
    let title: String
    let message: String

    /// watchOS allows exactly one *primary* workout session across the whole device. If
    /// another app already holds it — or grabs it mid-run — HealthKit reports
    /// `HKError.errorAnotherWorkoutSessionStarted`, and there is no way to share.
    static let anotherSessionRunning = SourceFailure(
        title: "Another app is tracking",
        message: "Apple Watch allows only one workout at a time, and another app has it. End that workout to use runtil, or let runtil coach while your phone tracks the run."
    )

    static func unexpected(_ error: Error) -> SourceFailure {
        SourceFailure(title: "Workout stopped", message: error.localizedDescription)
    }
}
