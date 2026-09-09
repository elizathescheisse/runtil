import Foundation
import HealthKit
import Observation
import WatchConnectivity
import RuntilCore

/// Receives a run happening on the watch.
///
/// The watch owns everything that matters — the session, the sensors, the cues — and sends
/// a snapshot once a second. This is a display, so it never blocks anything and never
/// pretends to be authoritative.
///
/// Per Apple's docs the handler must be assigned "promptly after your app is launched",
/// because the phone app can be woken in the background specifically to receive this.
@MainActor
@Observable
final class MirroredWorkoutObserver: NSObject {

    enum Availability: Equatable {
        case ready
        case noPairedWatch
        case watchAppNotInstalled
        case healthUnavailable

        var explanation: String? {
            switch self {
            case .ready: return nil
            case .noPairedWatch:
                return "Pair an Apple Watch to see heart-rate runs here while they happen."
            case .watchAppNotInstalled:
                return "Install runtil on your Apple Watch to run heart-rate plans and see them here live."
            case .healthUnavailable:
                return "Health data isn't available on this device."
            }
        }
    }

    private(set) var state: MirroredState?
    private(set) var isActive = false
    private(set) var availability: Availability = .ready

    private let store = HKHealthStore()
    private var session: HKWorkoutSession?

    override init() {
        super.init()
        checkAvailability()
        beginObserving()
    }

    /// What the phone can actually offer, so the UI explains the real situation rather
    /// than a version number.
    ///
    /// Note there's no OS version check here: mirroring needs iOS 17 / watchOS 10, but
    /// runtil already requires iOS 18 / watchOS 11, so any device that can run this app
    /// can mirror. What genuinely varies is whether there's a watch and whether the watch
    /// app is installed.
    private func checkAvailability() {
        guard HKHealthStore.isHealthDataAvailable() else {
            availability = .healthUnavailable
            return
        }
        availability = WatchPairing.current()
    }

    func refreshAvailability() {
        checkAvailability()
    }

    private func beginObserving() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        store.workoutSessionMirroringStartHandler = { [weak self] mirrored in
            Task { @MainActor in
                self?.attach(to: mirrored)
            }
        }
    }

    private func attach(to mirrored: HKWorkoutSession) {
        session = mirrored
        mirrored.delegate = self
        isActive = true
    }
}

// MARK: - HKWorkoutSessionDelegate

extension MirroredWorkoutObserver: HKWorkoutSessionDelegate {

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        guard toState == .ended || toState == .stopped else { return }
        Task { @MainActor in self.finish() }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in self.finish() }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didReceiveDataFromRemoteWorkoutSession data: [Data]
    ) {
        // Batched delivery is possible, and only the newest snapshot is worth showing —
        // this is a live readout, not a log.
        guard let newest = data.compactMap(MirroredState.decoded(from:)).last else { return }
        Task { @MainActor in
            self.state = newest
            self.isActive = !newest.isFinished
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didDisconnectFromRemoteDeviceWithError error: Error?
    ) {
        Task { @MainActor in self.finish() }
    }

    @MainActor
    private func finish() {
        isActive = false
        session = nil
        // The last snapshot is kept so the screen doesn't blank the instant a run ends.
    }

    @MainActor
    func dismiss() {
        state = nil
        isActive = false
    }
}

/// Whether there's a watch to mirror from, and whether it has runtil on it.
///
/// These read as unknown until `WCSession` finishes activating, which `PlanLibrary`
/// already does at launch — so the answer is treated as optimistic before then rather than
/// telling someone to install an app they already have.
enum WatchPairing {
    static func current() -> MirroredWorkoutObserver.Availability {
        guard WCSession.isSupported() else { return .noPairedWatch }
        let session = WCSession.default
        guard session.activationState == .activated else { return .ready }
        guard session.isPaired else { return .noPairedWatch }
        guard session.isWatchAppInstalled else { return .watchAppNotInstalled }
        return .ready
    }
}
