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
    func start() async throws
    func stop() async
    /// Saves the workout where the source supports it; a no-op for the simulation.
    func finish() async
}
