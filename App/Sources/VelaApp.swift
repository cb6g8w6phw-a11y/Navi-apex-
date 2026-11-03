import SwiftUI

@main
struct VelaApp: App {
    init() {
        WazeWeb.install()
        Task { @MainActor in LiveNav.shared.endLeftovers() }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
