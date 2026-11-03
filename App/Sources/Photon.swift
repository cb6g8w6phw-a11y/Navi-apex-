import Foundation

/**
 * Photon, the OpenStreetMap geocoder (photon.komoot.io). Vela's no-Google search: it knows
 * names, cities and addresses, not categories like "pizza". Used when Google fails or finds nothing.
 */
public enum Photon {
    static let base = "https://photon.komoot.io/api/"
    static let langs: Set<String> = ["en", "de", "fr", "it"]
    static let userAgent = "VelaMaps-iOS/0.1 (+https://github.com/matteofx1/vela-ios)"

    public static func search(_ query: String, near: LatLng?, limit: Int = 20) async throws -> [Place] {
        var c = URLComponents(string: base)!
        var items = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: String(limit))]
        if let near {
            items.append(URLQueryItem(name: "lat", value: String(near.lat)))
            items.append(URLQueryItem(name: "lon", value: String(near.lng)))
        }
        let lang = Locale.current.language.languageCode?.identifier ?? "en"
        items.append(URLQueryItem(name: "lang", value: langs.contains(lang) ? lang : "en"))
        c.queryItems = items
        var r = URLRequest(url: c.url!)
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        r.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: r)
        return parse(data, near: near)
    }

    /** The address at a point, for a dropped pin. */
    public static func reverse(_ p: LatLng) async -> Place? {
        guard let url = URL(string: "https://photon.komoot.io/reverse?lat=\(p.lat)&lon=\(p.lng)&limit=1") else { return nil }
        var r = URLRequest(url: url)
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        r.timeoutInterval = 10
        guard let res = try? await URLSession.shared.data(for: r), var place = parse(res.0, near: nil).first else { return nil }
        place.location = p
        place.id = "pin:\(p.lat),\(p.lng)"
        return place
    }

    static func parse(_ data: Data, near: LatLng?) -> [Place] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = root["features"] as? [[String: Any]] else { return [] }
        return features.compactMap { f in
            guard let coords = (f["geometry"] as? [String: Any])?["coordinates"] as? [Double], coords.count >= 2,
                  let p = f["properties"] as? [String: Any] else { return nil }
            let loc = LatLng(coords[1], coords[0])
            func s(_ k: String) -> String? { p[k] as? String }
            let street = [s("housenumber"), s("street")].compactMap { $0 }.joined(separator: " ").nilIfBlank
            let locality = [s("city") ?? s("district"), s("state"), s("postcode")].compactMap { $0 }
                .joined(separator: ", ").nilIfBlank
            let named = s("name") != nil && s("osm_key") != "highway" && !(s("osm_key") == "place" && s("osm_value") == "house")
            guard let title = named ? s("name") : (street ?? s("name")) else { return nil }
            let osmId = (p["osm_id"] as? NSNumber)?.stringValue ?? "\(loc.lat),\(loc.lng)"
            var place = Place(id: "osm:\(s("osm_type") ?? "")\(osmId)", name: title, location: loc, source: "osm")
            place.category = named
                ? s("osm_value")?.replacingOccurrences(of: "_", with: " ").capitalizedFirst
                : "Address"
            place.address = [named ? street : nil, locality, s("country")].compactMap { $0 }.joined(separator: ", ").nilIfBlank
            place.distanceMeters = near?.distance(to: loc)
            return place
        }
    }
}

extension String {
    public var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
