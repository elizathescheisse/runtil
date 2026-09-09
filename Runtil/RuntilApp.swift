import SwiftUI
import RuntilCore

@main
struct RuntilApp: App {
    @State private var library = PlanLibrary()
    @State private var runController = PhoneWorkoutController()
    /// Created at launch, not lazily: the phone can be woken in the background purely to
    /// receive a mirrored session, and the handler has to already be in place when it is.
    @State private var mirror = MirroredWorkoutObserver()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TabView {
                PhoneRunView(library: library, controller: runController, mirror: mirror)
                    .tabItem { Label("Run", systemImage: "figure.run") }
                PlanLibraryView(library: library)
                    .tabItem { Label("Plans", systemImage: "list.bullet") }
                HistoryView(zones: library.plans.first?.zones ?? .estimated(age: 35))
                    .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            }
            // Zones come from Health on first launch rather than waiting to be corrected.
            // A wrong Zone 2 isn't cosmetic — it's training in the wrong range unaware.
            .task { await library.applyHealthProfileIfNeeded() }
            // Coming back to the foreground is the reliable moment to catch up a push
            // that couldn't be delivered earlier.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { library.push() }
            }
        }
    }
}
