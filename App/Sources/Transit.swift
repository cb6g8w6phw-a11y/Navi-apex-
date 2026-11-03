import Foundation

/** One part of a transit trip: a walk, or a ride on one line between two stops. */
public struct TransitLeg: Hashable, Sendable {
    public var isWalk: Bool
    /** "SUBWAY", "BUS", "TRAM", "RAIL"…, as the planner names it. */
    public var mode: String
    /** The line's short name ("N", "38R"), empty for a walk. */
    public var line: String
    /** The agency's own colors, 0xRRGGBB, when it publishes them. */
    public var color: UInt32?
    public var textColor: UInt32?
    public var headsign: String?
    public var fromName: String
    public var toName: String
    public var depart: Date?
    public var arrive: Date?
    public var durationSeconds: Double
    public var distanceMeters: Double
    public var stops: Int
    /** Minutes late (or early, below zero) when the agency sends live times. */
    public var delayMinutes: Int?
    public var path: [LatLng]

    public init(isWalk: Bool, mode: String, line: String = "", color: UInt32? = nil, textColor: UInt32? = nil,
                headsign: String? = nil, fromName: String = "", toName: String = "", depart: Date? = nil,
                arrive: Date? = nil, durationSeconds: Double = 0, distanceMeters: Double = 0, stops: Int = 0,
                delayMinutes: Int? = nil, path: [LatLng] = []) {
        self.isWalk = isWalk; self.mode = mode; self.line = line; self.color = color; self.textColor = textColor
        self.headsign = headsign; self.fromName = fromName; self.toName = toName; self.depart = depart
        self.arrive = arrive; self.durationSeconds = durationSeconds; self.distanceMeters = distanceMeters
        self.stops = stops; self.delayMinutes = delayMinutes; self.path = path
    }

    /** What kind of vehicle, for an icon. */
    public var vehicle: Vehicle { Vehicle(mode) }

    public enum Vehicle: Sendable {
        case walk, bus, metro, tram, train, ferry, other
        init(_ mode: String) {
            switch mode {
            case "WALK", "BIKE", "CAR", "RENTAL": self = .walk
            case "BUS", "COACH", "ODM", "FLEX": self = .bus
            case "SUBWAY", "METRO": self = .metro
            case "TRAM", "CABLE_CAR", "FUNICULAR", "AERIAL_LIFT": self = .tram
            case "FERRY": self = .ferry
            default: self = mode.contains("RAIL") || mode == "SUBURBAN" || mode == "LONG_DISTANCE" ? .train : .other
            }
        }
    }
}

/** One way to get there by public transit. */
public struct TransitTrip: Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var depart: Date?
    public var arrive: Date?
    public var durationSeconds: Double
    public var transfers: Int
    public var legs: [TransitLeg]

    public init(depart: Date?, arrive: Date?, durationSeconds: Double, transfers: Int, legs: [TransitLeg]) {
        self.depart = depart; self.arrive = arrive; self.durationSeconds = durationSeconds
        self.transfers = transfers; self.legs = legs
    }

    public var rides: [TransitLeg] { legs.filter { !$0.isWalk } }
    public var walkSeconds: Double { legs.filter(\.isWalk).map(\.durationSeconds).reduce(0, +) }
    /** The whole trip's shape, for framing the map. */
    public var path: [LatLng] { legs.flatMap(\.path) }
}

/**
 * Public transit directions from Transitous (transitous.org), the community-run planner over
 * the world's open timetables that Vela uses: keyless, with live delays where agencies send them.
 */
public enum Transitous {
    public static let base = "https://api.transitous.org"

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 25
        c.httpAdditionalHeaders = ["User-Agent": "Vela-iOS (https://github.com/matteofx1/vela-ios)"]
        return URLSession(configuration: c)
    }()

    public static func planURL(from: LatLng, to: LatLng, max: Int = 5, time: Date? = nil, arriveBy: Bool = false) -> URL? {
        var s = "\(base)/api/v1/plan?fromPlace=\(from.lat),\(from.lng)&toPlace=\(to.lat),\(to.lng)&numItineraries=\(max)"
        if let time {
            let f = ISO8601DateFormatter()
            s += "&time=" + f.string(from: time)
            if arriveBy { s += "&arriveBy=true" }
        }
        return URL(string: s)
    }

    /** Trips leaving now, or around [time] (arriving by it when [arriveBy]). Throws on a network error. */
    public static func plan(from: LatLng, to: LatLng, time: Date? = nil, arriveBy: Bool = false) async throws -> [TransitTrip] {
        guard let url = planURL(from: from, to: to, time: time, arriveBy: arriveBy) else { return [] }
        let (data, resp) = try await session.data(from: url)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw URLError(.badServerResponse) }
        return parse(data)
    }

    /** One upcoming departure at a stop. */
    public struct Departure: Hashable, Sendable {
        public var line: String
        public var mode: String
        public var color: UInt32?
        public var textColor: UInt32?
        public var headsign: String
        public var time: Date
        /** Minutes late, when the agency sends live times. */
        public var delayMinutes: Int?
        public var vehicle: TransitLeg.Vehicle { TransitLeg.Vehicle(mode) }
    }

    /**
     * The departure board for the stop nearest [point] (within about [radius] meters), the way
     * Vela reads it: the stop's parent station, so every platform of a hub is on one board.
     * Nil when there is no stop or no service.
     */
    public static func departures(near point: LatLng, radius: Double = 150) async -> (stop: String, departures: [Departure])? {
        let dLat = radius / 111_320, dLng = radius / (111_320 * cos(point.lat * .pi / 180))
        guard let url = URL(string: "\(base)/api/v1/map/stops?min=\(point.lat - dLat),\(point.lng - dLng)&max=\(point.lat + dLat),\(point.lng + dLng)"),
              let (data, _) = try? await session.data(from: url),
              let stops = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let nearest = stops.compactMap { s -> (name: String, id: String, d: Double)? in
            guard let id = (s["parentId"] as? String) ?? (s["stopId"] as? String), let p = Self.point(s) else { return nil }
            return (s["name"] as? String ?? "", id, p.distance(to: point))
        }.sorted { $0.d < $1.d }
        guard let first = nearest.first else { return nil }
        // The two curbs of a street often are two stops with one name: show both on one board.
        let ids = Array(Set(nearest.filter { $0.name == first.name || $0.d - first.d < 25 }.map(\.id))).prefix(4)
        var all: [Departure] = []
        for id in ids {
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            guard let u = URL(string: "\(base)/api/v1/stoptimes?stopId=\(id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id)&n=30"),
                  let (d, _) = try? await session.data(from: u) else { continue }
            all += parseStopTimes(d, stopName: first.name)
        }
        guard !all.isEmpty else { return nil }
        var seen = Set<String>()
        let board = all.sorted { $0.time < $1.time }.filter { seen.insert("\($0.line)|\($0.headsign)|\($0.time.timeIntervalSince1970)").inserted }
        return (first.name, board)
    }

    public static func parseStopTimes(_ data: Data, stopName: String = "") -> [Departure] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["stopTimes"] as? [[String: Any]] else { return [] }
        return list.compactMap { st in
            let place = st["place"] as? [String: Any] ?? [:]
            if st["tripCancelled"] as? Bool == true || place["cancelled"] as? Bool == true { return nil }
            guard let time = date(place["departure"]) else { return nil }
            var delay: Int?
            if st["realTime"] as? Bool == true, let sched = date(place["scheduledDeparture"]) {
                delay = Int((time.timeIntervalSince(sched) / 60).rounded())
            }
            let line = [st["routeShortName"], st["displayName"], st["routeLongName"]]
                .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
            // Where the run ends. Some feeds put the stop's own name in the headsign, so the trip's
            // last stop wins; a run that ends here isn't a departure.
            let end = (st["tripTo"] as? [String: Any])?["name"] as? String
            if let end, !stopName.isEmpty, end == stopName { return nil }
            var headsign = st["headsign"] as? String ?? ""
            if let end, !end.isEmpty, headsign.isEmpty || headsign == stopName { headsign = end }
            return Departure(line: line, mode: st["mode"] as? String ?? "", color: hex(st["routeColor"]),
                             textColor: hex(st["routeTextColor"]), headsign: headsign,
                             time: time, delayMinutes: delay)
        }
    }

    /** A stretch of metro or rail track with its lines' color, for the transit map layer. */
    public struct Line: Sendable {
        public var points: [LatLng]
        public var color: UInt32
        public var metro: Bool
        public var names: [String]
    }

    /**
     * Metro, tram and train lines in a box, from Transitous' route map (Vela's transit layer).
     * Buses are left out. Below zoom 9 the service sends long-distance rail only.
     */
    public static func lines(south: Double, west: Double, north: Double, east: Double, zoom: Int) async -> [Line]? {
        guard let url = URL(string: "\(base)/api/experimental/map/routes?min=\(south),\(west)&max=\(north),\(east)&zoom=\(zoom)"),
              let (data, resp) = try? await session.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parseLines(data)
    }

    public static func parseLines(_ data: Data) -> [Line] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let routes = root["routes"] as? [[String: Any]],
              let polys = root["polylines"] as? [[String: Any]] else { return [] }
        var out: [Line] = []
        for p in polys {
            let rs = (p["routeIndexes"] as? [Int] ?? []).compactMap { routes.indices.contains($0) ? routes[$0] : nil }
            let rail = rs.filter { r in
                let v = TransitLeg.Vehicle(r["mode"] as? String ?? "")
                return v == .metro || v == .tram || v == .train
            }
            guard !rail.isEmpty, let enc = p["polyline"] as? [String: Any], let pts = enc["points"] as? String else { continue }
            let color = rail.lazy.compactMap { r in hex((r["transitRoutes"] as? [[String: Any]])?.first?["color"]) }.first
            let metro = rail.contains { TransitLeg.Vehicle($0["mode"] as? String ?? "") != .train }
            let names = rail.compactMap { ($0["transitRoutes"] as? [[String: Any]])?.first?["shortName"] as? String }
            let precision = min(7, max(5, (enc["precision"] as? Int) ?? 6))
            let line = Geo.decodePolyline(pts, precision: pow(10, Double(precision)))
            guard line.count >= 2 else { continue }
            // A feed without shapes draws straight chords between distant stops: leave those out.
            let len = Geo.length(line)
            if !metro, len / Double(line.count - 1) > 700 { continue }
            out.append(Line(points: line, color: color ?? (metro ? 0x5F6368 : 0x8E8E93), metro: metro,
                            names: Array(Set(names)).sorted()))
        }
        return out
    }

    public static func parse(_ data: Data) -> [TransitTrip] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let its = root["itineraries"] as? [[String: Any]] else { return [] }
        let trips = its.compactMap(itinerary)
        // The planner can repeat a trip; keep the first of each line-up and time.
        var seen = Set<String>()
        return trips.filter { t in
            let key = t.rides.map(\.line).joined(separator: ",") + "\(t.depart?.timeIntervalSince1970 ?? 0)"
            return seen.insert(key).inserted
        }
    }

    private static func itinerary(_ it: [String: Any]) -> TransitTrip? {
        guard let rawLegs = it["legs"] as? [[String: Any]] else { return nil }
        let legs = rawLegs.map(leg)
        guard legs.contains(where: { !$0.isWalk }) else { return nil } // a walk-only answer isn't transit
        let start = date(it["startTime"]), end = date(it["endTime"])
        let dur = number(it["duration"]) ?? (start.flatMap { s in end.map { $0.timeIntervalSince(s) } } ?? 0)
        let transfers = (it["transfers"] as? Int) ?? max(0, legs.filter { !$0.isWalk }.count - 1)
        return TransitTrip(depart: start, arrive: end, durationSeconds: dur, transfers: transfers, legs: legs)
    }

    private static func leg(_ l: [String: Any]) -> TransitLeg {
        let mode = l["mode"] as? String ?? ""
        let from = l["from"] as? [String: Any] ?? [:], to = l["to"] as? [String: Any] ?? [:]
        let start = date(l["startTime"]), end = date(l["endTime"])
        let dur = number(l["duration"]) ?? (start.flatMap { s in end.map { $0.timeIntervalSince(s) } } ?? 0)
        var out = TransitLeg(isWalk: TransitLeg.Vehicle(mode) == .walk, mode: mode,
                             fromName: from["name"] as? String ?? "", toName: to["name"] as? String ?? "",
                             depart: start, arrive: end, durationSeconds: dur,
                             distanceMeters: number(l["distance"]) ?? 0, path: path(l))
        if out.path.count < 2, let a = point(from), let b = point(to) { out.path = [a, b] }
        if out.distanceMeters == 0 { out.distanceMeters = Geo.length(out.path) }
        guard !out.isWalk else { return out }
        out.line = [l["routeShortName"], l["displayName"], l["routeLongName"]]
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        out.color = hex(l["routeColor"])
        out.textColor = hex(l["routeTextColor"])
        out.headsign = (l["headsign"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        out.stops = ((l["intermediateStops"] as? [Any])?.count ?? 0) + 1
        if l["realTime"] as? Bool == true, let s = start, let sched = date(l["scheduledStartTime"]) {
            out.delayMinutes = Int((s.timeIntervalSince(sched) / 60).rounded())
        }
        return out
    }

    private static func path(_ l: [String: Any]) -> [LatLng] {
        guard let g = l["legGeometry"] as? [String: Any], let pts = g["points"] as? String, !pts.isEmpty else { return [] }
        let p = min(7, max(5, (g["precision"] as? Int) ?? 6))
        return Geo.decodePolyline(pts, precision: pow(10, Double(p)))
            .filter { (-90...90).contains($0.lat) && (-180...180).contains($0.lng) }
    }

    private static func point(_ o: [String: Any]) -> LatLng? {
        guard let lat = number(o["lat"]), let lon = number(o["lon"]) else { return nil }
        return LatLng(lat, lon)
    }

    private static func number(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }

    static func hex(_ v: Any?) -> UInt32? {
        guard var s = (v as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        return s.count == 6 ? UInt32(s, radix: 16) : nil
    }

    static func date(_ v: Any?) -> Date? {
        guard let s = v as? String, !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }
}
