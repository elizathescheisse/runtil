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

    /// Whether the phone is currently receiving a live copy of this run.
    private(set) var isMirroring = false

    /// Whether this build is actually allowed to keep location running in the background.
    static var declaresLocationBackgroundMode: Bool {
        let modes = Bundle.main.object(forInfoDictionaryKey: "WKBackgroundModes") as? [String]
        return modes?.contains("location") ?? false
    }

    /// When false the run is discarded at the end instead of saved, so a second app
    /// recording the same run doesn't produce a duplicate workout in Health.
    private let savesToHealth: Bool

    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var routeBuilder: HKWorkoutRouteBuilder?
    private let locationManager = CLLocationManager()

    private var startDate: Date?
    private var latestHeartRate: Int?
    private var latestDistance: Double = 0

    /// Kept so elevation gain can be computed at the end. Apple Watch has a barometric
    /// altimeter, so these are better than phone-only GPS altitude.
    private var altitudes: [Double] = []
    private var weather: WeatherSnapshot?
    private var hasRequestedWeather = false
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

    /// Everything the workout needs permission to *write*.
    ///
    /// The workout type alone isn't enough. `HKLiveWorkoutDataSource` collects heart rate,
    /// energy and distance during the session, and those samples are saved with the
    /// workout when it finishes — but only for types we're authorised to share. Omitting
    /// them yields a workout with a duration and nothing else: no calories, no distance,
    /// no rings credit. The route is likewise a separate series type.
    static var shareTypes: Set<HKSampleType> {
        [
            HKQuantityType.workoutType(),
            HKSeriesType.workoutRoute(),
            HKQuantityType(.heartRate),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.basalEnergyBurned),
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.stepCount)
        ]
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
        // Taken from the workout builder rather than constructed directly, so the route is
        // finished and attached automatically when the workout finishes — and discarded
        // with it when we discard.
        self.routeBuilder = builder.seriesBuilder(for: HKSeriesType.workoutRoute()) as? HKWorkoutRouteBuilder

        let start = Date()
        startDate = start
        session.startActivity(with: start)
        do {
            try await builder.beginCollection(at: start)
        } catch let error as HKError where error.code == .errorAnotherWorkoutSessionStarted {
            // Another app already held the session when we tried to start.
            throw SourceError.anotherWorkoutRunning
        }

        await startMirroring(session)

        locationManager.requestWhenInUseAuthorization()
        // Without this, location updates stop the moment the screen sleeps — which would
        // lose both the route and pace cues for most of the run.
        //
        // Guarded because CoreLocation raises an exception, rather than failing quietly,
        // if the `location` background mode isn't declared. A missing plist entry should
        // cost pace accuracy, not take the whole run down mid-stride.
        if Self.declaresLocationBackgroundMode {
            locationManager.allowsBackgroundLocationUpdates = true
        }
        locationManager.startUpdatingLocation()

        startTicking()
    }

    /// Offers the phone a live copy of the run.
    ///
    /// Best-effort: a run must never depend on the phone being present, reachable, or even
    /// owned. Failure here is silent because the watch is doing the actual work either way.
    private func startMirroring(_ session: HKWorkoutSession) async {
        do {
            try await session.startMirroringToCompanionDevice()
            isMirroring = true
        } catch {
            isMirroring = false
        }
    }

    /// Pushes a snapshot to the phone. Dropped silently if mirroring isn't running —
    /// this is a display update, never something a cue waits on.
    func mirror(_ state: MirroredState) {
        guard isMirroring, let session, let data = try? state.encoded() else { return }
        Task { try? await session.sendToRemoteWorkoutSession(data: data) }
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

    /// Conditions explain a lot about a run — heart rate for a given pace climbs sharply
    /// in heat and humidity — so they're recorded once, at the start, rather than averaged.
    private func fetchWeatherIfNeeded(at location: CLLocation) {
        guard !hasRequestedWeather else { return }
        hasRequestedWeather = true
        Task { [weak self] in
            self?.weather = try? await WeatherLookup.current(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude
            )
        }
    }

    /// Everything worth attaching to the finished workout that HealthKit won't derive.
    private var workoutMetadata: [String: Any] {
        var metadata: [String: Any] = [:]

        let gain = RunAnalysis.elevationGain(altitudes: altitudes)
        if gain > 0 {
            metadata[HKMetadataKeyElevationAscended] = HKQuantity(unit: .meter(), doubleValue: gain)
        }
        if let weather {
            metadata[HKMetadataKeyWeatherTemperature] = HKQuantity(
                unit: .degreeCelsius(), doubleValue: weather.temperatureCelsius
            )
            // HealthKit expects a fraction here, not whole percent.
            metadata[HKMetadataKeyWeatherHumidity] = HKQuantity(
                unit: .percent(), doubleValue: weather.relativeHumidity
            )
            // No HealthKit key exists for dew point, so it goes under our own. Stored as
            // a plain number because custom metadata must be a property-list type.
            metadata[MetadataKey.dewPointCelsius] = weather.effectiveDewPointCelsius
        }
        return metadata
    }

    func finish() async {
        guard let builder else { return }

        let metadata = workoutMetadata
        if !metadata.isEmpty {
            try? await builder.addMetadata(metadata)
        }
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
        // Route: keep anything with a usable fix. Filtering hard here would punch holes in
        // the map, so the bar is lower than for pace.
        let routable = locations.filter { $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= 50 }
        if !routable.isEmpty, savesToHealth {
            routeBuilder?.insertRouteData(routable) { _, _ in }
        }

        if let first = routable.first {
            fetchWeatherIfNeeded(at: first)
        }
        // Vertical accuracy is a separate, much worse figure than horizontal, so it's
        // checked on its own — a fix good enough for the map may be useless for altitude.
        altitudes += routable
            .filter { $0.verticalAccuracy > 0 && $0.verticalAccuracy <= 15 }
            .map(\.altitude)

        guard let location = locations.last else { return }
        // Pace is stricter: a negative speed means no valid fix, and below ~0.5 m/s the
        // reading is GPS drift rather than movement.
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
