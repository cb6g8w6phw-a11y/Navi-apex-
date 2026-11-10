import Foundation

/** Cost, range, parking, schools and the path under a bike or a walk. Real figures only. */
enum TripExtras {
    static func litres(km: Double, consumption: Double) -> Double {
        km * (consumption > 1 ? consumption : 7) / 100
    }

    static func rangeKm(litres: Int, consumption: Double) -> Double {
        Double(max(litres, 0)) / (consumption > 1 ? consumption : 7) * 100
    }

    /// Fuel for this route, or a warning when the tank will not reach the end.
    static func costLine(meters: Double, consumption: Double, litresLeft: Int, price: Double?) -> (text: String, short: Bool) {
        let km = meters / 1_000
        let need = litres(km: km, consumption: consumption)
        let range = rangeKm(litres: litresLeft, consumption: consumption)
        if litresLeft > 0, range + 1 < km {
            return ("Nie dojedziesz. W baku starczy na około \(Fmt.distance(range * 1_000)).", true)
        }
        let l = String(format: "%.1f", need).replacingOccurrences(of: ".", with: ",")
        if let price, price > 0.4 {
            let eur = (need * price).rounded()
            return ("Około \(l) l · \(Int(eur)) €", false)
        }
        return ("Około \(l) l paliwa", false)
    }

    static func sms(arrive: Date, place: String) -> URL? {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        let body = "Będę o \(f.string(from: arrive)) (\(place))."
        var c = URLComponents()
        c.scheme = "sms"
        c.queryItems = [URLQueryItem(name: "body", value: body)]
        return c.url
    }

    static func remember(id: String, minutes: Double) {
        guard minutes > 1 else { return }
        let hour = Calendar.current.component(.hour, from: Date())
        UserDefaults.standard.set(minutes, forKey: "commute-\(id)-\(hour)")
    }

    static func usual(id: String) -> String? {
        let hour = Calendar.current.component(.hour, from: Date())
        let m = UserDefaults.standard.double(forKey: "commute-\(id)-\(hour)")
        guard m > 1 else { return nil }
        return "ostatnio o tej godzinie \(Fmt.duration(m * 60))"
    }

    static func parking(near p: LatLng) async -> [Place] {
        guard var comps = URLComponents(string: "https://photon.komoot.io/api/") else { return [] }
        comps.queryItems = [
            URLQueryItem(name: "q", value: "Parkplatz"),
            URLQueryItem(name: "lat", value: String(p.lat)),
            URLQueryItem(name: "lon", value: String(p.lng)),
            URLQueryItem(name: "limit", value: "15"),
            URLQueryItem(name: "osm_tag", value: "amenity:parking"),
            URLQueryItem(name: "lang", value: "de"),
        ]
        guard let url = comps.url else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue(Photon.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return Photon.parse(data, near: p)
            .filter { $0.location.distance(to: p) < 2_000 && $0.location.distance(to: p) > 25 }
            .sorted { $0.location.distance(to: p) < $1.location.distance(to: p) }
    }

    /// How far along the route the nearest schools and kindergartens sit.
    static func schools(along line: [LatLng]) async -> [Double] {
        guard line.count >= 2 else { return [] }
        let step = max(1, line.count / 18)
        let pts = stride(from: 0, to: line.count, by: step).map { line[$0] }
        let coords = pts.map { String(format: "%.5f,%.5f", $0.lat, $0.lng) }.joined(separator: ",")
        let q = "[out:json][timeout:20];(node[\"amenity\"=\"school\"](around:80,\(coords));node[\"amenity\"=\"kindergarten\"](around:80,\(coords)););out body 40;"
        guard let data = await Overpass.query(q),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let els = root["elements"] as? [[String: Any]] else { return [] }
        let cum = Geo.cumulative(line)
        return els.compactMap { e -> Double? in
            guard let lat = e["lat"] as? Double, let lon = e["lon"] as? Double else { return nil }
            let hit = Geo.project(LatLng(lat, lon), on: line, cumulative: cum)
            return hit.offset < 45 ? hit.along : nil
        }.sorted()
    }

    /// Asphalt, gravel, steps and lights, for a bike or a walk. Nil for a drive, or when the map has nothing.
    static func pathNote(line: [LatLng], mode: TravelMode) async -> String? {
        guard mode != .drive, line.count >= 2 else { return nil }
        let step = max(1, line.count / 14)
        let pts = stride(from: 0, to: line.count, by: step).map { line[$0] }
        let coords = pts.map { String(format: "%.5f,%.5f", $0.lat, $0.lng) }.joined(separator: ",")
        let q = "[out:json][timeout:20];way[\"highway\"](around:18,\(coords));out tags 80;"
        guard let data = await Overpass.query(q),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let els = root["elements"] as? [[String: Any]], !els.isEmpty else { return nil }
        let softNames: Set = ["gravel", "ground", "dirt", "unpaved", "fine_gravel", "grass", "sand", "mud", "pebblestone", "compacted"]
        var hard = 0, soft = 0, steps = 0, lit = 0, dark = 0
        for e in els {
            let tags = e["tags"] as? [String: String] ?? [:]
            let s = (tags["surface"] ?? "").lowercased()
            if tags["highway"] == "steps" || s == "steps" { steps += 1 }
            else if softNames.contains(s) { soft += 1 }
            else if !s.isEmpty { hard += 1 }
            if tags["lit"] == "yes" { lit += 1 }
            if tags["lit"] == "no" { dark += 1 }
        }
        var bits: [String] = []
        if steps > 0 { bits.append("są schody") }
        if soft > 0, soft >= hard { bits.append("dużo szutru") }
        else if soft > 0 { bits.append("miejscami szuter") }
        else if hard > 0 { bits.append("nawierzchnia twarda") }
        let hour = Calendar.current.component(.hour, from: Date())
        if hour >= 20 || hour < 6 {
            if dark > lit, dark > 0 { bits.append("po zmroku część bez latarni") }
            else if lit > 0 { bits.append("w większości oświetlona") }
        }
        return bits.isEmpty ? nil : bits.joined(separator: " · ")
    }
}
