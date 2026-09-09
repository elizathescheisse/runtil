import SwiftUI

@main
struct RuntilApp: App {
    @State private var library = PlanLibrary()
    @State private var runController = PhoneWorkoutController()

    var body: some Scene {
        WindowGroup {
            TabView {
                PhoneRunView(library: library, controller: runController)
                    .tabItem { Label("Run", systemImage: "figure.run") }
                PlanLibraryView(library: library)
                    .tabItem { Label("Plans", systemImage: "list.bullet") }
                HistoryView(zones: library.plans.first?.zones ?? .estimated(age: 35))
                    .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            }
        }
    }
}
