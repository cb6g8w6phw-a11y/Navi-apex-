import ActivityKit
import Foundation

/**
 * Puts the trip in the Dynamic Island and on the lock screen (a Live Activity). It starts with the
 * first position of a trip, is refreshed as the next turn, distance or warning change (at most
 * every couple of seconds, which is what iOS allows) and ends with the trip.
 */
@MainActor
final class LiveNav {
    static let shared = LiveNav()

    private var activity: Activity<NavActivityAttributes>?
    private var lastState: NavActivityAttributes.ContentState?
    private var lastSent = Date.distantPast
    private weak var pending: Navigator?
    private var flushScheduled = false

    /** The trip changed. The update itself waits for the end of the current change, so it sees all of it. */
    func poke(_ nav: Navigator) {
        guard !nav.isStopped else { return }
        pending = nav
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            if let n = self.pending { self.push(n) }
        }
    }

    private func push(_ nav: Navigator) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = Self.state(from: nav)
        if state == lastState { return }
        let changedLook = lastState == nil || lastState?.symbol != state.symbol || lastState?.street != state.street
            || lastState?.alert != state.alert || lastState?.arrived != state.arrived || lastState?.rerouting != state.rerouting
        if !changedLook, Date().timeIntervalSince(lastSent) < 2.5 { return }
        lastState = state
        lastSent = Date()
        let content = ActivityContent(state: state, staleDate: nil)
        if let a = activity {
            Task { await a.update(content) }
        } else {
            do {
                activity = try Activity.request(attributes: NavActivityAttributes(destination: nav.destination.name),
                                                content: content, pushType: nil)
            } catch {
                // Live Activities are off for this app, or too many are running: the trip goes on without one.
            }
        }
    }

    /** The trip is over: take it off the island. */
    func end() {
        let a = activity
        activity = nil
        lastState = nil
        pending = nil
        guard let a else { return }
        let last = a.content.state
        Task { await a.end(ActivityContent(state: last, staleDate: nil), dismissalPolicy: .immediate) }
    }

    /** At launch: anything left from a trip the app didn't get to end (it was killed) goes away. */
    func endLeftovers() {
        for a in Activity<NavActivityAttributes>.activities where a.id != activity?.id {
            let last = a.content.state
            Task { await a.end(ActivityContent(state: last, staleDate: nil), dismissalPolicy: .immediate) }
        }
    }

    private static func state(from nav: Navigator) -> NavActivityAttributes.ContentState {
        let m = nav.nextManeuver
        let p = nav.progress
        let headline = InstructionBanner.headline(m)
        let street = m?.road ?? InstructionBanner.split(headline)?.1 ?? headline
        let left = p?.remainingSeconds ?? nav.route.durationSeconds
        let leftMeters = p?.remainingMeters ?? nav.route.distanceMeters

        var alert: String?
        var kind: String?
        if let r = nav.roadAhead {
            let name: String
            switch r.event.kind {
            case .roadworks: name = "Roadworks"
            case .closure: name = "Road closed"
            case .warning: name = "Warning"
            }
            alert = "\(name) · " + (r.left.map { "\(Fmt.distance($0)) left" } ?? Fmt.distance(r.meters))
            switch r.event.kind {
            case .roadworks: kind = "roadworks"
            case .closure: kind = "closure"
            case .warning: kind = "warning"
            }
        } else if let c = nav.cameraAhead {
            alert = (c.kind == .speed ? "Speed camera" : "Camera") + " · " + Fmt.distance(c.meters)
            kind = "camera"
        }

        return NavActivityAttributes.ContentState(
            symbol: nav.arrived ? "mappin.circle.fill" : maneuverSymbol(m?.type ?? .straight),
            distance: nav.arrived ? "Arrived" : Fmt.distance(p?.distanceToNext ?? 0),
            street: nav.arrived ? nav.destination.name : street,
            arrival: Fmt.arrival(left),
            remaining: Fmt.duration(left),
            remainingDistance: Fmt.distance(leftMeters),
            speedKmh: Int((nav.speedMps * 3.6).rounded()),
            limitKmh: nav.speedLimitKmh.map { Int($0.rounded()) },
            alert: alert,
            alertKind: kind,
            rerouting: nav.rerouting,
            arrived: nav.arrived
        )
    }
}
