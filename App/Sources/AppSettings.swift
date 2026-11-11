import Foundation
import SwiftUI

// MARK: - Settings modes

enum ThemeMode: String, CaseIterable, Identifiable {
    case system, light, dark, black
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "Systemowy"
        case .light: return "Jasny"
        case .dark: return "Ciemny"
        case .black: return "Czarny, matowe szkło"
        }
    }
}

/** How the buttons and cards floating over the map look: Apple's shiny Liquid Glass, or calm matte frosted glass. */
enum GlassStyle: String, CaseIterable, Identifiable {
    case liquid, matte
    var id: String { rawValue }
    var label: String { self == .liquid ? "Liquid Glass" : "Matowe szkło" }
}

enum UnitsMode: String, CaseIterable, Identifiable {
    case auto, metric, imperial, yards
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Automatyczne"
        case .metric: return "Kilometry"
        case .imperial: return "Mile i stopy"
        case .yards: return "Mile i jardy (UK)"
        }
    }
}

/** Everything in Settings, kept between launches. */
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

       @Published var hapticLevel: Haptics.Level {
        didSet { d.set(hapticLevel.rawValue, forKey: "hapticLevel") }
    }
    @Published var theme: ThemeMode { didSet { d.set(theme.rawValue, forKey: "theme") } }
    @Published var glassStyle: GlassStyle { didSet { d.set(glassStyle.rawValue, forKey: "glassStyle") } }
    @Published var units: UnitsMode { didSet { d.set(units.rawValue, forKey: "units") } }
    @Published var voice: Bool { didSet { d.set(voice, forKey: "voice") } }
    /// pl, de or en. Drives the spoken maneuvers and the lock-screen words.
    @Published var language: String { didSet { d.set(language, forKey: "appLanguage") } }
    @Published var traffic: Bool { didSet { d.set(traffic, forKey: "traffic") } }
    /** Live fuel prices (Tankerkönig): on or off, the person's own free key (kept on this phone), which fuel, and the size of a fill-up. */
    @Published var fuelOn: Bool { didSet { d.set(fuelOn, forKey: "fuelOn") } }
    @Published var fuelKey: String { didSet { d.set(fuelKey, forKey: "fuelKey") } }
    @Published var fuelType: String { didSet { d.set(fuelType, forKey: "fuelType") } }
    @Published var fuelTank: Int { didSet { d.set(fuelTank, forKey: "fuelTank") } }
    /** Litres in the tank right now, so a cheap station is priced on what still fits, not a drive to Poland. */
    @Published var fuelLeft: Int { didSet { d.set(fuelLeft, forKey: "fuelLeft") } }
    /// The reserve light: about a fifth of the tank, or 8 litres, whichever comes first.
    var fuelOnReserve: Bool {
        let tank = max(fuelTank, 1)
        return fuelLeft <= 8 || fuelLeft * 5 <= tank
    }
    /** How many of the cheapest stations the map shows at a time. */
    @Published var fuelCount: Int { didSet { d.set(fuelCount, forKey: "fuelCount") } }
    /** The small weather badge on the map screen. */
    @Published var weatherOn: Bool { didSet { d.set(weatherOn, forKey: "weatherOn") } }
    /** The DWD rain radar drawn on the main map. */
    @Published var radarOn: Bool { didSet { d.set(radarOn, forKey: "radarOn") } }
    @Published var satellite: Bool { didSet { d.set(satellite, forKey: "satellite") } }
    /** Hill shading, and metro/rail lines in their colors. */
    @Published var terrain: Bool { didSet { d.set(terrain, forKey: "terrain") } }
    @Published var transitLines: Bool { didSet { d.set(transitLines, forKey: "transitLines") } }
    @Published var avoidTolls: Bool { didSet { d.set(avoidTolls, forKey: "avoidTolls") } }
    @Published var avoidHighways: Bool { didSet { d.set(avoidHighways, forKey: "avoidHighways") } }
    /** "Use Apex without Google": search and routes from open data only. */
    @Published var noGoogle: Bool { didSet { d.set(noGoogle, forKey: "noGoogle") } }
    /** Fixed speed cameras on the map, and plate readers (DeFlock), from OpenStreetMap. */
    @Published var speedCameras: Bool { didSet { d.set(speedCameras, forKey: "speedCameras") } }
    @Published var plateCameras: Bool { didSet { d.set(plateCameras, forKey: "plateCameras") } }
    /** Public CCTV from OpenStreetMap. On the map only, never spoken. */
    @Published var watchCameras: Bool { didSet { d.set(watchCameras, forKey: "watchCameras") } }
    /** Say "Speed camera ahead" while navigating. Off by default: some countries restrict it. */
    @Published var cameraWarnings: Bool { didSet { d.set(cameraWarnings, forKey: "cameraWarnings") } }
    /** Say so when driving over the posted limit. Off by default, like Vela. */
    @Published var speedingAlert: Bool { didSet { d.set(speedingAlert, forKey: "speedingAlert") } }
    /** How many km/h over the posted limit before that warning can speak. */
    @Published var speedSlack: Int { didSet { d.set(speedSlack, forKey: "speedSlack") } }
    /** Live reports from Waze drivers (police, crashes, hazards…): on the map, and warned about while driving. */
    @Published var waze: Bool { didSet { d.set(waze, forKey: "waze") } }
    /** The "Waze alerts (beta)" question has been answered, on first launch or after updating. */
    @Published var wazeAsked: Bool { didSet { d.set(wazeAsked, forKey: "wazeAsked") } }
    /** Which kinds of Waze report to show; the basics are on at first. */
    @Published var wazeKinds: Set<WazeAlert.Kind> { didSet { d.set(wazeKinds.map(\.rawValue), forKey: "wazeKinds") } }
    /** Waze reports as icons on the map (they're always warned about on the route). */
    @Published var wazeOnMap: Bool { didSet { d.set(wazeOnMap, forKey: "wazeOnMap") } }
    /** Chime and say "Police reported ahead" while navigating. */
    @Published var wazeVoice: Bool { didSet { d.set(wazeVoice, forKey: "wazeVoice") } }
    /** Reports older than this are ignored, in minutes; 0 keeps everything Waze still lists. */
    @Published var wazeMaxAge: Int { didSet { d.set(wazeMaxAge, forKey: "wazeMaxAge") } }
    /** A glow where police get reported, from what Kite has seen on this phone. */
    @Published var wazeHeatmap: Bool { didSet { d.set(wazeHeatmap, forKey: "wazeHeatmap") } }
    /** "Police risk: high" while driving, from the Waze police reports remembered on this phone. */
    @Published var policeRisk: Bool { didSet { d.set(policeRisk, forKey: "policeRisk") } }
    /** Warn about police planes and helicopters nearby (open ADS-B flight tracking, not Waze). */
    @Published var policeAircraft: Bool { didSet { d.set(policeAircraft, forKey: "policeAircraft") } }
    /** The map's "P" button: save where you parked, and find the way back. */
    @Published var parkingButton: Bool { didSet { d.set(parkingButton, forKey: "parkingButton") } }
    @Published var home: Place? { didSet { save(home, "home") } }
    @Published var work: Place? { didSet { save(work, "work") } }
    /** Where the car is parked, with when in `statusText`. */
    @Published var parking: Place? { didSet { save(parking, "parking") } }
    /** The first-run choice between Google's data and open data only has been made. */
    @Published var welcomed: Bool { didSet { d.set(welcomed, forKey: "welcomed") } }
    @Published var defaultMode: TravelMode { didSet { d.set(defaultMode.rawValue, forKey: "defaultMode") } }
    @Published var saved: [Place] { didSet { save(saved, "saved") } }
    @Published var recents: [String] { didSet { d.set(recents, forKey: "recents") } }
    /** Places you opened lately, newest first. */
    @Published var recentPlaces: [Place] { didSet { save(recentPlaces, "recentPlaces") } }
    // The car: what it is, and everything about it that runs out.
    @Published var carName: String { didSet { d.set(carName, forKey: "carName") } }
    @Published var carFuel: String { didSet { d.set(carFuel, forKey: "carFuel"); Self.fuelKind = carFuel } }
    /// Average use, litres per 100 km. The border-fuel note uses this with the tank, not a fixed 45 l.
    @Published var carConsumption: Double { didSet { d.set(carConsumption, forKey: "carConsumption") } }
    @Published var carOdometer: Int { didSet { d.set(carOdometer, forKey: "carOdometer") } }
    @Published var insuranceEnd: Date? { didSet { d.set(insuranceEnd, forKey: "insuranceEnd") } }
    @Published var inspectionEnd: Date? { didSet { d.set(inspectionEnd, forKey: "inspectionEnd") } }
    @Published var carParts: [CarPart] { didSet { save(carParts, "carParts") } }
    /** The car ball under the weather on the map. */
    @Published var carBallOn: Bool { didSet { d.set(carBallOn, forKey: "carBallOn") } }
    /// Green Umwelt sticker on the windscreen. Off: driving routes stay outside the zones.
    @Published var greenSticker: Bool {
        didSet { d.set(greenSticker, forKey: "greenSticker"); Self.stickerOn = greenSticker }
    }
    /// Sign in with Apple user identifier. Empty until the account is connected in Settings.
    @Published var appleUser: String { didSet { d.set(appleUser, forKey: "appleUser") } }
    /// Name (or email) Apple returned the first time this account signed in.
    @Published var appleName: String { didSet { d.set(appleName, forKey: "appleName") } }
    /// Builtin music apps the person switched on. Apple Music stays if the list would be empty.
    @Published var musicEnabled: [String] { didSet { d.set(musicEnabled, forKey: "musicEnabled") } }
    /// Which connected service the map player opens.
    @Published var musicActive: String { didSet { d.set(musicActive, forKey: "musicActive") } }
    /// Services added from a link, the way Mornye takes an extra source.
    @Published var musicExtras: [MusicExtra] { didSet { save(musicExtras, "musicExtras") } }
    nonisolated(unsafe) static var stickerOn = true
    nonisolated(unsafe) static var fuelKind = "diesel"

    /// Electric cars may enter an Umweltzone without a sticker.
    var mayEnterUmwelt: Bool { carFuel == "electric" || greenSticker }

    private init() {
        theme = ThemeMode(rawValue: d.string(forKey: "theme") ?? "") ?? .system
        glassStyle = GlassStyle(rawValue: d.string(forKey: "glassStyle") ?? "") ?? .liquid
        units = UnitsMode(rawValue: d.string(forKey: "units") ?? "") ?? .auto
        voice = d.object(forKey: "voice") as? Bool ?? true
        language = d.string(forKey: "appLanguage") ?? "pl"
        traffic = d.object(forKey: "traffic") as? Bool ?? true
        fuelOn = d.object(forKey: "fuelOn") as? Bool ?? true
        fuelKey = d.string(forKey: "fuelKey") ?? ""
        fuelType = d.string(forKey: "fuelType") ?? "diesel"
        let tank = d.object(forKey: "fuelTank") as? Int ?? 40
        fuelTank = tank
        fuelLeft = d.object(forKey: "fuelLeft") as? Int ?? tank
        fuelCount = d.object(forKey: "fuelCount") as? Int ?? 5
        weatherOn = d.object(forKey: "weatherOn") as? Bool ?? true
        radarOn = d.bool(forKey: "radarOn")
        satellite = d.bool(forKey: "satellite")
        terrain = d.bool(forKey: "terrain")
        transitLines = d.bool(forKey: "transitLines")
        avoidTolls = d.bool(forKey: "avoidTolls")
        avoidHighways = d.bool(forKey: "avoidHighways")
        noGoogle = d.bool(forKey: "noGoogle")
        speedCameras = d.object(forKey: "speedCameras") as? Bool ?? true
        plateCameras = d.object(forKey: "plateCameras") as? Bool ?? true
        watchCameras = d.object(forKey: "watchCameras") as? Bool ?? false
        // On for new users, except where warning of cameras is against the law.
        cameraWarnings = d.object(forKey: "cameraWarnings") as? Bool ?? !Self.camerasRestricted
        speedingAlert = d.bool(forKey: "speedingAlert")
        speedSlack = min(20, max(0, d.object(forKey: "speedSlack") as? Int ?? 5))
        parkingButton = d.object(forKey: "parkingButton") as? Bool ?? true
        hapticLevel = Haptics.Level(rawValue: d.string(forKey: "hapticLevel") ?? "") ?? .medium
        // Off until the person says yes on the Waze screen.
        waze = d.bool(forKey: "waze")
        wazeAsked = d.bool(forKey: "wazeAsked")
        wazeKinds = (d.stringArray(forKey: "wazeKinds")).map { Set($0.compactMap(WazeAlert.Kind.init(rawValue:))) }
            ?? [.police, .accident, .hazard, .weather]
        wazeOnMap = d.object(forKey: "wazeOnMap") as? Bool ?? true
        wazeVoice = d.object(forKey: "wazeVoice") as? Bool ?? true
        wazeHeatmap = d.bool(forKey: "wazeHeatmap")
        wazeMaxAge = d.object(forKey: "wazeMaxAge") as? Int ?? 120
        policeRisk = d.object(forKey: "policeRisk") as? Bool ?? true
        policeAircraft = d.bool(forKey: "policeAircraft")
        home = d.data(forKey: "home").flatMap { try? JSONDecoder().decode(Place.self, from: $0) }
        work = d.data(forKey: "work").flatMap { try? JSONDecoder().decode(Place.self, from: $0) }
        parking = d.data(forKey: "parking").flatMap { try? JSONDecoder().decode(Place.self, from: $0) }
        welcomed = d.bool(forKey: "welcomed") || d.object(forKey: "saved") != nil
        defaultMode = TravelMode(rawValue: d.integer(forKey: "defaultMode")) ?? .drive
        saved = (d.data(forKey: "saved")).flatMap { try? JSONDecoder().decode([Place].self, from: $0) } ?? []
        recents = d.stringArray(forKey: "recents") ?? []
        recentPlaces = d.data(forKey: "recentPlaces").flatMap { try? JSONDecoder().decode([Place].self, from: $0) } ?? []
        // The car. The parts list is born with the usual suspects — oil, filters, brakes, timing
        // belt — ready to be filled in; it's only left empty when everything was deleted on purpose.
        carName = d.string(forKey: "carName") ?? ""
        carFuel = d.string(forKey: "carFuel") ?? "diesel"
        carConsumption = d.object(forKey: "carConsumption") as? Double ?? 6.5
        carOdometer = d.object(forKey: "carOdometer") as? Int ?? 0
        insuranceEnd = d.object(forKey: "insuranceEnd") as? Date
        inspectionEnd = d.object(forKey: "inspectionEnd") as? Date
        if let data = d.data(forKey: "carParts"), let parts = try? JSONDecoder().decode([CarPart].self, from: data) {
            carParts = parts
        } else {
            carParts = d.bool(forKey: "carPartsInit") ? [] : AppSettings.defaultCarParts
            d.set(true, forKey: "carPartsInit")
        }
        carBallOn = d.object(forKey: "carBallOn") as? Bool ?? true
        let sticker = d.object(forKey: "greenSticker") as? Bool ?? true
        greenSticker = sticker
        appleUser = d.string(forKey: "appleUser") ?? ""
        appleName = d.string(forKey: "appleName") ?? ""
        musicEnabled = d.stringArray(forKey: "musicEnabled") ?? ["apple"]
        musicActive = d.string(forKey: "musicActive") ?? "apple"
        musicExtras = d.data(forKey: "musicExtras").flatMap { try? JSONDecoder().decode([MusicExtra].self, from: $0) } ?? []
        Self.stickerOn = sticker
        Self.fuelKind = carFuel
        hapticLevel = Haptics.Level(rawValue: d.string(forKey: "hapticLevel") ?? "") ?? .medium
        // The OpenWeb Ninja key and counter from 0.7.3, no longer used: don't leave the key on the phone.
        for k in ["ninjaKey", "ninjaMonth", "ninjaUsed"] { d.removeObject(forKey: k) }
    }

    /** Countries where apps may not warn of speed cameras (France, Germany, Switzerland and a few more). */
    static var camerasRestricted: Bool {
        ["FR", "DE", "CH", "CY", "SK", "TR"].contains(Locale.current.regionCode ?? "")
    }

    private func save<T: Encodable>(_ v: T, _ key: String) {
        if let data = try? JSONEncoder().encode(v) { d.set(data, forKey: key) }
    }

    func setMusic(_ id: String, on: Bool) {
        var next = musicEnabled.isEmpty ? ["apple"] : musicEnabled
        if on {
            if !next.contains(id) { next.append(id) }
            musicActive = id
        } else {
            next.removeAll { $0 == id }
            if next.isEmpty { next = ["apple"] }
            if musicActive == id { musicActive = "apple" }
        }
        musicEnabled = next
    }

    /// Adds a service from a pasted link. Returns false when the link is not an address.
    func addMusicLink(name: String, link: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, let url = MusicCatalog.normalize(link) else { return false }
        let item = MusicExtra(id: UUID().uuidString, name: n, link: url)
        musicExtras.append(item)
        musicActive = item.id
        return true
    }

    func removeMusicLinks(at offsets: IndexSet) {
        let gone = offsets.map { musicExtras[$0].id }
        musicExtras.remove(atOffsets: offsets)
        if gone.contains(musicActive) { musicActive = "apple" }
    }

    var colorScheme: ColorScheme? {
        switch theme {
        case .system: return nil
        case .light: return .light
        case .dark, .black: return .dark
        }
    }

    /** Whether reports of this kind are wanted at all. */
    /** Waze belongs to Google, so "Use Apex without Google" turns it off too. */
    var wazeOn: Bool { waze && !noGoogle }

    /** Ask about Waze once: not to someone who chose no Google, since Waze is Google's. */
    var needsWazeChoice: Bool { !wazeAsked && !noGoogle }

    /** Waze still shares police reports, for the heat map and risk score (or the screenshot run's made-up ones). */
    var wazePolice: Bool { Waze.shares.contains(.police) || DemoScript.active }

    func wants(_ k: WazeAlert.Kind) -> Bool { wazeOn && wazeKinds.contains(k) }

    /** Whether this report should show and warn: a wanted kind, and not too old. */
    func shows(_ a: WazeAlert) -> Bool {
        wants(a.kind) && (wazeMaxAge == 0 || Date().timeIntervalSince(a.reportedAt) <= Double(wazeMaxAge) * 60)
    }

    func isSaved(_ p: Place) -> Bool { saved.contains { $0.id == p.id } }

    func toggleSaved(_ p: Place) {
        if let i = saved.firstIndex(where: { $0.id == p.id }) { saved.remove(at: i) } else { saved.insert(p, at: 0) }
    }

    func renameSaved(_ id: String, to name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, let i = saved.firstIndex(where: { $0.id == id }) else { return }
        saved[i].name = n
    }

    func addRecentPlace(_ p: Place) {
        guard !p.id.hasPrefix("pin:"), !p.id.hasPrefix("link:"), !p.id.hasPrefix("parking"), !p.id.hasPrefix("tap:"), !p.id.hasPrefix("demo") else { return }
        var slim = p
        slim.distanceMeters = nil
        slim.photoUrls = Array(p.photoUrls.prefix(1))
        slim.about = []
        slim.featuredReview = nil
        var r = recentPlaces.filter { $0.id != p.id && $0.name != p.name }
        r.insert(slim, at: 0)
        recentPlaces = Array(r.prefix(15))
    }

    func addRecent(_ q: String) {
        var r = recents.filter { $0.caseInsensitiveCompare(q) != .orderedSame }
        r.insert(q, at: 0)
        recents = Array(r.prefix(12))
    }
}

enum L {
    static func t(_ pl: String, _ de: String, _ en: String) -> String {
        switch AppSettings.shared.language {
        case "de": return de
        case "en": return en
        default: return pl
        }
    }
}
