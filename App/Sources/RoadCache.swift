import Foundation

/**
 * Every speed limit, camera and traffic light Kite has been told about, kept on the phone. The
 * public Overpass servers can take a minute or more to answer (or not answer at all), so without
 * this a drive starts, and every reroute restarts, with no speed limit on screen. Roads driven
 * before (a commute) get their limits straight away; the live answer still replaces them.
 */
public final class RoadCache: @unchecked Sendable {
    public static let shared = RoadCache()

    struct Store: Codable {
        var ways: [Int64: Overpass.LimitWay] = [:]
        var cameras: [Int64: RoadCamera] = [:]
        var signals: [Int64: LatLng] = [:]
    }

    private let lock = NSLock()
    private var store: Store?
    private let file: URL?
    private var saving = false

    /** [file] nil keeps it in memory only (tests). */
    public init(file: URL? = RoadCache.defaultFile) {
        self.file = file
    }

    public static var defaultFile: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("road-data.json")
    }

    /** About a county's worth of roads; past that the oldest-added half goes. */
    static let maxWays = 40_000

    private func loaded() -> Store {
        if let store { return store }
        var s = Store()
        if let file, let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Store.self, from: data) { s = saved }
        store = s
        return s
    }

    /** Remembers one Overpass answer. */
    public func add(ways: [Overpass.LimitWay], cameras: [RoadCamera], signals: [(id: Int64, at: LatLng)]) {
        lock.lock()
        var s = loaded()
        for w in ways where w.id != 0 { s.ways[w.id] = w }
        for c in cameras where c.id != 0 { s.cameras[c.id] = c }
        for g in signals where g.id != 0 { s.signals[g.id] = g.at }
        if s.ways.count > Self.maxWays {
            // Ids grow as roads are added to OSM, not by when Kite saw them, but trimming the
            // lowest is cheap and keeps the file bounded.
            for id in s.ways.keys.sorted().prefix(s.ways.count - Self.maxWays / 2) { s.ways[id] = nil }
        }
        store = s
        let start = !saving && file != nil
        if start { saving = true }
        lock.unlock()
        // One write a few seconds later covers a burst of answers.
        if start {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { self.save() }
        }
    }

    /** Writes now, rather than a few seconds after the last answer. */
    public func flush() { save() }

    private func save() {
        lock.lock()
        let s = store
        saving = false
        lock.unlock()
        guard let file, let s, let data = try? JSONEncoder().encode(s) else { return }
        try? data.write(to: file, options: .atomic)
    }

    /** What's known within about 200 m of [line]: the ways, cameras and lights a live answer would hold. */
    public func along(_ line: [LatLng]) -> (cameras: [RoadCamera], ways: [Overpass.LimitWay], signals: [LatLng]) {
        guard line.count >= 2 else { return ([], [], []) }
        lock.lock()
        let s = loaded()
        lock.unlock()
        guard !s.ways.isEmpty || !s.cameras.isEmpty || !s.signals.isEmpty else { return ([], [], []) }
        // A quick box test first, then near the line itself, in cells of about 500 m.
        let cell = 0.005
        var cells = Set<Int64>()
        func key(_ lat: Double, _ lng: Double) -> Int64 { Int64((lat / cell).rounded(.down)) << 32 | (Int64((lng / cell).rounded(.down)) & 0xFFFF_FFFF) }
        let cum = Geo.cumulative(line)
        let samples = line + stride(from: 0, through: cum.last ?? 0, by: 200).map { Geo.point(along: line, meters: $0, cumulative: cum) }
        for p in samples {
            for dy in [-cell, 0, cell] { for dx in [-cell, 0, cell] { cells.insert(key(p.lat + dy, p.lng + dx)) } }
        }
        func near(_ p: LatLng) -> Bool { cells.contains(key(p.lat, p.lng)) }
        let ways = s.ways.values.filter { $0.line.contains(where: near) }
        let cams = s.cameras.values.filter { near($0.location) }
        let signals = s.signals.values.filter(near)
        return (Array(cams), Array(ways), Overpass.signalsOnRoute(Array(signals), line: line))
    }
}
