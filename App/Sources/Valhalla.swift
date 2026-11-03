import Foundation

/**
 * Posted speed limits along a route from the public Valhalla server (FOSSGIS, the same people as
 * the open router), which matches the route to OpenStreetMap's roads and says each one's limit.
 * It answers a whole drive in under a second, where the public Overpass servers can take a minute
 * or not answer at all at night; Overpass still brings the cameras and traffic lights.
 */
public enum Valhalla {
    static let endpoint = URL(string: "https://valhalla1.openstreetmap.de/trace_attributes")!

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.httpAdditionalHeaders = ["User-Agent": OSRM.userAgent]
        return URLSession(configuration: c)
    }()

    /** The limits along [line], and the roads it drives (with their limit where known). Nil when the server didn't answer. */
    /// [progress] gets the limits so far after each piece, so a long drive's first miles show straight away.
    public static func speedLimits(along line: [LatLng], progress: (@Sendable ([SpeedLimit]) async -> Void)? = nil) async
        -> (limits: [SpeedLimit], ways: [Overpass.LimitWay])? {
        guard line.count >= 2 else { return ([], []) }
        let cum = Geo.cumulative(line)
        let total = cum.last ?? 0
        // In pieces of about 25 km: the server turns away very long traces, and placing each road on
        // a short piece of the line is quick.
        var merged: [SpeedLimit] = []
        var ways: [Overpass.LimitWay] = []
        var start = 0.0
        while start < total {
            let end = min(total, start + 25_000)
            let piece = Geo.slice(line, from: start, to: end, cumulative: cum)
            guard let data = await fetch(thin(piece)), let parsed = parse(data) else { return nil }
            // Placed by where each road really lies on the route; scaled by length (the matched
            // roads run a little longer or shorter) only where that doesn't place it.
            let placed = Overpass.speedLimits(parsed.ways, on: piece)
            let scale = parsed.meters > 0 ? (end - start) / parsed.meters : 1
            for m in stride(from: 0.0, to: end - start, by: 25) {
                let kmh = placed.last { $0.startMeters <= m }?.kmh ?? parsed.limits.last { $0.startMeters * scale <= m }?.kmh
                if merged.last.map({ $0.kmh != kmh }) ?? true { merged.append(SpeedLimit(startMeters: start + m, kmh: kmh)) }
            }
            ways += parsed.ways
            start = end
            // Unknown past what has been matched so far, not the last limit carried on.
            if start < total { await progress?(merged + [SpeedLimit(startMeters: start, kmh: nil)]) }
        }
        return (merged, ways)
    }

    /** About one point every 15 m is plenty to match on, and keeps the request small. */
    static func thin(_ line: [LatLng]) -> [LatLng] {
        guard var last = line.first else { return [] }
        var out = [last]
        for p in line.dropFirst() where last.distance(to: p) >= 15 {
            out.append(p)
            last = p
        }
        if let end = line.last, out.last != end { out.append(end) }
        return out
    }

    private static func fetch(_ shape: [LatLng]) async -> Data? {
        let body: [String: Any] = [
            "shape": shape.map { ["lat": $0.lat, "lon": $0.lng] },
            "costing": "auto",
            "shape_match": "map_snap",
            "filters": ["attributes": ["edge.speed_limit", "edge.way_id", "edge.names", "edge.length", "edge.begin_shape_index",
                                       "edge.end_shape_index", "shape"], "action": "include"],
        ]
        var r = URLRequest(url: endpoint)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, resp) = try? await session.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    /** Limit changes along the matched roads (meters from their start), the roads themselves, and their length. */
    static func parse(_ data: Data) -> (limits: [SpeedLimit], ways: [Overpass.LimitWay], meters: Double)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let edges = root["edges"] as? [[String: Any]] else { return nil }
        let shape = (root["shape"] as? String).map { Geo.decodePolyline($0) } ?? []
        var limits: [SpeedLimit] = []
        var ways: [Overpass.LimitWay] = []
        var along = 0.0
        // The last posted limit and the road it was on.
        var carried: (kmh: Double, names: Set<String>)?
        for e in edges {
            // 0 is "not known"; Valhalla marks a variable or no limit with 255.
            let raw = (e["speed_limit"] as? NSNumber)?.doubleValue
            let mapped = Overpass.britishLimit(raw.flatMap { (1...200).contains($0) ? $0 : nil }, at: shape.first ?? LatLng(0, 0))
            let names = Set((e["names"] as? [String]) ?? [])
            // A limit holds until a sign says otherwise: further along the same road with no limit
            // mapped, the last one still applies (Normandy Way, Marchwood: 40 mph mapped by the
            // roundabout, then a mile with none, 2026-10-27). A different road starts unknown.
            if let m = mapped, !names.isEmpty { carried = (m, names) }
            else if mapped == nil, let c = carried, names.isDisjoint(with: c.names) { carried = nil }
            else if mapped != nil { carried = nil }
            let kmh = mapped ?? carried?.kmh
            if limits.last.map({ $0.kmh != kmh }) ?? true { limits.append(SpeedLimit(startMeters: along, kmh: kmh)) }
            along += ((e["length"] as? NSNumber)?.doubleValue ?? 0) * 1000
            if let a = (e["begin_shape_index"] as? NSNumber)?.intValue, let b = (e["end_shape_index"] as? NSNumber)?.intValue,
               a >= 0, b < shape.count, b > a {
                // The roads keep only what's mapped (they're remembered for later drives); the carried limit is in [limits].
                ways.append(Overpass.LimitWay(id: (e["way_id"] as? NSNumber)?.int64Value ?? 0, kmh: mapped, line: Array(shape[a...b])))
            }
        }
        return (limits, ways, along)
    }
}
