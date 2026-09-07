import SwiftUI

@main
struct RuntilApp: App {
    @State private var library = PlanLibrary()

    var body: some Scene {
        WindowGroup {
            TabView {
                PlanLibraryView(library: library)
                    .tabItem { Label("Plans", systemImage: "list.bullet") }
                HistoryView()
                    .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            }
        }
    }
}
