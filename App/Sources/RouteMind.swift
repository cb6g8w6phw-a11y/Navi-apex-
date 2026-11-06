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

    private init() {
        deadReckoning = d.object(forKey: "mind.dr") as? Bool ?? true
        trueTime = d.object(forKey: "mind.trueTime") as? Bool ?? true
        avoidHardJunctions = d.object(forKey: "mind.hard") as? Bool ?? false
        greenWave = d.object(forKey: "mind.green") as? Bool ?? true
        haptics = d.object(forKey: "mind.haptics") as? Bool ?? true
        borderAssist = d.object(forKey: "mind.border") as? Bool ?? true
        umwelt = d.object(forKey: "mind.umwelt") as? Bool ?? true
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
        var sticker: String
        var south: Double
        var west: Double
        var north: Double
        var east: Double
    }

    static let umweltZones: [Zone] = [
        Zone(name: "Berlin", sticker: "zielona", south: 52.34, west: 13.09, north: 52.67, east: 13.76),
        Zone(name: "Hannover", sticker: "zielona", south: 52.30, west: 9.60, north: 52.46, east: 9.87),
        Zone(name: "Braunschweig", sticker: "zielona", south: 52.22, west: 10.44, north: 52.33, east: 10.58),
        Zone(name: "Magdeburg", sticker: "zielona", south: 52.08, west: 11.55, north: 52.18, east: 11.70),
    ]

    static func umwelt(at p: LatLng) -> Zone? {
        umweltZones.first { p.lat >= $0.south && p.lat <= $0.north && p.lng >= $0.west && p.lng <= $0.east }
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
