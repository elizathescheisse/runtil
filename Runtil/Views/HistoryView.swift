import SwiftUI
import HealthKit
import RuntilCore

/// Past runs, read back from HealthKit.
///
/// The watch saves every session as a real `HKWorkout`, so this reads the same store the
/// Fitness app does rather than keeping a private copy that could drift out of sync.
struct HistoryView: View {
    @State private var workouts: [HKWorkout] = []
    @State private var status: Status = .loading

    enum Status: Equatable {
        case loading
        case ready
        case denied
        case failed(String)
    }

    private let store = HKHealthStore()

    var body: some View {
        NavigationStack {
            Group {
                switch status {
                case .loading:
                    ProgressView()
                case .denied:
                    ContentUnavailableView(
                        "No access to Health",
                        systemImage: "heart.text.square",
                        description: Text("Allow runtil to read workouts in Settings › Health › Data Access.")
                    )
                case .failed(let message):
                    ContentUnavailableView("Couldn't load runs", systemImage: "exclamationmark.triangle", description: Text(message))
                case .ready where workouts.isEmpty:
                    ContentUnavailableView(
                        "No runs yet",
                        systemImage: "figure.run",
                        description: Text("Start a plan from your watch and it'll show up here.")
                    )
                case .ready:
                    List(workouts, id: \.uuid) { workout in
                        WorkoutRow(workout: workout)
                    }
                }
            }
            .navigationTitle("History")
            .task { await load() }
            .refreshable { await load() }
        }
    }

    private func load() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            status = .failed("Health data isn't available on this device.")
            return
        }
        do {
            try await store.requestAuthorization(toShare: [], read: [HKObjectType.workoutType()])
            workouts = try await fetchRuns()
            status = .ready
        } catch {
            status = .denied
        }
    }

    private func fetchRuns() async throws -> [HKWorkout] {
        try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForWorkouts(with: .running)
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
            let query = HKSampleQuery(
                sampleType: .workoutType(),
                predicate: predicate,
                limit: 50,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (samples as? [HKWorkout]) ?? [])
                }
            }
            store.execute(query)
        }
    }
}

private struct WorkoutRow: View {
    let workout: HKWorkout

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(workout.startDate.formatted(date: .abbreviated, time: .shortened))
                .font(.headline)
            HStack(spacing: 12) {
                Label(Format.duration(workout.duration), systemImage: "clock")
                if let meters = distanceMeters {
                    Label(Format.distance(meters: meters, unit: .miles), systemImage: "figure.run")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var distanceMeters: Double? {
        workout.statistics(for: HKQuantityType(.distanceWalkingRunning))?
            .sumQuantity()?
            .doubleValue(for: .meter())
    }
}
