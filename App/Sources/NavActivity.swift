import ActivityKit
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
        /** A warning ahead ("Roadworks · 2.4 km") and which kind: roadworks, closure, warning, camera. */
        var alert: String?
        var alertKind: String?
        var rerouting: Bool
        var arrived: Bool
    }

    var destination: String
}
