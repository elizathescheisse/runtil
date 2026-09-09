import Foundation
import HealthKit
import CoreLocation
import Observation
import RuntilCore

/// Pulls one workout's detail out of HealthKit and runs it through `RunAnalysis`.
///
/// Everything here is retrieval and assembly; the actual maths lives in RuntilCore where
/// it's tested. This layer's only job is to hand it well-formed arrays.
@MainActor
@Observable
final class WorkoutDetailLoader {

    private(set) var heartRateSamples: [(elapsed: TimeInterval, bpm: Int)] = []
    private(set) var zoneTimes: [RunAnalysis.ZoneTime] = []
    private(set) var splits: [RunAnalysis.Split] = []
    private(set) var altitudes: [Double] = []

    private(set) var totalDistance: Double?
    private(set) var activeCalories: Double?
    private(set) var averageHeartRate: Int?
    private(set) var maxHeartRate: Int?
    private(set) var elevationGain: Double?
    private(set) var weather: WeatherSnapshot?
    private(set) var effortScore: Double?

    private let store = HKHealthStore()

    func load(workout: HKWorkout, zones: HeartRateZones) async {
        readTotals(from: workout)
        readMetadata(from: workout)

        heartRateSamples = await loadHeartRate(for: workout)
        if !heartRateSamples.isEmpty {
            zoneTimes = RunAnalysis.timeInZones(samples: heartRateSamples, zones: zones)
            averageHeartRate = RunAnalysis.averageHeartRate(
                samples: heartRateSamples, from: 0, to: workout.duration
            )
            maxHeartRate = heartRateSamples.map(\.bpm).max()
        }

        let locations = await loadRoute(for: workout)
        if !locations.isEmpty {
            altitudes = locations
                .filter { $0.verticalAccuracy > 0 && $0.verticalAccuracy <= 25 }
                .map(\.altitude)

            // The route gives cumulative distance over time, which is what splits need.
            let start = workout.startDate
            var cumulative = 0.0
            var previous: CLLocation?
            var samples: [(elapsed: TimeInterval, distance: Double)] = []
            for location in locations {
                if let previous {
                    let step = location.distance(from: previous)
                    if step >= 1 { cumulative += step }
                }
                previous = location
                samples.append((location.timestamp.timeIntervalSince(start), cumulative))
            }

            splits = RunAnalysis.splits(
                samples: samples,
                every: DistanceUnit.miles.metersPerUnit
            )
            attachHeartRates(to: &splits, samples: samples)
        }

        effortScore = await loadEffortScore(for: workout)
    }

    /// Labels each split with the heart rate held during it, which is what makes a split
    /// table say something about effort rather than only about pace.
    private func attachHeartRates(
        to splits: inout [RunAnalysis.Split],
        samples: [(elapsed: TimeInterval, distance: Double)]
    ) {
        var start: TimeInterval = 0
        for index in splits.indices {
            let end = start + splits[index].duration
            splits[index].averageHeartRate = RunAnalysis.averageHeartRate(
                samples: heartRateSamples, from: start, to: end
            )
            start = end
        }
    }

    // MARK: Reading

    private func readTotals(from workout: HKWorkout) {
        totalDistance = workout.statistics(for: HKQuantityType(.distanceWalkingRunning))?
            .sumQuantity()?.doubleValue(for: .meter())
        activeCalories = workout.statistics(for: HKQuantityType(.activeEnergyBurned))?
            .sumQuantity()?.doubleValue(for: .kilocalorie())
    }

    private func readMetadata(from workout: HKWorkout) {
        if let ascended = workout.metadata?[HKMetadataKeyElevationAscended] as? HKQuantity {
            elevationGain = ascended.doubleValue(for: .meter())
        }
        if let temperature = workout.metadata?[HKMetadataKeyWeatherTemperature] as? HKQuantity,
           let humidity = workout.metadata?[HKMetadataKeyWeatherHumidity] as? HKQuantity {
            weather = WeatherSnapshot(
                temperatureCelsius: temperature.doubleValue(for: .degreeCelsius()),
                relativeHumidity: humidity.doubleValue(for: .percent()),
                dewPointCelsius: workout.metadata?[MetadataKey.dewPointCelsius] as? Double
            )
        }
    }

    private func loadHeartRate(for workout: HKWorkout) async -> [(elapsed: TimeInterval, bpm: Int)] {
        await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForObjects(from: workout)
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            let query = HKSampleQuery(
                sampleType: HKQuantityType(.heartRate),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, samples, _ in
                let unit = HKUnit.count().unitDivided(by: .minute())
                let mapped = (samples as? [HKQuantitySample] ?? []).map {
                    (
                        elapsed: $0.startDate.timeIntervalSince(workout.startDate),
                        bpm: Int($0.quantity.doubleValue(for: unit).rounded())
                    )
                }
                continuation.resume(returning: mapped)
            }
            store.execute(query)
        }
    }

    private func loadRoute(for workout: HKWorkout) async -> [CLLocation] {
        let routes: [HKWorkoutRoute] = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKSeriesType.workoutRoute(),
                predicate: HKQuery.predicateForObjects(from: workout),
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, _ in
                continuation.resume(returning: samples as? [HKWorkoutRoute] ?? [])
            }
            store.execute(query)
        }

        var all: [CLLocation] = []
        for route in routes {
            all += await locations(in: route)
        }
        return all.sorted { $0.timestamp < $1.timestamp }
    }

    /// Route data arrives in batches rather than all at once, so this collects until the
    /// query reports it's done.
    private func locations(in route: HKWorkoutRoute) async -> [CLLocation] {
        await withCheckedContinuation { continuation in
            var collected: [CLLocation] = []
            var resumed = false
            let query = HKWorkoutRouteQuery(route: route) { _, batch, done, _ in
                collected += batch ?? []
                if done, !resumed {
                    resumed = true
                    continuation.resume(returning: collected)
                }
            }
            store.execute(query)
        }
    }

    private func loadEffortScore(for workout: HKWorkout) async -> Double? {
        await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKQuantityType(.workoutEffortScore),
                predicate: HKQuery.predicateForWorkoutEffortSamplesRelated(workout: workout, activity: nil),
                limit: 1,
                sortDescriptors: nil
            ) { _, samples, _ in
                let value = (samples as? [HKQuantitySample])?.first?
                    .quantity.doubleValue(for: .appleEffortScore())
                continuation.resume(returning: value)
            }
            store.execute(query)
        }
    }

    // MARK: Writing

    /// Saves perceived effort as a native Health type and relates it to the run, so it
    /// travels with the workout instead of being locked inside this app.
    func saveEffort(_ score: Double, for workout: HKWorkout) async {
        let type = HKQuantityType(.workoutEffortScore)
        let sample = HKQuantitySample(
            type: type,
            quantity: HKQuantity(unit: .appleEffortScore(), doubleValue: score),
            start: workout.startDate,
            end: workout.endDate
        )

        do {
            try await store.save(sample)
            try await store.relateWorkoutEffortSample(sample, with: workout, activity: nil)
            effortScore = score
        } catch {
            // Effort is a nicety; a failure here shouldn't disturb the rest of the screen.
        }
    }
}
