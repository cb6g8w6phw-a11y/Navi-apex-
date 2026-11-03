import Foundation

/**
 * Follows the driver along a route: snaps each GPS fix to the line, says how far the next
 * maneuver is, how much trip is left, and when the driver has left the route.
 */
public final class RouteTracker {
    public struct Progress: Sendable {
        public var snapped: LatLng
        public var alongMeters: Double
        /** How far the fix is from the line. */
        public var offsetMeters: Double
        /** Bearing of the route at the snapped point. */
        public var routeBearing: Double
        public var nextIndex: Int?
        public var distanceToNext: Double
        public var remainingMeters: Double
        public var remainingSeconds: Double
        public var offRoute: Bool
        public var arrived: Bool
    }

    public let route: Route
    private let cum: [Double]
    private let total: Double
    private var segment = 0
    private var offCount = 0
    private var wrongWayCount = 0

    public init(route: Route) {
        self.route = route
        cum = Geo.cumulative(route.polyline)
        total = cum.last ?? 0
    }

    /**
     * [heading] is the way the car is moving (degrees from north), only when it's moving fast enough
     * for the phone's compass course to mean something.
     */
    public func update(_ fix: LatLng, accuracy: Double = 10, heading: Double? = nil) -> Progress {
        let line = route.polyline
        // Look near the last match first (cheap, and avoids jumping to a parallel leg of the route),
        // then the whole line if nothing near fits.
        var best = nearest(fix, from: max(0, segment - 3), to: min(line.count - 2, segment + 40))
        if best.dist > 60 {
            let all = nearest(fix, from: 0, to: line.count - 2)
            if all.dist < best.dist - 15 { best = all }
        }
        segment = best.seg
        let along = cum[best.seg] + best.t * (cum[best.seg + 1] - cum[best.seg])
        let snapped = LatLng(line[best.seg].lat + (line[best.seg + 1].lat - line[best.seg].lat) * best.t,
                             line[best.seg].lng + (line[best.seg + 1].lng - line[best.seg].lng) * best.t)
        let limit = max(40, min(accuracy, 60) + 25)
        // Well clear of the route counts double, so a wrong turn is noticed in a couple of seconds.
        offCount = best.dist > limit * 2 ? offCount + 2 : (best.dist > limit ? offCount + 1 : 0)
        let routeBearing = Geo.bearing(line[best.seg], line[best.seg + 1])
        // The road's way over about 30 m, so a tiny kink or doubled point in the line isn't "backwards".
        let a = Geo.point(along: line, meters: max(0, along - 10), cumulative: cum)
        let b = Geo.point(along: line, meters: min(total, along + 20), cumulative: cum)
        let roadBearing = a.distance(to: b) > 5 ? Geo.bearing(a, b) : routeBearing
        // On the route's road but driving back along it (after turning round, or snapped onto the
        // route the wrong way): that's off the route too, or it would never reroute.
        if let heading, best.dist <= limit {
            let diff = abs((heading - roadBearing + 540).truncatingRemainder(dividingBy: 360) - 180)
            wrongWayCount = diff > 120 ? wrongWayCount + 1 : 0
        } else {
            wrongWayCount = 0
        }
        let next = route.maneuvers.firstIndex { !$0.silent && $0.alongMeters > along + 8 }
        let toNext = next.map { route.maneuvers[$0].alongMeters - along } ?? (total - along)
        let remaining = max(0, total - along)
        return Progress(
            snapped: snapped,
            alongMeters: along,
            offsetMeters: best.dist,
            routeBearing: routeBearing,
            nextIndex: next,
            distanceToNext: max(0, toNext),
            remainingMeters: remaining,
            remainingSeconds: total > 0 ? route.durationSeconds * remaining / total : 0,
            offRoute: offCount >= 3 || wrongWayCount >= 4,
            // Only on the road to it: passing close by on a parallel street isn't arriving.
            arrived: remaining < 25 && best.dist < limit
        )
    }

    private func nearest(_ p: LatLng, from: Int, to: Int) -> (seg: Int, t: Double, dist: Double) {
        let line = route.polyline
        guard line.count >= 2, from <= to else { return (0, 0, .greatestFiniteMagnitude) }
        let k = cos(p.lat * .pi / 180) * 111_320.0
        var best = (seg: from, t: 0.0, dist: Double.greatestFiniteMagnitude)
        for i in from...to {
            let a = line[i], b = line[i + 1]
            let ax = (a.lng - p.lng) * k, ay = (a.lat - p.lat) * 110_540
            let bx = (b.lng - p.lng) * k, by = (b.lat - p.lat) * 110_540
            let dx = bx - ax, dy = by - ay
            let len2 = dx * dx + dy * dy
            let t = len2 > 0 ? min(max(-(ax * dx + ay * dy) / len2, 0), 1) : 0
            let x = ax + t * dx, y = ay + t * dy
            let d = (x * x + y * y).squareRoot()
            if d < best.dist { best = (i, t, d) }
        }
        return best
    }
}
