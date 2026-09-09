import SwiftUI
import HealthKit
import RuntilCore

/// Past runs, read back from HealthKit.
///
/// The watch saves every session as a real `HKWorkout`, so this reads the same store the
/// Fitness app does rather than keeping a private copy that could drift out of sync.
struct HistoryView: View {
    /// Zones come from the library so the detail charts shade *your* Zone 2, not a default.
    let zones: HeartRateZones

    @Environment(\.scenePhase) private var scenePhase

    @State private var workouts: [HKWorkout] = []
    @State private var status: Status = .loading
    @State private var pendingDeletion: HKWorkout?
    @State private var deletionProblem: String?

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
                    List {
                        ForEach(workouts, id: \.uuid) { workout in
                            NavigationLink {
                                WorkoutDetailView(workout: workout, zones: zones)
                            } label: {
                                WorkoutRow(workout: workout)
                            }
                            .swipeActions(edge: .trailing) {
                                Button("Delete", role: .destructive) {
                                    pendingDeletion = workout
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("History")
            .task { await load() }
            .refreshable { await load() }
            // A run finished on the watch arrives while this tab is already open, so
            // reloading only on first appearance means it never shows up.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await load() } }
            }
            // Confirmed rather than immediate: this removes the run from Health itself,
            // not just from runtil, and there is no undo.
            .confirmationDialog(
                "Delete this run?",
                isPresented: Binding(
                    get: { pendingDeletion != nil },
                    set: { if !$0 { pendingDeletion = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete from Health", role: .destructive) {
                    if let workout = pendingDeletion {
                        Task { await delete(workout) }
                    }
                    pendingDeletion = nil
                }
                Button("Cancel", role: .cancel) { pendingDeletion = nil }
            } message: {
                Text("This removes the workout from Health permanently. It can't be undone.")
            }
            .alert(
                "Couldn't delete",
                isPresented: Binding(
                    get: { deletionProblem != nil },
                    set: { if !$0 { deletionProblem = nil } }
                )
            ) {
                Button("OK") { deletionProblem = nil }
            } message: {
                Text(deletionProblem ?? "")
            }
        }
    }

    private func load() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            status = .failed("Health data isn't available on this device.")
            return
        }
        do {
            try await store.requestAuthorization(
                toShare: [
                    HKQuantityType(.workoutEffortScore),
                    // Write access is what permits deletion, not just saving.
                    HKQuantityType.workoutType()
                ],
                read: [
                    HKObjectType.workoutType(),
                    HKQuantityType(.heartRate),
                    HKQuantityType(.distanceWalkingRunning),
                    HKQuantityType(.activeEnergyBurned),
                    HKQuantityType(.workoutEffortScore),
                    HKSeriesType.workoutRoute()
                ]
            )
            workouts = try await fetchRuns()
            status = .ready
        } catch {
            status = .denied
        }
    }

    /// Removes a workout from Health.
    ///
    /// HealthKit only permits deleting samples this app saved, which is exactly the set
    /// worth offering — a run recorded by another app isn't ours to remove, and the
    /// failure says so rather than appearing to work.
    private func delete(_ workout: HKWorkout) async {
        do {
            try await store.delete(workout)
            workouts.removeAll { $0.uuid == workout.uuid }
        } catch {
            deletionProblem = "runtil can only delete runs it recorded itself. This one was saved by another app."
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
