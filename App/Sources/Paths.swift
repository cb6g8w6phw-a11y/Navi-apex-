import Foundation

/**
 * Walking paths and cycle lanes from OSM (Overpass), the map layer of Apex's foot and bike
 * modes: the route itself follows them (the OSRM foot and bike profiles), and this draws
 * what's around too, so the way across a park or along a river is on the map before it is
 * asked for. Green for cycle lanes, tan for walking paths.
 */
public enum Paths {
    public struct PathLine: Sendable {
        public var cycle: Bool
        public var points: [LatLng]
        public init(cycle: Bool, points: [LatLng]) {
            self.cycle = cycle; self.points = points
        }
    }

    /** Paths in a box. Nil when every mirror failed, so the caller can retry later. */
    public static func fetch(south: Double, west: Double, north: Double, east: Double) async -> [PathLine]? {
        let box = String(format: "%.5f,%.5f,%.5f,%.5f", south, west, north, east)
        let q = """
        [out:json][timeout:25];
        way[highway~"^(cycleway|footway|path)$"](\(box));
        out geom 700;
        """
        guard let data = await Overpass.query(q) else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = root["elements"] as? [[String: Any]] else { return nil }
        var out: [PathLine] = []
        for el in elements {
            guard el["type"] as? String == "way",
                  let geometry = el["geometry"] as? [[String: Any]] else { continue }
            let pts: [LatLng] = geometry.compactMap { g in
                guard let lat = g["lat"] as? Double, let lng = g["lon"] as? Double else { return nil }
                return LatLng(lat, lng)
            }
            guard pts.count >= 2 else { continue }
            let tags = el["tags"] as? [String: Any]
            let kind = tags?["highway"] as? String
            out.append(PathLine(cycle: kind == "cycleway", points: pts))
        }
        return out
    }
}
