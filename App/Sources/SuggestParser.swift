import Foundation

/**
 * Google Maps' search-as-you-type answer (`/s?tbm=map&gs_ri=maps&suggest=p`), ported from Vela.
 * The body is `{"c":0,"d":")]}'\n<json>"}` plus a tail; <json> is `[[query, [rows...]], ...]`.
 * Each row holds a block whose first child is an array starting with a string: the title at
 * [0][0], the name at [1][0], the address at [2][0] and the position at [11][2..3]. A row with
 * no position is a plain query ("pizza near me").
 */
public enum SuggestParser {
    public struct Result: Sendable {
        public var places: [Place]
        public var queries: [String]
        public init(places: [Place] = [], queries: [String] = []) {
            self.places = places
            self.queries = queries
        }
    }

    static func parse(_ body: String, near: LatLng?) -> Result {
        guard let payload = unwrap(body), let root = GoogleJSON.parse(payload),
              let rows = arr(at(root, 0, 1)) else { return Result() }
        var out = Result()
        for row in rows {
            guard let block = (row as? [Any])?.first(where: { el in
                guard let a = el as? [Any], let first = a.first as? [Any] else { return false }
                return first.first is String
            }) else { continue }
            guard let title = str(at(block, 0, 0))?.nilIfBlank else { continue }
            let primary = str(at(block, 1, 0))?.nilIfBlank ?? title
            let secondary = str(at(block, 2, 0))?.nilIfBlank
            let lat = dbl(at(block, 11, 2)) ?? dbl(at(block, 13, 0, 3, 2))
            let lng = dbl(at(block, 11, 3)) ?? dbl(at(block, 13, 0, 3, 3))
            guard let lat, let lng else {
                out.queries.append(title)
                continue
            }
            let fid = str(at(block, 13, 0, 0)).flatMap { $0.range(of: #"^0x[0-9a-f]+:0x[0-9a-f]+$"#, options: .regularExpression) != nil ? $0 : nil }
            var p = Place(id: fid ?? String(format: "suggest:%.5f,%.5f", lat, lng), name: primary,
                          location: LatLng(lat, lng), source: "google")
            p.address = secondary == primary ? nil : secondary
            p.featureId = fid
            if let near { p.distanceMeters = near.distance(to: p.location) }
            out.places.append(p)
        }
        out.places = closeMatchesFirst(out.places, query: query(of: root))
        return out
    }

    /** What was typed, as Google echoes it at [0][0]. */
    static func query(of root: Any) -> String { str(at(root, 0, 0)) ?? "" }

    /**
     * Places whose name is close to what was typed come first, keeping Google's order otherwise.
     * Google sometimes puts a shop inside a place first ("The Body Shop, Whiteley Village" for
     * "Whiteley Shopping Centre"), so tapping the top row went to the wrong place.
     */
    static func closeMatchesFirst(_ places: [Place], query: String) -> [Place] {
        let q = words(query)
        guard !q.isEmpty else { return places }
        // 0: the name is what was typed; 1: most typed words are in it; 2: some; 3: none.
        func tier(_ p: Place) -> Int {
            let n = words(p.name)
            // The last word may still be being typed: "whiteley shop" matches "Shopping".
            let hits = q.enumerated().filter { i, w in
                n.contains(w) || (i == q.count - 1 && n.contains { $0.hasPrefix(w) })
            }.count
            if hits == q.count && hits == n.count { return 0 }
            let share = Double(hits) / Double(q.count)
            return share >= 0.6 ? 1 : (share > 0 ? 2 : 3)
        }
        return places.enumerated().map { (i: $0.offset, p: $0.element, t: tier($0.element)) }
            .sorted { $0.t != $1.t ? $0.t < $1.t : $0.i < $1.i }.map(\.p)
    }

    static func words(_ s: String) -> [String] {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\u{2019}", with: "")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .filter { !["the", "and", "of"].contains($0) }
    }

    /** The `d` string of the first `{...}` object in the body. */
    static func unwrap(_ body: String) -> String? {
        guard let start = body.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escape = false
        var end: String.Index?
        var i = start
        while i < body.endIndex {
            let c = body[i]
            if inString {
                if escape { escape = false } else if c == "\\" { escape = true } else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == "{" {
                depth += 1
            } else if c == "}" {
                depth -= 1
                if depth == 0 { end = i; break }
            }
            i = body.index(after: i)
        }
        guard let end, let data = String(body[start...end]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["d"] as? String
    }
}
