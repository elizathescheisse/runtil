import AppIntents
import Observation
import RuntilCore

/// Carries a "start this plan" request from a Siri intent or a complication tap into the UI.
///
/// The intent runs in the app's own process (`openAppWhenRun`), so a shared observable is
/// enough — no cross-process plumbing, and no App Group, which free provisioning wouldn't
/// give us anyway.
@MainActor
@Observable
final class LaunchCoordinator {
    static let shared = LaunchCoordinator()

    /// Set when something outside the UI asks for a run. The plan list watches this and
    /// starts the matching plan.
    var requestedPlanID: UUID?
    /// Set when the request named no particular plan — just open and let her choose.
    var requestedPlanList = false

    private init() {}

    func requestRun(planID: UUID?) {
        if let planID {
            requestedPlanID = planID
        } else {
            requestedPlanList = true
        }
    }

    func clear() {
        requestedPlanID = nil
        requestedPlanList = false
    }
}

/// "Hey Siri, start a Zone 2 run with runtil."
struct StartRunIntent: AppIntent {
    static let title: LocalizedStringResource = "Start a run"
    static let description = IntentDescription("Starts a coached run with haptic cues.")

    /// The run needs the watch app frontmost to take the workout session and play haptics,
    /// so the intent brings the app up rather than trying to work headless.
    static let openAppWhenRun = true

    @Parameter(title: "Plan")
    var plan: PlanEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Start a \(\.$plan) run")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        LaunchCoordinator.shared.requestRun(planID: plan?.id)
        return .result()
    }
}

struct RuntilShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRunIntent(),
            phrases: [
                "Start a run with \(.applicationName)",
                "Start a \(.applicationName) run",
                "Begin a run with \(.applicationName)",
                "Go for a run with \(.applicationName)"
            ],
            shortTitle: "Start a run",
            systemImageName: "figure.run"
        )
    }
}
