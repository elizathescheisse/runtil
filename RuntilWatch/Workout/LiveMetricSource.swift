import Foundation
import HealthKit
import CoreLocation
import RuntilCore

/// The real thing: an `HKWorkoutSession` feeding heart rate and distance, with CoreLocation
/// supplying pace.
///
/// The workout session isn't incidental — it's what earns the app background runtime, and
/// it's the reason `WKInterfaceDevice.play` still reaches your wrist with the screen off and
/// your arm down. A plain timer app would go silent the moment the display slept. It also
/// means the run lands in Fitness and counts toward the activity rings.
final class LiveMetricSource: NSObject, MetricSource {

    enum SourceError: Error, LocalizedError {
        case healthDataUnavailable
        case authorizationDenied
        case anotherWorkoutRunning

        var errorDescription: String? {
            switch self {
            case .healthDataUnavailable: return "Health data isn't available on this device."
            case .authorizationDenied: return "runtil needs permission to read your heart rate."
            case .anotherWorkoutRunning: return SourceFailure.anotherSessionRunning.message
            }
        }
    }

    var onFailure: ((SourceFailure) -> Void)?

    /// When false the run is discarded at the end instead of saved, so a second app
    /// recording the same run doesn't produce a duplicate workout in Health.
    private let savesToHealth: Bool

    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private let locationManager = CLLocationManager()

    private var startDate: Date?
    private var latestHeartRate: Int?
    private var latestDistance: Double = 0
    /// Pace from GPS speed rather than HealthKit distance: HealthKit delivers distance in
    /// laggy chunks, which is fine for splits but far too coarse to cue pace on.
    private var latestPace: Double?

    private var continuation: AsyncStream<Tick>.Continuation?
    private var tickTask: Task<Void, Never>?

    let ticks: AsyncStream<Tick>

    init(savesToHealth: Bool = true) {
        self.savesToHealth = savesToHealth
        var capturedContinuation: AsyncStream<Tick>.Continuation!
        self.ticks = AsyncStream { capturedContinuation = $0 }
        super.init()
        self.continuation = capturedContinuation
        locationManager.delegate = self
        locationManager.activityType = .fitness
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
    }

    // MARK: Authorization

    static var shareTypes: Set<HKSampleType> {
        [HKQuantityType.workoutType()]
    }

    static var readTypes: Set<HKObjectType> {
        [
            HKQuantityType(.heartRate),
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.activeEnergyBurned),
            HKObjectType.activitySummaryType()
        ]
    }

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw SourceError.healthDataUnavailable }
        try await store.requestAuthorization(toShare: Self.shareTypes, read: Self.readTypes)
    }

    // MARK: Lifecycle

    func start() async throws {
        try await requestAuthorization()

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .running
        configuration.locationType = .outdoor

        let session = try HKWorkoutSession(healthStore: store, configuration: configuration)
        let builder = session.associatedWorkoutBuilder()
        builder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: configuration)
        session.delegate = self
        builder.delegate = self

        self.session = session
        self.builder = builder

        let start = Date()
        startDate = start
        session.startActivity(with: start)
        do {
            try await builder.beginCollection(at: start)
        } catch let error as HKError where error.code == .errorAnotherWorkoutSessionStarted {
            // Another app already held the session when we tried to start.
            throw SourceError.anotherWorkoutRunning
        }

        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()

        startTicking()
    }

    /// Emits at a steady 1 Hz regardless of when samples happen to arrive, so the engine
    /// sees an even cadence and time-based triggers stay accurate.
    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let startDate = self.startDate else { return }
                self.continuation?.yield(
                    Tick(
                        elapsed: Date().timeIntervalSince(startDate),
                        totalDistance: self.latestDistance,
                        heartRate: self.latestHeartRate,
                        instantPace: self.latestPace
                    )
                )
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() async {
        tickTask?.cancel()
        tickTask = nil
        locationManager.stopUpdatingLocation()
        session?.end()
        continuation?.finish()
    }

    func finish() async {
        guard let builder else { return }
        try? await builder.endCollection(at: Date())
        if savesToHealth {
            _ = try? await builder.finishWorkout()
        } else {
            // Coaching-only: something else is recording this run, so saving here would
            // put a second overlapping workout in Health.
            //
            // The heart rate readings survive this. Per HKWorkoutBuilder: "Samples that
            // were added to the workout will not be deleted." So the other app still gets
            // the dense heart rate data that only exists because we held a workout
            // session — outside one, the watch samples every few minutes, not every second.
            builder.discardWorkout()
        }
    }
}

// MARK: - HKWorkoutSessionDelegate

extension LiveMetricSource: HKWorkoutSessionDelegate {
    func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {}

    /// The conflict usually lands here rather than at `start()`: another app can seize the
    /// watch's single workout session mid-run, which ends ours.
    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        let failure: SourceFailure
        if (error as? HKError)?.code == .errorAnotherWorkoutSessionStarted {
            failure = .anotherSessionRunning
        } else {
            failure = .unexpected(error)
        }
        onFailure?(failure)
        continuation?.finish()
    }
}

// MARK: - HKLiveWorkoutBuilderDelegate

extension LiveMetricSource: HKLiveWorkoutBuilderDelegate {
    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    func workoutBuilder(
        _ workoutBuilder: HKLiveWorkoutBuilder,
        didCollectDataOf collectedTypes: Set<HKSampleType>
    ) {
        for type in collectedTypes {
            guard let quantityType = type as? HKQuantityType,
                  let statistics = workoutBuilder.statistics(for: quantityType)
            else { continue }

            switch quantityType {
            case HKQuantityType(.heartRate):
                let unit = HKUnit.count().unitDivided(by: .minute())
                if let bpm = statistics.mostRecentQuantity()?.doubleValue(for: unit) {
                    latestHeartRate = Int(bpm.rounded())
                }

            case HKQuantityType(.distanceWalkingRunning):
                if let meters = statistics.sumQuantity()?.doubleValue(for: .meter()) {
                    latestDistance = meters
                }

            default:
                break
            }
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension LiveMetricSource: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        // A negative speed means no valid fix; below ~0.5 m/s the reading is drift, not pace.
        guard location.speed > 0.5, location.horizontalAccuracy >= 0, location.horizontalAccuracy < 50 else {
            latestPace = nil
            return
        }
        latestPace = 1.0 / location.speed
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        latestPace = nil
    }
}
