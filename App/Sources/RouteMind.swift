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
    @Published var umwelt: Bool { didSet { d.set(umwelt, forKey: "mind.umwelt") } }
    /// GPS worse than this many metres is handed to the phone sensors.
    @Published var gpsTrust: Int { didSet { d.set(gpsTrust, forKey: "mind.trust") } }
    /// Degrees added to the course, when the phone's compass sits crooked.
    @Published var headingTrim: Int { didSet { d.set(headingTrim, forKey: "mind.trim") } }
    /// Couch test page. Stays off until the version row in About is tapped five times.
    @Published var simUnlocked: Bool { didSet { d.set(simUnlocked, forKey: "mind.sim") } }
    /// The next GPS fix throws away the sensor estimate and starts again.
    var resetAsked = false

    private init() {
        deadReckoning = d.object(forKey: "mind.dr") as? Bool ?? true
        trueTime = d.object(forKey: "mind.trueTime") as? Bool ?? true
        avoidHardJunctions = d.object(forKey: "mind.hard") as? Bool ?? false
        greenWave = d.object(forKey: "mind.green") as? Bool ?? true
        haptics = d.object(forKey: "mind.haptics") as? Bool ?? true
        borderAssist = d.object(forKey: "mind.border") as? Bool ?? true
        umwelt = d.object(forKey: "mind.umwelt") as? Bool ?? true
        gpsTrust = d.object(forKey: "mind.trust") as? Int ?? 80
        headingTrim = d.object(forKey: "mind.trim") as? Int ?? 0
        simUnlocked = d.object(forKey: "mind.sim") as? Bool ?? false
    }
}

struct GuidanceNote: Equatable {
    var title: String
    var body: String
    /// "info", "warn" or "good".
    var tone: String
}

/// The Umwelt sticker shown during a couch simulation.
struct CouchChip: Equatable {
    var name: String
    var blocked: Bool
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

    /// How many zł waiting for the Polish side saves on `litres`. Negative means fuel in Germany.
    static func fuelDelta(litres: Double, _ p: Prices = helmstedt) -> Double {
        let plEur = p.plPln / p.plnPerEur
        return (p.deEur - plEur) * litres * p.plnPerEur
    }

    static func fuelNote(alongKm: Double, toBorderKm: Double, nearHelmstedt: Bool = false, litres: Double = 45) -> GuidanceNote {
        let save = Int(fuelDelta(litres: litres).rounded())
        let amount = "\(Int(litres.rounded())) l"
        if toBorderKm < 30 && save > 0 {
            return GuidanceNote(title: "Tankuj za granicą",
                                body: "\(helmstedt.plName), \(helmstedt.plPln) zł. Na \(amount) około \(save) zł mniej niż po niemieckiej stronie.",
                                tone: "good")
        }
        if nearHelmstedt && save > 0 {
            return GuidanceNote(title: "Nie tankuj w Helmstedt",
                                body: "\(helmstedt.deName) \(helmstedt.deEur) €. Do \(helmstedt.plName) około \(Int(toBorderKm)) km, na \(amount) około \(save) zł mniej.",
                                tone: "good")
        }
        if toBorderKm <= 120 && save > 0 {
            return GuidanceNote(title: "Paliwo przed granicą",
                                body: "W baku zostało mało na tę trasę. Do \(helmstedt.plName) około \(Int(toBorderKm)) km, na \(amount) około \(save) zł mniej po polskiej stronie.",
                                tone: "good")
        }
        return GuidanceNote(title: "Paliwo",
                            body: "Ceny po obu stronach granicy są zbliżone. Tankuj tam, gdzie stoisz.",
                            tone: "info")
    }

    /// Shell at Helmstedt, the last expensive stop people hit on the A2 before Poland.
    static let helmstedtPoint = LatLng(52.228, 10.974)

    /**
     * Border fuel card only for a long trip that actually goes to Poland, when the car
     * profile says the tank will not last, and only once you're near the cheap-fuel stretch.
     * A full tank or a short hop around home stays quiet.
     */
    static func borderFuelNote(here: LatLng, destination: LatLng, tripMeters: Double,
                               fuelLeft: Int, fuelTank: Int, consumption: Double, electric: Bool) -> GuidanceNote? {
        if electric || tripMeters < 40_000 { return nil }
        let tank = max(fuelTank, 1)
        let left = min(max(fuelLeft, 0), tank)
        if left * 10 >= tank * 9 { return nil }
        let use = consumption > 1 ? consumption : 6.5
        let rangeM = Double(left) / (use / 100.0) * 1000
        // Enough in the tank for this drive, with a small reserve: nothing to say.
        if rangeM >= tripMeters + 40_000 { return nil }
        let nowD = nearestCrossing(here)
        let destD = nearestCrossing(destination)
        let toPoland = destination.lng > 14.35 || destD < 40_000
        guard toPoland else { return nil }
        let atHelmstedt = here.distance(to: helmstedtPoint) < 40_000 && destD + 50_000 < nowD
        let closeToBorder = nowD < 80_000
        guard atHelmstedt || closeToBorder else { return nil }
        let litres = Double(max(tank - left, 5))
        return fuelNote(alongKm: 0, toBorderKm: nowD / 1000, nearHelmstedt: atHelmstedt && !closeToBorder, litres: litres)
    }

    private static func nearestCrossing(_ p: LatLng) -> Double {
        borders.map { p.distance(to: $0.location) }.min() ?? .greatestFiniteMagnitude
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

    /// Real low-emission outline, not a rectangle around the city.
    static func umwelt(at p: LatLng) -> UmweltHere? {
        CityAtlas.hit(p)
    }

    /// What the route card names. Only the city the trip still has to enter — not the one you are already in.
    struct Zone: Equatable, Sendable {
        var name: String
        var sticker: String
    }

    static func umweltToShow(me: LatLng?, destination: LatLng?, line: [LatLng], along: Double, driving: Bool) -> Zone? {
        let here = me.flatMap { umwelt(at: $0)?.name }
        if !driving {
            if let d = destination, let z = umwelt(at: d), z.name != here { return Zone(name: z.name, sticker: z.sticker) }
            return firstZone(on: line, from: 0, to: .greatestFiniteMagnitude, skip: here)
        }
        if let z = firstZone(on: line, from: along, to: along + 3_500, skip: here) { return z }
        if let d = destination, let z = umwelt(at: d), z.name != here, (me?.distance(to: d) ?? 1e12) < 8_000 {
            return Zone(name: z.name, sticker: z.sticker)
        }
        return nil
    }

    private static func firstZone(on line: [LatLng], from: Double, to: Double, skip: String?) -> Zone? {
        guard line.count >= 2 else { return nil }
        let cum = Geo.cumulative(line)
        let end = min(cum.last ?? 0, to)
        var m = max(0, from)
        while m <= end {
            if let z = umwelt(at: Geo.point(along: line, meters: m, cumulative: cum)), z.name != skip {
                return Zone(name: z.name, sticker: z.sticker)
            }
            m += 250
        }
        return nil
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
