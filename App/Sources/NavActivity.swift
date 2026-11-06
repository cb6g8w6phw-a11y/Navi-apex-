import ActivityKit
import AppIntents
import Foundation

/**
 * What the Dynamic Island and the lock screen show while a trip is on. The app and the widget
 * extension both compile this file, so everything is already text: the widget does no maths.
 */
struct NavActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /** SF Symbol of the next manoeuvre. */
        var symbol: String
        /** How far to it: "450 m". */
        var distance: String
        /** The road to turn onto, or the instruction. */
        var street: String
        /** Arrival clock time: "20:55". */
        var arrival: String
        /** Time left: "24 min". */
        var remaining: String
        /** Distance left: "30 km". */
        var remainingDistance: String
        var speedKmh: Int
        var limitKmh: Int?
        /** A warning ahead ("Fotoradar 120 km/h za 450 m") and which kind: roadworks, closure, warning, camera. */
        var alert: String?
        var alertKind: String?
        var rerouting: Bool
        var arrived: Bool
        /** "A2 / E30" or the road under the car. */
        var routeTitle: String
        /** "→ Warszawa". */
        var routeLine: String
        var muted: Bool
    }

    var destination: String
}

extension Notification.Name {
    static let kiteEndTrip = Notification.Name("kite.endTrip")
    static let kiteMuteTrip = Notification.Name("kite.muteTrip")
}

/** Set from the island; the app reads it on the main thread (the intent may wake a background trip). */
enum TripCommand {
    static var end = false
    static var toggleMute = false

    static func requestEnd() {
        DispatchQueue.main.async {
            end = true
            NotificationCenter.default.post(name: .kiteEndTrip, object: nil)
        }
    }

    static func requestMute() {
        DispatchQueue.main.async {
            toggleMute = true
            NotificationCenter.default.post(name: .kiteMuteTrip, object: nil)
        }
    }
}

@available(iOS 17.0, *)
struct EndTripIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Zakończ nawigację"
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        TripCommand.requestEnd()
        return .result()
    }
}

@available(iOS 17.0, *)
struct MuteTripIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Wycisz"
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        TripCommand.requestMute()
        return .result()
    }
}
