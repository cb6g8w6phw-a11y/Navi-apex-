import Foundation
import UIKit

/** Toggles for the driving mind. Kept on their own so the big settings object stays untouched. */
@MainActor
final class MindSettings: ObservableObject {
    static let shared = MindSettings()
    private let d = UserDefaults.standard

    @Published var deadReckoning: Bool { didSet { d.set(deadReckoning, forKey: "mind.dr") } }
    @Published var trueTime: Bool { didSet { d.set(trueTime, forKey: "mind.trueTime") } }
    @Published var avoidHardJunctions: Bool { didSet { d.set(avoidHardJunctions, forKey: "mind.hard") } }
    @Published var greenWave: Bool { didSet { d.set(greenWave, forKey: "mind.green") } }
    @Published var haptics: Bool { didSet { d.set(haptics, forKey: "mind.haptics") } }
    @Published var borderAssist: Bool { didSet { d.set(borderAssist, forKey: "mind.border") } }
    @Published var umwelt: Bool {
        didSet {
            d.set(umwelt, forKey: "mind.umwelt")
            Self.umweltOn = umwelt
        }
    }
    /** GPS worse than this many metres is handed to the sensors. */
    @Published var gpsTrust: Int { didSet { d.set(gpsTrust, forKey: "mind.trust") } }
    /** Degrees added to the arrow, when the compass sits crooked. */
    @Published var headingTrim: Int { didSet { d.set(headingTrim, forKey: "mind.trim") } }
    /// The next GPS fix throws away the sensor estimate and starts again.
    var resetAsked = false
    /// Read from the map, which is not on the main actor. A bool, written only from here.
    nonisolated(unsafe) static var umweltOn = true

    private init() {
        deadReckoning = d.object(forKey: "mind.dr") as? Bool ?? true
        trueTime = d.object(forKey: "mind.trueTime") as? Bool ?? true
        avoidHardJunctions = d.object(forKey: "mind.hard") as? Bool ?? false
        greenWave = d.object(forKey: "mind.green") as? Bool ?? true
        haptics = d.object(forKey: "mind.haptics") as? Bool ?? true
        borderAssist = d.object(forKey: "mind.border") as? Bool ?? true
        let zoneOn = d.object(forKey: "mind.umwelt") as? Bool ?? true
        umwelt = zoneOn
        gpsTrust = d.object(forKey: "mind.trust") as? Int ?? 80
        headingTrim = d.object(forKey: "mind.trim") as? Int ?? 0
        Self.umweltOn = zoneOn
    }
}

struct GuidanceNote: Equatable {
    var title: String
    var body: String
    /// "info", "warn" or "good".
    var tone: String
}

enum VoiceIntent {
    case fuel, traffic, border, reroute, stop, unknown

    static func parse(_ text: String) -> VoiceIntent {
        let q = text.lowercased()
        if q.contains("paliw") || q.contains("tank") || q.contains("fuel") { return .fuel }
        if q.contains("korek") || q.contains("traffic") || q.contains("jam") { return .traffic }
        if q.contains("granic") || q.contains("border") { return .border }
        if q.contains("objazd") || q.contains("omij") || q.contains("reroute") { return .reroute }
        if q.contains("koniec") || q.contains("stop") { return .stop }
        return .unknown
    }
}

/**
 * The bits that sit on top of a route: real travel time, a fuel price across the border,
 * green-wave speed, rail crossings, Umwelt zones, border queues, parking at the pin.
 */
enum RouteMind {
    struct Prices {
        var deEur: Double
        var plPln: Double
        var plnPerEur: Double
        var tankLitres: Double
        var deName: String
        var plName: String
        var plKm: Double
    }

    static let helmstedt = Prices(deEur: 1.89, plPln: 6.49, plnPerEur: 4.28, tankLitres: 45,
                                  deName: "Shell Helmstedt", plName: "Orlen Świecko", plKm: 0)

    /// How many zł a full tank saves by waiting for the Polish side. Negative means fuel in Germany.
    static func fuelDelta(_ p: Prices = helmstedt) -> Double {
        let plEur = p.plPln / p.plnPerEur
        return (p.deEur - plEur) * p.tankLitres * p.plnPerEur
    }

    static func fuelNote(alongKm: Double, toBorderKm: Double) -> GuidanceNote {
        let save = Int(fuelDelta().rounded())
        if toBorderKm < 30 && save > 0 {
            return GuidanceNote(title: "Tankuj za granicą",
                                body: "\(helmstedt.plName), \(helmstedt.plPln) zł. Około \(save) zł mniej niż w \(helmstedt.deName).",
                                tone: "good")
        }
        if toBorderKm > 80 && save > 15 {
            return GuidanceNote(title: "Nie tankuj w Helmstedt",
                                body: "\(helmstedt.deName) \(helmstedt.deEur) €. Dojedź do \(helmstedt.plName) (\(Int(toBorderKm)) km), około \(save) zł mniej na baku.",
                                tone: "good")
        }
        return GuidanceNote(title: "Paliwo",
                            body: "Ceny po obu stronach granicy są zbliżone. Tankuj tam, gdzie stoisz.",
                            tone: "info")
    }

    /// A side road is offered only when cars would actually keep moving on it.
    static func acceptDetour(extraSeconds: Double, villageCapacity: Double, divertedDemand: Double) -> Bool {
        if divertedDemand > villageCapacity * 0.85 { return false }
        return extraSeconds < -90
    }

    /// Speed to suggest so the next light is met on green. Nil when it would mean speeding or crawling.
    static func greenWaveKmh(distanceMeters: Double, secondsToGreen: Double, limit: Double) -> Double? {
        guard distanceMeters > 30, distanceMeters < 1200 else { return nil }
        let need = distanceMeters / max(4, secondsToGreen) * 3.6
        if need < 25 || need > limit + 3 { return nil }
        return (need / 5).rounded() * 5
    }

    struct Ring: Equatable, Sendable {
        var outer: [LatLng]
        var holes: [[LatLng]]
    }

    /// One city's Umweltzone: the official outline, including every separate piece and any holes.
    struct Zone: Equatable, Sendable {
        var name: String
        var rings: [Ring]
        var south: Double
        var north: Double
        var west: Double
        var east: Double
    }

    private struct ZonePack: Decodable {
        var n: String
        var rings: [ZoneRing]
    }

    private struct ZoneRing: Decodable {
        var o: [[Double]]
        var h: [[[Double]]]?
    }

    /// Official Umweltbundesamt outlines (schematic; the signs on the road still win). Not ellipses.
    static let umweltZones: [Zone] = loadZones()

    private static func loadZones() -> [Zone] {
        guard let url = Bundle.main.url(forResource: "umwelt", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let packs = try? JSONDecoder().decode([ZonePack].self, from: data) else { return [] }
        return packs.compactMap { pack in
            let rings: [Ring] = pack.rings.compactMap { raw in
                let outer = coords(raw.o)
                guard outer.count >= 3 else { return nil }
                let holes = (raw.h ?? []).compactMap { h -> [LatLng]? in
                    let pts = coords(h)
                    return pts.count >= 3 ? pts : nil
                }
                return Ring(outer: outer, holes: holes)
            }
            let pts = rings.flatMap(\.outer)
            guard !pts.isEmpty else { return nil }
            return Zone(name: pack.n, rings: rings,
                        south: pts.map(\.lat).min() ?? 0, north: pts.map(\.lat).max() ?? 0,
                        west: pts.map(\.lng).min() ?? 0, east: pts.map(\.lng).max() ?? 0)
        }
    }

    private static func coords(_ pairs: [[Double]]) -> [LatLng] {
        pairs.compactMap { pair in pair.count >= 2 ? LatLng(pair[0], pair[1]) : nil }
    }

    /// Electric cars and cars with a green sticker may enter. Everyone else is kept out.
    static func mayEnterUmwelt() -> Bool {
        AppSettings.fuelKind == "electric" || AppSettings.stickerOn
    }

    static func umwelt(at p: LatLng) -> Zone? {
        umweltZones.first { z in
            p.lat >= z.south && p.lat <= z.north && p.lng >= z.west && p.lng <= z.east && covers(z, p)
        }
    }

    /// A point about 40 m outside the nearest boundary, so a car without a sticker stops before the zone.
    static func edgePoint(of zone: Zone, near p: LatLng) -> LatLng {
        let ring = zone.rings.min { dist2($0.outer, p) < dist2($1.outer, p) } ?? zone.rings[0]
        var best = ring.outer[0]
        var bestD = Double.greatestFiniteMagnitude
        let pts = ring.outer
        for i in pts.indices {
            let q = closest(pts[i], pts[(i + 1) % pts.count], p)
            let d = p.distance(to: q)
            if d < bestD { bestD = d; best = q }
        }
        let c = centroid(pts)
        let away = Geo.bearing(c, best)
        for meters in [40.0, 90.0, 160.0] {
            let out = shift(best, bearing: away, meters: meters)
            if !covers(zone, out) { return out }
        }
        return shift(best, bearing: away, meters: 160)
    }

    /// Routes that stay outside every Umweltzone. When none of [routes] do, Valhalla is asked to bend around the zones they hit.
    static func keepOut(_ routes: [Route], from: LatLng, to: LatLng, via: [LatLng]) async -> (routes: [Route], note: String?) {
        let clean = routes.filter { !enters($0.polyline) }
        if !clean.isEmpty { return (clean, nil) }
        let hit = zones(on: routes.flatMap(\.polyline))
        guard !hit.isEmpty else { return (routes, nil) }
        let rings = hit.flatMap(\.rings).map(\.outer)
        let budget = max(12, min(40, 700 / max(rings.count, 1)))
        let simple = rings.map { simplify($0, maxPoints: budget) }.filter { $0.count >= 3 }
        guard let trip = await Valhalla.routeAround(from: from, to: to, via: via, rings: simple),
              !enters(trip.line) else {
            return (routes, "Bez zielonej plakietki ta trasa i tak wjeżdża w strefę. Nie znalazłem objazdu.")
        }
        if let matched = try? await OSRM.match(trip.line, mode: .drive), !enters(matched.polyline) {
            var m = matched
            m.summary = "omija strefę"
            return ([m], "Trasa omija zieloną strefę, bo auto nie ma plakietki.")
        }
        let meters = trip.km > 0 ? trip.km * 1000 : Geo.length(trip.line)
        let seconds = trip.seconds > 0 ? trip.seconds : meters / 12
        let line = trip.line
        let bare = Route(mode: .drive, polyline: line, distanceMeters: meters,
                         typicalSeconds: seconds, trafficSeconds: nil, summary: "omija strefę",
                         maneuvers: [
                            Maneuver(type: .depart, instruction: "Jedź, omijając zieloną strefę",
                                     location: line[0], alongMeters: 0, distanceMeters: meters, road: nil),
                            Maneuver(type: .arrive, instruction: "Jesteś u celu",
                                     location: line[line.count - 1], alongMeters: meters, distanceMeters: 0, road: nil),
                         ], source: "valhalla")
        return ([bare], "Trasa omija zieloną strefę, bo auto nie ma plakietki.")
    }

    private static func enters(_ line: [LatLng]) -> Bool {
        guard line.count >= 2 else { return false }
        let cum = Geo.cumulative(line)
        let total = cum.last ?? 0
        var m = 0.0
        while m <= total {
            if umwelt(at: Geo.point(along: line, meters: m, cumulative: cum)) != nil { return true }
            m += 50
        }
        return false
    }

    private static func zones(on line: [LatLng]) -> [Zone] {
        guard line.count >= 2 else { return [] }
        let cum = Geo.cumulative(line)
        let total = cum.last ?? 0
        var seen = Set<String>()
        var out: [Zone] = []
        var m = 0.0
        while m <= total {
            if let z = umwelt(at: Geo.point(along: line, meters: m, cumulative: cum)), seen.insert(z.name).inserted {
                out.append(z)
            }
            m += 80
        }
        return out
    }

    /// The zone to draw: the pin is inside and you are not, or the route is about to cross the line.
    /// Nothing while you are already in it, and nothing for a city the trip never enters.
    static func umweltToShow(me: LatLng?, destination: LatLng?, line: [LatLng], along: Double, driving: Bool) -> Zone? {
        guard MindSettings.umweltOn else { return nil }
        let here = me.flatMap { umwelt(at: $0) }?.name
        if !driving {
            if let d = destination, let z = umwelt(at: d), z.name != here { return z }
            return firstZone(on: line, from: 0, to: .greatestFiniteMagnitude, skip: here)
        }
        if let z = firstZone(on: line, from: along, to: along + 3_500, skip: here) { return z }
        if let d = destination, let z = umwelt(at: d), z.name != here, (me?.distance(to: d) ?? 1e12) < 8_000 { return z }
        return nil
    }

    private static func firstZone(on line: [LatLng], from: Double, to: Double, skip: String?) -> Zone? {
        guard line.count >= 2 else { return nil }
        let cum = Geo.cumulative(line)
        let end = min(cum.last ?? 0, to)
        var m = max(0, from)
        while m <= end {
            let p = Geo.point(along: line, meters: m, cumulative: cum)
            if let z = umwelt(at: p), z.name != skip { return z }
            m += 250
        }
        return nil
    }

    private static func covers(_ z: Zone, _ p: LatLng) -> Bool {
        z.rings.contains { ring in
            contains(p, ring.outer) && !ring.holes.contains { contains(p, $0) }
        }
    }

    private static func contains(_ p: LatLng, _ ring: [LatLng]) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in ring.indices {
            let a = ring[i], b = ring[j]
            if (a.lat > p.lat) != (b.lat > p.lat), a.lat != b.lat {
                let x = (b.lng - a.lng) * (p.lat - a.lat) / (b.lat - a.lat) + a.lng
                if p.lng < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    private static func centroid(_ pts: [LatLng]) -> LatLng {
        guard !pts.isEmpty else { return LatLng(0, 0) }
        return LatLng(pts.reduce(0) { $0 + $1.lat } / Double(pts.count), pts.reduce(0) { $0 + $1.lng } / Double(pts.count))
    }

    private static func dist2(_ ring: [LatLng], _ p: LatLng) -> Double {
        ring.reduce(Double.greatestFiniteMagnitude) { min($0, p.distance(to: $1)) }
    }

    /// Closest point of segment a–b to p, in a flat metre grid.
    private static func closest(_ a: LatLng, _ b: LatLng, _ p: LatLng) -> LatLng {
        let k = cos(p.lat * .pi / 180) * 111_320.0
        let ax = a.lng * k, ay = a.lat * 110_540
        let bx = b.lng * k, by = b.lat * 110_540
        let px = p.lng * k, py = p.lat * 110_540
        let dx = bx - ax, dy = by - ay
        let len2 = dx * dx + dy * dy
        let t = len2 < 1 ? 0 : max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / len2))
        return LatLng((ay + dy * t) / 110_540, (ax + dx * t) / k)
    }

    private static func shift(_ p: LatLng, bearing deg: Double, meters: Double) -> LatLng {
        let r = 6_371_000.0
        let br = deg * .pi / 180
        let lat1 = p.lat * .pi / 180, lng1 = p.lng * .pi / 180
        let d = meters / r
        let lat2 = asin(sin(lat1) * cos(d) + cos(lat1) * sin(d) * cos(br))
        let lng2 = lng1 + atan2(sin(br) * sin(d) * cos(lat1), cos(d) - sin(lat1) * sin(lat2))
        return LatLng(lat2 * 180 / .pi, lng2 * 180 / .pi)
    }

    /// Douglas–Peucker until the ring is small enough for a routing request. The map keeps the full line.
    private static func simplify(_ ring: [LatLng], maxPoints: Int) -> [LatLng] {
        var pts = ring
        if pts.count > 1, pts.first == pts.last { pts.removeLast() }
        // A long outline would recurse too deep. Thin it first; the map still uses every point.
        if pts.count > maxPoints * 4 {
            let n = maxPoints * 4
            let step = Double(pts.count - 1) / Double(n - 1)
            pts = (0..<n).map { pts[min(pts.count - 1, Int((Double($0) * step).rounded()))] }
        }
        var tol = 12.0
        while pts.count > maxPoints, tol < 600 {
            pts = douglas(pts, tol)
            tol *= 1.7
        }
        guard pts.count > maxPoints, pts.count > 2 else { return pts }
        let step = Double(pts.count - 1) / Double(maxPoints - 1)
        return (0..<maxPoints).map { pts[min(pts.count - 1, Int((Double($0) * step).rounded()))] }
    }

    private static func douglas(_ pts: [LatLng], _ tol: Double) -> [LatLng] {
        guard pts.count > 2 else { return pts }
        var maxD = 0.0, idx = 0
        for i in 1..<(pts.count - 1) {
            let d = distToSeg(pts[i], pts[0], pts[pts.count - 1])
            if d > maxD { maxD = d; idx = i }
        }
        if maxD <= tol { return [pts[0], pts[pts.count - 1]] }
        return Array(douglas(Array(pts[0...idx]), tol).dropLast()) + douglas(Array(pts[idx...]), tol)
    }

    private static func distToSeg(_ p: LatLng, _ a: LatLng, _ b: LatLng) -> Double {
        p.distance(to: closest(a, b, p))
    }

    struct Crossing {
        var name: String
        var waitMin: Int
        var carsOk: Bool
        var location: LatLng
    }

    static let borders: [Crossing] = [
        Crossing(name: "Świecko", waitMin: 36, carsOk: true, location: LatLng(52.348, 14.59)),
        Crossing(name: "Słubice", waitMin: 12, carsOk: true, location: LatLng(52.35, 14.56)),
        Crossing(name: "Osinów Dolny", waitMin: 9, carsOk: true, location: LatLng(52.52, 14.62)),
        Crossing(name: "Kostrzyn", waitMin: 18, carsOk: true, location: LatLng(52.58, 14.65)),
    ]

    static func borderNote(near p: LatLng) -> GuidanceNote? {
        let ranked = borders.map { ($0, p.distance(to: $0.location)) }.sorted { $0.1 < $1.1 }
        guard let (here, d) = ranked.first, d < 25_000 else { return nil }
        guard let better = ranked.dropFirst().first(where: { $0.0.carsOk && $0.0.waitMin + 4 < here.waitMin }) else { return nil }
        return GuidanceNote(title: "\(here.name) \(here.waitMin) min",
                            body: "\(better.0.name) około \(better.0.waitMin) min. Auto osobowe przejdzie.",
                            tone: "warn")
    }

    /// A rough free-bay guess for the pin at the end of a drive. Not a live sensor — a prior from the hour.
    static func parkingFree(at date: Date = Date(), capacity: Int = 220) -> Int {
        let hour = Calendar.current.component(.hour, from: date)
        let used = hour >= 10 && hour <= 18 ? 0.72 : (hour >= 19 && hour <= 22 ? 0.55 : 0.3)
        return max(0, Int((Double(capacity) * (1 - used)).rounded()))
    }

    @MainActor
    static func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        guard MindSettings.shared.haptics else { return }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
}
