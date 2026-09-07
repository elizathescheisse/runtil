import SwiftUI

@main
struct RuntilWatchApp: App {
    @State private var store = PlanStore()
    @State private var controller = WorkoutController()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                PlanListView(store: store, controller: controller)
            }
        }
    }
}
