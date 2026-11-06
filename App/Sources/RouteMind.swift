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
        umwelt = d.object(forKey: "mind.umwelt") as? Bool ?? true
        Self.umweltOn = umwelt
        gpsTrust = d.object(forKey: "mind.trust") as? Int ?? 80
        headingTrim = d.object(forKey: "mind.trim") as? Int ?? 0
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

    struct Zone: Equatable {
        var name: String
        var note: String
        var ring: [LatLng]
        var south: Double
        var north: Double
        var west: Double
        var east: Double
    }

    /// Inner-city rings of the Umweltzonen still in force in 2026. A green sticker is the only one that counts.
    static let umweltZones: [Zone] = {
        func oval(_ name: String, _ lat: Double, _ lng: Double, _ rxKm: Double, _ ryKm: Double, _ note: String = "Wjazd tylko z zieloną plakietką.") -> Zone {
            let cosLat = cos(lat * .pi / 180)
            let ring = (0..<32).map { i -> LatLng in
                let a = Double(i) / 32 * 2 * .pi
                return LatLng(lat + ryKm * cos(a) / 110.54, lng + rxKm * sin(a) / (111.32 * max(0.2, cosLat)))
            }
            return Zone(name: name, note: note,
                        ring: ring,
                        south: ring.map(\.lat).min() ?? lat, north: ring.map(\.lat).max() ?? lat,
                        west: ring.map(\.lng).min() ?? lng, east: ring.map(\.lng).max() ?? lng)
        }
        let ruhr = "Zielona plakietka. Autostrady są poza strefą."
        let diesel = "Zielona plakietka. Starsze diesle mają dodatkowy zakaz."
        return [
            oval("Magdeburg", 52.127, 11.639, 1.9, 2.5),
            oval("Halle", 51.482, 11.970, 2.0, 2.2),
            oval("Leipzig", 51.339, 12.373, 3.4, 3.1),
            oval("Berlin", 52.510, 13.405, 6.2, 5.4),
            oval("Bremen", 53.076, 8.808, 2.3, 2.0),
            oval("Osnabrück", 52.278, 8.047, 2.0, 1.8),
            oval("München", 48.137, 11.575, 4.3, 4.0, diesel),
            oval("Augsburg", 48.366, 10.894, 2.2, 2.0),
            oval("Regensburg", 49.013, 12.102, 1.7, 1.5),
            oval("Stuttgart", 48.778, 9.178, 6.2, 5.2, diesel),
            oval("Pforzheim", 48.893, 8.705, 2.0, 1.6),
            oval("Ludwigsburg", 48.897, 9.192, 6.5, 4.2),
            oval("Frankfurt", 50.110, 8.682, 3.6, 3.2),
            oval("Offenbach", 50.099, 8.766, 1.8, 1.6),
            oval("Wiesbaden", 50.083, 8.241, 2.4, 2.0),
            oval("Darmstadt", 49.872, 8.651, 2.2, 2.0, diesel),
            oval("Marburg", 50.809, 8.771, 1.4, 1.3),
            oval("Limburg", 50.388, 8.065, 1.2, 1.1),
            oval("Köln", 50.938, 6.960, 4.6, 4.2),
            oval("Düsseldorf", 51.227, 6.773, 3.4, 3.1),
            oval("Bonn", 50.735, 7.098, 2.6, 2.2),
            oval("Aachen", 50.776, 6.084, 2.3, 2.0),
            oval("Münster", 51.961, 7.626, 2.4, 2.2),
            oval("Wuppertal", 51.256, 7.151, 3.2, 1.6),
            oval("Krefeld", 51.333, 6.562, 2.2, 2.0),
            oval("Mönchengladbach", 51.194, 6.442, 2.4, 2.0),
            oval("Neuss", 51.198, 6.688, 1.8, 1.6),
            oval("Hagen", 51.359, 7.475, 2.0, 1.8),
            oval("Remscheid", 51.179, 7.192, 1.8, 1.5),
            oval("Siegen", 50.875, 8.024, 1.6, 1.4),
            oval("Dinslaken", 51.562, 6.734, 1.6, 1.4, ruhr),
            oval("Eschweiler", 50.817, 6.272, 1.5, 1.3),
            oval("Langenfeld", 51.108, 6.949, 1.5, 1.3),
            oval("Overath", 50.932, 7.284, 1.2, 1.1),
            oval("Bochum", 51.481, 7.216, 3.0, 2.5, ruhr),
            oval("Bottrop", 51.523, 6.925, 2.3, 2.0, ruhr),
            oval("Castrop-Rauxel", 51.550, 7.311, 2.1, 1.7, ruhr),
            oval("Dortmund", 51.514, 7.465, 4.0, 3.4, ruhr),
            oval("Duisburg", 51.435, 6.762, 3.4, 2.9, ruhr),
            oval("Essen", 51.456, 7.012, 3.5, 3.0, ruhr),
            oval("Gelsenkirchen", 51.508, 7.096, 2.7, 2.3, ruhr),
            oval("Gladbeck", 51.571, 6.983, 1.7, 1.5, ruhr),
            oval("Herne", 51.538, 7.221, 2.0, 1.6, ruhr),
            oval("Herten", 51.592, 7.140, 1.6, 1.4, ruhr),
            oval("Mülheim", 51.428, 6.883, 2.2, 1.9, ruhr),
            oval("Oberhausen", 51.470, 6.852, 2.3, 2.0, ruhr),
            oval("Recklinghausen", 51.614, 7.198, 2.2, 1.9, ruhr),
        ]
    }()

    static func umwelt(at p: LatLng) -> Zone? {
        umweltZones.first { z in
            p.lat >= z.south && p.lat <= z.north && p.lng >= z.west && p.lng <= z.east && contains(p, z.ring)
        }
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
            m += 400
        }
        return nil
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
