import Foundation

/**
 * How likely police are on the road ahead, 0 to 100: past Waze police reports near the next few
 * kilometres (counting most those made at this time of day and lately), plus live ones.
 */
public enum PoliceRisk {
    public enum Level: String, Sendable { case low, medium, high }

    public struct Report: Sendable {
        public var location: LatLng
        public var time: Date
        public init(_ location: LatLng, _ time: Date) {
            self.location = location
            self.time = time
        }
    }

    public static func level(_ score: Int) -> Level {
        score >= 60 ? .high : score >= 30 ? .medium : .low
    }

    /**
     * [ahead] is the road still to drive (a few km of it), [past] the reports remembered on the
     * phone, [live] police reported right now on that stretch.
     */
    public static func score(ahead: [LatLng], past: [Report], live: Int, now: Date = Date(),
                             radius: Double = 400, calendar: Calendar = .current) -> Int {
        guard ahead.count >= 2 else { return live > 0 ? 70 : 0 }
        let cum = Geo.cumulative(ahead)
        let lats = ahead.map(\.lat), lngs = ahead.map(\.lng)
        let pad = radius / 111_000 * 1.5
        let s = lats.min()! - pad, n = lats.max()! + pad
        let padLng = pad / max(cos(lats[0] * .pi / 180), 0.2)
        let w = lngs.min()! - padLng, e = lngs.max()! + padLng
        let hour = calendar.component(.hour, from: now)
        let weekend = calendar.isDateInWeekend(now)
        var weight = 0.0
        for r in past where r.location.lat >= s && r.location.lat <= n && r.location.lng >= w && r.location.lng <= e {
            guard Geo.project(r.location, on: ahead, cumulative: cum).offset <= radius else { continue }
            let days = max(now.timeIntervalSince(r.time) / 86_400, 0)
            // Half as much for every month that has gone by.
            var x = pow(0.5, days / 30)
            let h = calendar.component(.hour, from: r.time)
            let dh = min(abs(h - hour), 24 - abs(h - hour))
            x *= dh <= 1 ? 1.5 : dh <= 3 ? 1 : 0.5
            if calendar.isDateInWeekend(r.time) == weekend { x *= 1.2 }
            weight += x
        }
        // A handful of past reports makes it medium; live ones push it right up.
        let fromPast = 1 - exp(-weight / 4)
        let fromLive = 1 - pow(0.3, Double(live))
        let combined = 1 - (1 - fromPast * 0.8) * (1 - fromLive * 0.95)
        return Int((combined * 100).rounded())
    }
}
