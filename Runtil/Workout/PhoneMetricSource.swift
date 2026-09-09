import Foundation
import CoreLocation
import HealthKit
import RuntilCore

/// Feeds the cue engine from the phone.
///
/// The watch version leans on an `HKWorkoutSession` for distance and heart rate; the phone
/// has neither, so distance is accumulated from GPS and heart rate comes from a Bluetooth
/// monitor if one is paired. Everything above this — the whole interval state machine — is
/// the same tested code.
///
/// Background location isn't just for the route here: it's what keeps the app alive at all
/// once the screen goes off. Without it iOS suspends us and the run goes silent.
final class PhoneMetricSource: NSObject {

    private let locationManager = CLLocationManager()
    private let monitor: HeartRateMonitor?
    private let savesToHealth: Bool

    private var startDate: Date?
    private var totalDistance: Double = 0
    private var lastLocation: CLLocation?
    private var latestPace: Double?

    private var altitudes: [Double] = []
    private var weather: WeatherSnapshot?
    private var hasRequestedWeather = false

    private var continuation: AsyncStream<Tick>.Continuation?
    private var tickTask: Task<Void, Never>?

    private let store = HKHealthStore()
    private var builder: HKWorkoutBuilder?
    private var routeBuilder: HKWorkoutRouteBuilder?

    let ticks: AsyncStream<Tick>
    var onFailure: ((String) -> Void)?

    init(monitor: HeartRateMonitor?, savesToHealth: Bool) {
        self.monitor = monitor
        self.savesToHealth = savesToHealth
        var captured: AsyncStream<Tick>.Continuation!
        self.ticks = AsyncStream { captured = $0 }
        super.init()
        self.continuation = captured

        locationManager.delegate = self
        locationManager.activityType = .fitness
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = kCLDistanceFilterNone
    }

    func start() async throws {
        // "Always" isn't needed — "when in use" plus background updates covers a run the
        // user explicitly started, and asks for less.
        locationManager.requestWhenInUseAuthorization()
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.startUpdatingLocation()

        startDate = Date()

        if savesToHealth, HKHealthStore.isHealthDataAvailable() {
            try? await store.requestAuthorization(
                toShare: [
                    HKQuantityType.workoutType(),
                    HKSeriesType.workoutRoute(),
                    HKQuantityType(.workoutEffortScore)
                ],
                read: [HKQuantityType(.heartRate), HKQuantityType(.distanceWalkingRunning)]
            )
            await beginWorkout()
        }

        startTicking()
    }

    private func beginWorkout() async {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .running
        configuration.locationType = .outdoor

        let builder = HKWorkoutBuilder(
            healthStore: store,
            configuration: configuration,
            device: .local()
        )

        self.builder = builder
        self.routeBuilder = builder.seriesBuilder(for: HKSeriesType.workoutRoute()) as? HKWorkoutRouteBuilder
        try? await builder.beginCollection(at: startDate ?? Date())
    }

    /// A steady 1 Hz tick regardless of when GPS fixes land, so time-based triggers stay
    /// accurate even where the signal is poor.
    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let startDate = self.startDate else { return }
                self.continuation?.yield(
                    Tick(
                        elapsed: Date().timeIntervalSince(startDate),
                        totalDistance: self.totalDistance,
                        heartRate: self.monitor?.heartRate,
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
        continuation?.finish()
    }

    /// Conditions explain a lot about a run, so they're recorded once at the start.
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

    private var workoutMetadata: [String: Any] {
        var metadata: [String: Any] = [:]
        // A larger threshold than the watch uses: phone GPS altitude has no barometer
        // behind it and wanders further.
        let gain = RunAnalysis.elevationGain(altitudes: altitudes, threshold: 4.0)
        if gain > 0 {
            metadata[HKMetadataKeyElevationAscended] = HKQuantity(unit: .meter(), doubleValue: gain)
        }
        if let weather {
            metadata[HKMetadataKeyWeatherTemperature] = HKQuantity(
                unit: .degreeCelsius(), doubleValue: weather.temperatureCelsius
            )
            metadata[HKMetadataKeyWeatherHumidity] = HKQuantity(
                unit: .percent(), doubleValue: weather.relativeHumidity
            )
            // No HealthKit key exists for dew point, so it goes under our own. Stored as
            // a plain number because custom metadata must be a property-list type.
            metadata[MetadataKey.dewPointCelsius] = weather.effectiveDewPointCelsius
        }
        return metadata
    }

    func finish(segments: [SegmentRecord]) async {
        guard let builder else { return }

        let metadata = workoutMetadata
        if !metadata.isEmpty {
            try? await builder.addMetadata(metadata)
        }
        // Before ending collection: a builder that has closed refuses further events.
        //
        // Our own start date, not the builder's. Segment times are elapsed seconds measured
        // from this exact instant, so anything else risks sliding every boundary by however
        // much the two disagree.
        if let start = startDate, !segments.isEmpty {
            let events = WorkoutSegmentEvents.events(for: segments, startingAt: start)
            if !events.isEmpty { try? await builder.addWorkoutEvents(events) }
        }
        try? await builder.endCollection(at: Date())
        if savesToHealth {
            _ = try? await builder.finishWorkout()
        } else {
            builder.discardWorkout()
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension PhoneMetricSource: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let usable = locations.filter { $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= 50 }
        guard !usable.isEmpty else { return }

        if savesToHealth {
            routeBuilder?.insertRouteData(usable) { _, _ in }
        }

        if let first = usable.first {
            fetchWeatherIfNeeded(at: first)
        }
        // Vertical accuracy is a separate and much worse figure than horizontal.
        altitudes += usable
            .filter { $0.verticalAccuracy > 0 && $0.verticalAccuracy <= 25 }
            .map(\.altitude)

        for location in usable {
            defer { lastLocation = location }
            guard let previous = lastLocation else { continue }

            // The phone has no workout session totalling distance for us, so it's summed
            // here. Steps under 1m are GPS jitter while standing still, and adding them
            // would inflate a run by a surprising amount over an hour.
            let step = location.distance(from: previous)
            if step >= 1.0 {
                totalDistance += step
            }
        }

        if let latest = usable.last, latest.speed > 0.5 {
            latestPace = 1.0 / latest.speed
        } else {
            latestPace = nil
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        latestPace = nil
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .denied, .restricted:
            onFailure?("runtil needs location access to measure your distance and pace.")
        default:
            break
        }
    }
}
