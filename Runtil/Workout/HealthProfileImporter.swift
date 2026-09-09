import Foundation
import HealthKit
import Observation
import RuntilCore

/// Reads what Health already knows about you, so zones don't have to start as a guess.
///
/// Two of the three inputs are there for the asking. The third isn't: HealthKit has no
/// maximum heart rate type at all, so it's taken from the highest rate you've actually
/// recorded — which beats an age formula anyway, since those carry ±10–12 bpm of
/// individual variation and a real observation carries none.
@MainActor
@Observable
final class HealthProfileImporter {

    struct Profile: Equatable {
        var age: Int?
        var restingHeartRate: Int?
        /// Highest heart rate seen in the last year.
        var observedMaxHeartRate: Int?
        var observedOn: Date?

        var hasAnything: Bool {
            age != nil || restingHeartRate != nil || observedMaxHeartRate != nil
        }

        /// Best available max: what you've actually hit, else estimated from real age.
        var bestMaxHeartRate: Int? {
            if let observed = observedMaxHeartRate { return observed }
            if let age { return HeartRateZones.tanakaMaxHR(age: age) }
            return nil
        }
    }

    private(set) var profile = Profile()
    private(set) var isLoading = false
    private(set) var hasLoaded = false

    private let store = HKHealthStore()

    static var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [
            HKQuantityType(.heartRate),
            HKQuantityType(.restingHeartRate)
        ]
        if let dob = HKObjectType.characteristicType(forIdentifier: .dateOfBirth) {
            types.insert(dob)
        }
        return types
    }

    func load() async {
        guard HKHealthStore.isHealthDataAvailable() else { hasLoaded = true; return }
        isLoading = true
        defer { isLoading = false; hasLoaded = true }

        try? await store.requestAuthorization(toShare: [], read: Self.readTypes)

        var found = Profile()
        found.age = readAge()
        found.restingHeartRate = await readMostRecentResting()
        let observed = await readObservedMax()
        found.observedMaxHeartRate = observed?.bpm
        found.observedOn = observed?.date
        profile = found
    }

    /// Date of birth is a characteristic rather than a sample, so it reads synchronously
    /// and throws rather than returning empty when access isn't granted.
    private func readAge() -> Int? {
        guard let components = try? store.dateOfBirthComponents(),
              let birthDate = Calendar.current.date(from: components)
        else { return nil }
        let years = Calendar.current.dateComponents([.year], from: birthDate, to: Date()).year
        guard let years, (10...100).contains(years) else { return nil }
        return years
    }

    private func readMostRecentResting() async -> Int? {
        await withCheckedContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
            let query = HKSampleQuery(
                sampleType: HKQuantityType(.restingHeartRate),
                predicate: nil,
                limit: 1,
                sortDescriptors: [sort]
            ) { _, samples, _ in
                let unit = HKUnit.count().unitDivided(by: .minute())
                let value = (samples as? [HKQuantitySample])?.first
                    .map { Int($0.quantity.doubleValue(for: unit).rounded()) }
                continuation.resume(returning: value)
            }
            store.execute(query)
        }
    }

    /// Highest heart rate in the last year.
    ///
    /// A year rather than all time: max heart rate drifts down with age, and a reading
    /// from five years ago would set a ceiling you can no longer reach. This is a *floor*
    /// on your true maximum — you can only observe what you've actually hit — so it's
    /// offered as a starting point rather than presented as fact.
    private func readObservedMax() async -> (bpm: Int, date: Date)? {
        await withCheckedContinuation { continuation in
            let start = Calendar.current.date(byAdding: .year, value: -1, to: Date())
            let predicate = HKQuery.predicateForSamples(withStart: start, end: Date())
            let query = HKStatisticsQuery(
                quantityType: HKQuantityType(.heartRate),
                quantitySamplePredicate: predicate,
                options: .discreteMax
            ) { _, statistics, _ in
                let unit = HKUnit.count().unitDivided(by: .minute())
                guard let quantity = statistics?.maximumQuantity() else {
                    continuation.resume(returning: nil)
                    return
                }
                let bpm = Int(quantity.doubleValue(for: unit).rounded())
                // Optical sensors throw occasional wild readings; anything past 220 is
                // an artefact, not a heart rate.
                guard (100...220).contains(bpm) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: (bpm, statistics?.endDate ?? Date()))
            }
            store.execute(query)
        }
    }
}
