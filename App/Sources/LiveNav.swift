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
            || lastState?.routeTitle != state.routeTitle || lastState?.muted != state.muted || lastState?.limitKmh != state.limitKmh
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
        let m = Self.turn(nav)
        let p = nav.progress
        let headline = InstructionBanner.headline(m.maneuver)
        let street = m.maneuver?.road ?? InstructionBanner.split(headline)?.1 ?? headline
        let left = p?.remainingSeconds ?? nav.route.durationSeconds
        let leftMeters = p?.remainingMeters ?? nav.route.distanceMeters

        var alert: String?
        var kind: String?
        if let c = nav.cameraAhead {
            let lim = c.limitKmh.map { " \(Int($0.rounded())) km/h" } ?? ""
            alert = "Fotoradar\(lim) za \(Fmt.distance(c.meters))"
            kind = "camera"
        } else if let r = nav.roadAhead {
            let name: String
            switch r.event.kind {
            case .roadworks: name = "Roboty"
            case .closure: name = "Droga zamknięta"
            case .warning: name = "Uwaga"
            }
            alert = "\(name) · " + (r.left.map { "zostało \(Fmt.distance($0))" } ?? "za \(Fmt.distance(r.meters))")
            switch r.event.kind {
            case .roadworks: kind = "roadworks"
            case .closure: kind = "closure"
            case .warning: kind = "warning"
            }
        }

        let refs = Self.routeRefs(nav)
        let title = refs.isEmpty ? (nav.currentRoad ?? nav.route.summary ?? "trasa") : refs.prefix(2).joined(separator: " / ")
        let place = nav.destination.name.split(separator: ",").first.map(String.init) ?? nav.destination.name

        return NavActivityAttributes.ContentState(
            symbol: nav.arrived ? "mappin.circle.fill" : maneuverSymbol(m.maneuver?.type ?? .straight),
            distance: nav.arrived ? L.t("Na miejscu", "Angekommen", "Arrived") : L.t("Za \(Fmt.distance(m.meters))", "In \(Fmt.distance(m.meters))", "In \(Fmt.distance(m.meters))"),
            street: nav.arrived ? nav.destination.name : (m.maneuver?.instruction ?? street),
            arrival: Fmt.arrival(left),
            remaining: Fmt.duration(left),
            remainingDistance: Fmt.distance(leftMeters),
            speedKmh: Int((nav.speedMps * 3.6).rounded()),
            limitKmh: nav.speedLimitKmh.map { Int($0.rounded()) },
            alert: alert,
            alertKind: kind,
            rerouting: nav.rerouting,
            arrived: nav.arrived,
            routeTitle: title,
            routeLine: "→ \(place)",
            muted: nav.muted
        )
    }

    /** The next real turn, not a "keep going". Distance is how far that turn is. */
    private static func turn(_ nav: Navigator) -> (maneuver: Maneuver?, meters: Double) {
        let along = nav.progress?.alongMeters ?? 0
        let list = nav.route.maneuvers
        let start = nav.progress?.nextIndex ?? 0
        if start < list.count, let m = list[start...].first(where: { isTurn($0.type) }) {
            return (m, max(0, m.alongMeters - along))
        }
        return (nav.nextManeuver, nav.progress?.distanceToNext ?? 0)
    }

    private static func isTurn(_ t: ManeuverType) -> Bool {
        switch t {
        case .straight, .depart, .unknown, .arrive: return false
        default: return true
        }
    }

    /** A2, E30, DK92 — the numbers worth putting in the island title. */
    private static func routeRefs(_ nav: Navigator) -> [String] {
        let blob = ([nav.route.summary, nav.currentRoad].compactMap { $0 }
                    + nav.route.maneuvers.prefix(16).flatMap { [$0.road ?? "", $0.instruction] })
            .joined(separator: " ")
        var refs = RoadRefs.find(blob)
        if let re = try? NSRegularExpression(pattern: #"\b(DK|S)\s?-?\s?(\d{1,3})\b"#) {
            let ns = blob as NSString
            for m in re.matches(in: blob, range: NSRange(location: 0, length: ns.length)) {
                let ref = ns.substring(with: m.range(at: 1)) + ns.substring(with: m.range(at: 2))
                if !refs.contains(ref) { refs.append(ref) }
            }
        }
        return refs
    }
}
