import Foundation
import RuntilCore

/// A scripted runner, for developing and verifying without leaving the house.
///
/// The heart rate isn't a recording — it *responds* to what the plan currently asks for,
/// rising while running and decaying while walking, and only after a configurable delay.
/// That delay is the whole point: it reproduces the physiological lag the engine exists to
/// compensate for, so the Zone 2 logic can be exercised honestly at a desk.
final class SimulatedMetricSource: MetricSource {

    struct Profile {
        /// Heart rate the runner settles at while running / while walking.
        var runningPlateau: Double = 148
        var walkingPlateau: Double = 112
        var startingHeartRate: Double = 95
        /// Seconds before heart rate begins responding to a change in effort.
        var responseDelay: TimeInterval = 20
        /// How quickly it closes the gap to the plateau, per second.
        var approachRate: Double = 0.02
        var runningSpeed: Double = 3.0      // m/s ≈ 8:57 /mi
        var walkingSpeed: Double = 1.45     // m/s ≈ 18:30 /mi
        var noise: Double = 1.5
        /// Wall-clock seconds per simulated second. 0.1 runs a 20-minute workout in two.
        var timeScale: Double = 0.1

        /// Launch with `-speed 1` to run the simulation in real time.
        ///
        /// The default 10× is right for exercising a whole plan quickly, but it turns
        /// every transition into a single frame — useless for checking what the screen
        /// actually does in the seconds after a cue.
        static var `default`: Profile {
            var profile = Profile()
            let arguments = ProcessInfo.processInfo.arguments
            if let index = arguments.firstIndex(of: "-speed"),
               arguments.indices.contains(index + 1),
               let scale = Double(arguments[index + 1]), scale > 0 {
                profile.timeScale = 1.0 / scale
            }
            return profile
        }
    }

    /// Told by the controller what the plan currently expects, which is what makes the
    /// simulated body react to the plan rather than ignore it.
    var currentEffortIsRunning: () -> Bool = { true }

    /// Never fires — the simulation has no session to lose.
    var onFailure: ((SourceFailure) -> Void)?

    private let profile: Profile
    private var task: Task<Void, Never>?
    private var continuation: AsyncStream<Tick>.Continuation?

    let ticks: AsyncStream<Tick>

    init(profile: Profile = .default) {
        self.profile = profile
        var capturedContinuation: AsyncStream<Tick>.Continuation!
        self.ticks = AsyncStream { capturedContinuation = $0 }
        self.continuation = capturedContinuation
    }

    func start() async throws {
        task?.cancel()
        let profile = self.profile

        task = Task { [weak self] in
            var elapsed: TimeInterval = 0
            var distance: Double = 0
            var heartRate = profile.startingHeartRate
            var effortWasRunning = true
            var secondsSinceEffortChange = profile.responseDelay

            while !Task.isCancelled {
                guard let self else { return }
                let running = self.currentEffortIsRunning()

                if running != effortWasRunning {
                    effortWasRunning = running
                    secondsSinceEffortChange = 0
                }
                secondsSinceEffortChange += 1

                // Heart rate only starts moving once the delay has passed — the lag the
                // engine's projection is designed to see through.
                if secondsSinceEffortChange >= profile.responseDelay {
                    let plateau = running ? profile.runningPlateau : profile.walkingPlateau
                    heartRate += (plateau - heartRate) * profile.approachRate
                }

                let speed = running ? profile.runningSpeed : profile.walkingSpeed
                distance += speed
                elapsed += 1

                let jitter = Double.random(in: -profile.noise...profile.noise)
                self.continuation?.yield(
                    Tick(
                        elapsed: elapsed,
                        totalDistance: distance,
                        heartRate: Int((heartRate + jitter).rounded()),
                        instantPace: 1.0 / speed
                    )
                )

                try? await Task.sleep(for: .seconds(profile.timeScale))
            }
        }
    }

    func stop() async {
        task?.cancel()
        task = nil
        continuation?.finish()
    }

    func finish() async {}
}
