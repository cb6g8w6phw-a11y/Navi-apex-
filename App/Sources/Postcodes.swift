import Foundation

/**
 * British postcodes ("SW1A 1AA", "cf10 1ns") from postcodes.io: free, keyless, open data. OSM's
 * search finds few full postcodes, so a typed one goes here first.
 */
public enum Postcodes {
    /** The postcode in [query], normalized ("SW1A 1AA"), or nil. */
    public static func normalize(_ query: String) -> String? {
        let s = query.uppercased().filter { !$0.isWhitespace }
        guard s.range(of: #"^[A-Z]{1,2}[0-9][A-Z0-9]?[0-9][A-Z]{2}$"#, options: .regularExpression) != nil else { return nil }
        return String(s.dropLast(3)) + " " + String(s.suffix(3))
    }

    public static func lookup(_ query: String) async -> Place? {
        guard let code = normalize(query),
              let url = URL(string: "https://api.postcodes.io/postcodes/" + code.replacingOccurrences(of: " ", with: "%20")) else { return nil }
        var r = URLRequest(url: url)
        r.timeoutInterval = 10
        guard let (data, _) = try? await URLSession.shared.data(for: r) else { return nil }
        return parse(data, code: code)
    }

    static func parse(_ data: Data, code: String) -> Place? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let res = root["result"] as? [String: Any],
              let lat = res["latitude"] as? Double, let lng = res["longitude"] as? Double else { return nil }
        var p = Place(id: "postcode:\(code)", name: res["postcode"] as? String ?? code, location: LatLng(lat, lng), source: "postcodes.io")
        p.address = [res["admin_ward"], res["admin_district"], res["country"]].compactMap { $0 as? String }.joined(separator: ", ")
        p.category = "Postcode"
        return p
    }
}
