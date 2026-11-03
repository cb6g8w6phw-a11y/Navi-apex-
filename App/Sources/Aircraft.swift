import Foundation

/**
 * A police plane or helicopter overhead, from open ADS-B flight tracking (adsb.lol, with
 * airplanes.live as backup): keyless, community-run. Some police aircraft don't broadcast, so no
 * news isn't proof the sky is clear.
 */
public struct PoliceAircraft: Hashable, Sendable, Identifiable {
    public var id: String
    public var callsign: String?
    public var registration: String?
    public var operatorName: String?
    public var location: LatLng
    public var altitudeFeet: Double?
    public var speedKnots: Double?
    /** Heading over the ground, in degrees. */
    public var track: Double?
    public var helicopter: Bool

    public init(id: String, callsign: String? = nil, registration: String? = nil, operatorName: String? = nil,
                location: LatLng, altitudeFeet: Double? = nil, speedKnots: Double? = nil, track: Double? = nil,
                helicopter: Bool = false) {
        self.id = id
        self.callsign = callsign
        self.registration = registration
        self.operatorName = operatorName
        self.location = location
        self.altitudeFeet = altitudeFeet
        self.speedKnots = speedKnots
        self.track = track
        self.helicopter = helicopter
    }

    public var title: String { helicopter ? "Police helicopter" : "Police aircraft" }
}

public enum Aircraft {
    public static let endpoints = ["https://api.adsb.lol/v2", "https://api.airplanes.live/v2"]

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.httpAdditionalHeaders = ["User-Agent": "Kite-Maps (https://github.com/matteofx1/kite-maps)"]
        return URLSession(configuration: c)
    }()

    /** Words in an operator's name or callsign that mean police, in the languages drivers meet most. */
    static let policeWords = ["POLICE", "SHERIFF", "HIGHWAY PATROL", "STATE PATROL", "CONSTABULARY", "NPAS",
                              "LAW ENFORCEMENT", "POLIZEI", "POLIZIA", "POLICIA", "POLÍCIA", "GENDARMERIE",
                              "GUARDIA CIVIL", "CARABINIERI", "POLITIE", "POLIISI", "POLISI", "POLITI", "GARDA",
                              "MARECHAUSSEE", "PUBLIC SAFETY", "DEPT OF PUBLIC SAFETY"]
    /** Callsign starts used by police air units (Britain's NPAS flies as "NPAS" or "UKP"). */
    static let policeCallsigns = ["NPAS", "UKP", "POLICE", "SHERIFF"]

    public static func url(_ base: String, near p: LatLng, nauticalMiles: Int) -> URL {
        if base.contains("airplanes.live") {
            return URL(string: String(format: "%@/point/%.4f/%.4f/%d", base, p.lat, p.lng, nauticalMiles))!
        }
        return URL(string: String(format: "%@/lat/%.4f/lon/%.4f/dist/%d", base, p.lat, p.lng, nauticalMiles))!
    }

    /** Police aircraft within [nauticalMiles] of [p]. Nil when no tracker answered. */
    public static func police(near p: LatLng, nauticalMiles: Int = 15) async -> [PoliceAircraft]? {
        for base in endpoints {
            guard let (data, resp) = try? await session.data(from: url(base, near: p, nauticalMiles: nauticalMiles)),
                  (resp as? HTTPURLResponse)?.statusCode == 200, let list = parse(data) else { continue }
            return list
        }
        return nil
    }

    public static func isPolice(callsign: String?, operatorName: String?) -> Bool {
        let op = (operatorName ?? "").uppercased()
        if policeWords.contains(where: { op.contains($0) }) { return true }
        let cs = (callsign ?? "").uppercased().trimmingCharacters(in: .whitespaces)
        return policeCallsigns.contains { cs.hasPrefix($0) }
    }

    /** Every police aircraft in a readsb-style reply (`ac` list), ignoring ones on the ground. */
    public static func parse(_ data: Data) -> [PoliceAircraft]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let list = root["ac"] as? [[String: Any]] ?? root["aircraft"] as? [[String: Any]] ?? []
        return list.compactMap { a in
            guard let lat = (a["lat"] as? NSNumber)?.doubleValue, let lon = (a["lon"] as? NSNumber)?.doubleValue else { return nil }
            let callsign = (a["flight"] as? String)?.trimmingCharacters(in: .whitespaces)
            let op = a["ownOp"] as? String
            guard isPolice(callsign: callsign, operatorName: op) else { return nil }
            // "alt_baro" is a number in feet, or "ground".
            let alt = (a["alt_baro"] as? NSNumber)?.doubleValue
            if a["alt_baro"] as? String == "ground" { return nil }
            let type = (a["t"] as? String ?? "").uppercased()
            let desc = (a["desc"] as? String ?? "").uppercased()
            let heli = a["category"] as? String == "A7" || desc.contains("HELICOPTER")
                || ["EC35", "EC45", "EC30", "EC55", "EC135", "H135", "H145", "AS50", "AS55", "AS65", "B407", "B429", "B06", "A109", "A119", "A139", "R44", "MD52", "MD60"].contains(type)
            return PoliceAircraft(id: a["hex"] as? String ?? "\(lat),\(lon)", callsign: callsign?.isEmpty == true ? nil : callsign,
                                  registration: a["r"] as? String, operatorName: op, location: LatLng(lat, lon),
                                  altitudeFeet: alt, speedKnots: (a["gs"] as? NSNumber)?.doubleValue,
                                  track: (a["track"] as? NSNumber)?.doubleValue, helicopter: heli)
        }
    }
}
