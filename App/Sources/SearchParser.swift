import Foundation

/**
 * Reads Google's `/search?tbm=map` answer (port of Vela's SearchParser). The positions are
 * Vela's calibrated paths; each is relative to a result entry whose place node is `[1]`,
 * except `results` and `single`, which are relative to the response root.
 */
enum SearchParser {
    static let paths: [String: [Int]] = [
        "results": [64],
        "single": [0, 1, 0, 14],
        "atThisPlace": [0, 1, 0, 14, 68],
        "name": [1, 11],
        "lat": [1, 9, 2],
        "lng": [1, 9, 3],
        "address": [1, 39],
        "addressComponents": [1, 2],
        "category": [1, 13, 0],
        "rating": [1, 4, 7],
        "reviewCount": [1, 4, 8],
        "priceText": [1, 4, 2],
        "website": [1, 7, 0],
        "phone": [1, 178, 0, 0],
        "featureId": [1, 10],
        "placeId": [1, 78],
        "photos": [1, 72, 0],
        "featuredReview": [1, 142, 1, 0, 1, 0, 0],
        "about": [1, 100, 1],
        "editorialSummary": [1, 32, 1, 1],
        "openStatus": [1, 203, 1, 8, 0],
        "statusRich": [1, 203, 1, 4, 0],
        "status118": [1, 118, 0, 3, 1, 4, 0],
        "hours203": [1, 203, 0],
        "hours118": [1, 118, 0, 3, 0],
        "closedFlag": [1, 23],
    ]

    static func parse(root: Any, near: LatLng?) -> [Place] {
        let entries: [Any] =
            nonEmpty(arr(at(root, paths["results"]!)))
            ?? atThisPlaceEntries(root)
            ?? singleEntry(root)
            ?? []
        // Google's own order (its best match first), as Google Maps lists them; the Sort menu has Distance.
        var seen = Set<String>()
        return entries.compactMap { toPlace($0, near: near) }.filter { seen.insert($0.featureId ?? $0.id).inserted }
    }

    private static func nonEmpty(_ a: [Any]?) -> [Any]? {
        guard let a, !a.isEmpty else { return nil }
        return a
    }

    /** A specific or far address answers with one geocoded node instead of a list. */
    private static func singleEntry(_ root: Any) -> [Any]? {
        guard let node = at(root, paths["single"]!) else { return nil }
        let entry: [Any] = [NSNull(), node]
        return str(field(entry, "name")) == nil ? nil : [entry]
    }

    /** An address that is a business ("1020 Olive Dr" is an In-N-Out) lists the business. */
    private static func atThisPlaceEntries(_ root: Any) -> [Any]? {
        guard let list = arr(at(root, paths["atThisPlace"]!)) else { return nil }
        let entries: [Any] = list.compactMap { e in
            guard let node = at(e, 0) else { return nil }
            let entry: [Any] = [NSNull(), node]
            return str(field(entry, "name")) == nil ? nil : entry
        }
        return entries.isEmpty ? nil : entries
    }

    private static func field(_ entry: Any, _ key: String) -> Any? {
        at(entry, paths[key]!)
    }

    static func toPlace(_ entry: Any, near: LatLng?) -> Place? {
        guard let name = str(field(entry, "name")),
              let lat = dbl(field(entry, "lat")),
              let lng = dbl(field(entry, "lng")) else { return nil }
        let loc = LatLng(lat, lng)
        var p = Place(id: "g:\(str(field(entry, "featureId")) ?? "\(name)|\(Int(lat * 1e4))|\(Int(lng * 1e4))")",
                      name: name, location: loc, source: "google")
        p.category = str(field(entry, "category"))
        let components = arr(field(entry, "addressComponents"))?.compactMap { str($0) }
            .filter { $0.caseInsensitiveCompare(name) != .orderedSame }
        let joined = components.map { $0.joined(separator: ", ") }.flatMap { $0.isEmpty ? nil : $0 }
        p.address = (str(field(entry, "address")) ?? joined).map { stripNamePrefix($0, name: name) }
        p.rating = dbl(field(entry, "rating"))
        p.reviewCount = int(field(entry, "reviewCount"))
        p.priceText = str(field(entry, "priceText"))
        p.website = str(field(entry, "website"))
        p.phone = str(field(entry, "phone"))
        let rich = str(field(entry, "statusRich"))
        let s118 = str(field(entry, "status118"))
        let status = rich ?? s118 ?? str(field(entry, "openStatus"))
        p.statusText = status
        p.openNow = openNow(status)
        p.permanentlyClosed = int(field(entry, "closedFlag")) == 1
            || [rich, s118, str(field(entry, "openStatus"))].contains { $0?.localizedCaseInsensitiveContains("Permanently") == true }
        // Hours from the same block the status came from, so the two never disagree.
        let h203 = readHours(field(entry, "hours203"))
        let h118 = readHours(field(entry, "hours118"))
        p.hours = (rich == nil && s118 != nil) ? (h118.isEmpty ? h203 : h118) : (h203.isEmpty ? h118 : h203)
        p.photoUrls = photos(entry)
        p.featuredReview = str(field(entry, "featuredReview"))?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“” \n"))
            .nilIfBlank
        p.editorialSummary = str(field(entry, "editorialSummary"))?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        p.about = (arr(field(entry, "about")) ?? []).compactMap { s in
            guard let title = str(at(s, 1)) else { return nil }
            let items = (arr(at(s, 2)) ?? []).compactMap { str(at($0, 1))?.nilIfBlank }
            return items.isEmpty ? nil : AboutSection(title: title, items: items)
        }
        p.featureId = str(field(entry, "featureId"))
        p.placeId = str(field(entry, "placeId"))
        p.distanceMeters = near?.distance(to: loc)
        return p
    }

    /** Open or closed from the status text ("Open · Closes 9 PM", "Closed · Opens 5 AM").
     *  Closed words are tested first: "Opens 5 AM" starts like "Open" but means closed. */
    static func openNow(_ status: String?) -> Bool? {
        guard let s = status?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if ["Closed", "Opens", "Opening", "Temporarily", "Permanently"].contains(where: { s.hasPrefix($0) }) { return false }
        if ["Open", "Closes", "Closing"].contains(where: { s.hasPrefix($0) }) { return true }
        return nil
    }

    /** Seven days starting today; each day is name `[0]` and time ranges `[3][i][0]`. */
    static func readHours(_ days: Any?) -> [String] {
        (arr(days) ?? []).compactMap { day in
            guard let name = str(at(day, 0)) else { return nil }
            let ranges = (arr(at(day, 3)) ?? []).compactMap { str(at($0, 0))?.nilIfBlank }
            guard !ranges.isEmpty else { return nil }
            let note = str(at(day, 6, 1))?.nilIfBlank
            return "\(name): \(ranges.joined(separator: ", "))" + (note.map { " · \($0)" } ?? "")
        }
    }

    private static func photos(_ entry: Any) -> [String] {
        var out: [String] = []
        func add(_ u: String?) {
            guard let u, u.contains("googleusercontent") else { return }
            let sized = u.replacingOccurrences(of: #"=w\d+-h\d+.*$"#, with: "=w800-h600", options: .regularExpression)
            if !out.contains(sized) { out.append(sized) }
        }
        (arr(field(entry, "photos")) ?? []).forEach { add(str(at($0, 6, 0))) }
        (arr(at(entry, 1, 204, 0)) ?? []).forEach { add(str(at($0, 1, 2, 0, 0))) }
        return Array(out.prefix(12))
    }

    /** "Safeway, 1451 W Covell Blvd" reads the name twice under the title; drop the prefix. */
    static func stripNamePrefix(_ addr: String, name: String) -> String {
        guard !name.isEmpty, addr.lowercased().hasPrefix(name.lowercased()) else { return addr }
        let rest = addr.dropFirst(name.count)
        if let c = rest.first, c.isLetter || c.isNumber { return addr }
        let trimmed = rest.drop { $0 == " " }
        if let c = trimmed.first, !c.isNumber, !",·–-".contains(c) { return addr }
        let out = trimmed.drop { ",·–- ".contains($0) }
        return out.isEmpty ? addr : String(out)
    }
}

extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
