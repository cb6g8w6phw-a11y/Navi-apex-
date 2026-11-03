import AppIntents
import SwiftUI

/** What a Siri or Shortcuts request asked the app to do once it's open. */
@MainActor
final class LaunchAction: ObservableObject {
    enum Kind: String { case home, work, car }
    static let shared = LaunchAction()
    @Published var pending: Kind?
}

struct DirectionsHomeIntent: AppIntent {
    static var title: LocalizedStringResource = "Directions home"
    static var description = IntentDescription("Opens Apex with directions to your home.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        LaunchAction.shared.pending = .home
        return .result()
    }
}

struct DirectionsWorkIntent: AppIntent {
    static var title: LocalizedStringResource = "Directions to work"
    static var description = IntentDescription("Opens Apex with directions to work.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        LaunchAction.shared.pending = .work
        return .result()
    }
}

struct FindMyCarIntent: AppIntent {
    static var title: LocalizedStringResource = "Find my car"
    static var description = IntentDescription("Opens Apex with the way back to where you parked.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        LaunchAction.shared.pending = .car
        return .result()
    }
}

/** "Hey Siri, take me home with Apex", also in Spotlight and the Shortcuts app. */
struct VelaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: DirectionsHomeIntent(), phrases: [
            "Take me home with \(.applicationName)",
            "\(.applicationName) directions home",
        ])
        AppShortcut(intent: DirectionsWorkIntent(), phrases: [
            "Take me to work with \(.applicationName)",
            "\(.applicationName) directions to work",
        ])
        AppShortcut(intent: FindMyCarIntent(), phrases: [
            "Find my car with \(.applicationName)",
            "Where did I park in \(.applicationName)",
        ])
    }
}
