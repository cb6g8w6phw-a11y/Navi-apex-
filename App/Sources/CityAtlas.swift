import CoreLocation
import Foundation
import MapKit
import UIKit

/**
 * Real outlines, not boxes.
 *
 * Low-emission zones ship with the app (Umweltzone / Strefa Czystego Transportu and the other
 * zones in the bundled file): each ring is the real boundary, thinned so it still follows the
 * streets. Municipal borders for whatever is on screen come from OpenStreetMap: relation ids
 * first, then the real polygon for each city, cached on disk so the next drive draws them at once.
 *
 * Zone geometry: Tyremap europe-emission-zones (CC BY 4.0), itself from OpenStreetMap (ODbL).
 * City geometry: © OpenStreetMap contributors, ODbL.
 */
struct UmweltHere: Equatable {
    var name: String
    var sticker: String
    var body: String
}

final class CityRingOverlay: NSObject, MKOverlay {
    let rings: [[CLLocationCoordinate2D]]
    let stroke: UIColor
    let fill: UIColor
    let line: CGFloat
    let bounding: MKMapRect
    let center: CLLocationCoordinate2D

    var coordinate: CLLocationCoordinate2D { center }
    var boundingMapRect: MKMapRect { bounding }

    init(rings: [[CLLocationCoordinate2D]], stroke: UIColor, fill: UIColor, line: CGFloat) {
        self.rings = rings
        self.stroke = stroke
        self.fill = fill
        self.line = line
        var rect = MKMapRect.null
        var lat = 0.0, lon = 0.0, n = 0
        for ring in rings {
            for c in ring {
                let p = MKMapPoint(c)
                let dot = MKMapRect(x: p.x, y: p.y, width: 0, height: 0)
                rect = rect.isNull ? dot : rect.union(dot)
                lat += c.latitude
                lon += c.longitude
                n += 1
            }
        }
        bounding = rect.isNull ? MKMapRect.null : rect
        center = n > 0
            ? CLLocationCoordinate2D(latitude: lat / Double(n), longitude: lon / Double(n))
            : CLLocationCoordinate2D()
        super.init()
    }
}

final class CityRingRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let o = overlay as? CityRingOverlay else { return }
        let path = CGMutablePath()
        for ring in o.rings where ring.count >= 3 {
            var started = false
            for c in ring {
                let pt = point(for: MKMapPoint(c))
                if !started {
                    path.move(to: pt)
                    started = true
                } else {
                    path.addLine(to: pt)
                }
            }
            path.closeSubpath()
        }
        guard !path.isEmpty else { return }
        context.setLineJoin(.round)
        context.setLineCap(.round)
        context.addPath(path)
        context.setStrokeColor(UIColor(white: 0, alpha: 0.55).cgColor)
        context.setLineWidth((o.line + 2.4) / zoomScale)
        context.strokePath()
        context.addPath(path)
        context.setStrokeColor(o.stroke.cgColor)
        context.setLineWidth(o.line / zoomScale)
        context.strokePath()
        if o.fill.cgColor.alpha > 0.01 {
            context.addPath(path)
            context.setFillColor(o.fill.cgColor)
            context.fillPath(using: .evenOdd)
        }
    }
}

@MainActor
final class CityAtlas: ObservableObject {
    static let shared = CityAtlas()

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "city.outlines")
            rebuild()
        }
    }

    private(set) var revision = 0
    private(set) var cityDrawing: CityRingOverlay?
    private(set) var zoneDrawing: CityRingOverlay?
    var onChange: (() -> Void)?

    private struct LL: Sendable {
        var lat: Double
        var lon: Double
    }

    fileprivate struct Shape: Sendable {
        var id: Int
        var name: String
        var sticker: String?
        var polygons: [[[LL]]]
        var south: Double
        var west: Double
        var north: Double
        var east: Double
    }

    private struct Job {
        var id: Int
        var name: String
    }

    private var zones: [Shape] = []
    private var cities: [Int: Shape] = [:]
    private var jobs: [Job] = []
    private var queued = Set<Int>()
    private var askedCells = Set<String>()
    private var drawingKey = ""
    private var wait: Task<Void, Never>?
    private var pumping = false
    private var lastGeo = Date.distantPast
    private weak var lastMap: MKMapView?
    private var booted = false

    nonisolated private static let endpoints = [
        "https://overpass-api.de/api/interpreter",
        "https://lz4.overpass-api.de/api/interpreter",
        "https://overpass.kumi.systems/api/interpreter",
        "https://overpass.osm.ch/api/interpreter",
        "https://overpass.openstreetmap.fr/api/interpreter",
    ]

    private init() {
        enabled = UserDefaults.standard.object(forKey: "city.outlines") as? Bool ?? true
    }

    func warm() {
        guard !booted else { return }
        booted = true
        let disk = Self.cacheURL()
        Task {
            let packed = await Task.detached { Self.loadBundled() }.value
            let saved = await Task.detached { Self.loadCache(disk) }.value
            self.zones = packed
            for s in saved { self.cities[s.id] = s }
            self.rebuild()
        }
    }

    /// The map moved. Outlines already cached redraw at once; missing cities are fetched.
    func consider(_ map: MKMapView) {
        lastMap = map
        warm()
        guard enabled else { rebuild(); return }
        rebuild()
        wait?.cancel()
        let region = map.region
        let zoom = map.zoomLevel
        wait = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard !Task.isCancelled, let self else { return }
            if zoom >= 10 { await self.fetchIDs(region) }
            await self.pump(max: 5)
            if self.cities.isEmpty || !self.coversCenter(region.center) {
                await self.reverseCity(region.center)
            }
            self.rebuild()
        }
    }

    func zone(at p: LatLng) -> UmweltHere? {
        for z in zones {
            if p.lat < z.south || p.lat > z.north || p.lng < z.west || p.lng > z.east { continue }
            guard Self.contains(z, lat: p.lat, lon: p.lng) else { continue }
            let sticker = z.sticker ?? "zielona"
            let body: String
            if sticker == "SCT" {
                body = "Strefa czystego transportu. Sprawdź, czy auto może wjechać."
            } else if sticker == "zielona" {
                body = "Do wjazdu potrzebna zielona plakietka."
            } else {
                body = "Strefa niskiej emisji. Sprawdź naklejkę zanim wjedziesz."
            }
            return UmweltHere(name: z.name, sticker: sticker, body: body)
        }
        return nil
    }

    // MARK: Draw

    private func rebuild() {
        guard enabled, let map = lastMap else {
            let changed = cityDrawing != nil || zoneDrawing != nil
            cityDrawing = nil
            zoneDrawing = nil
            if changed { touch() }
            return
        }
        let b = map.visibleCoordinateBounds
        let padLat = (b.ne.latitude - b.sw.latitude) * 0.35
        let padLon = (b.ne.longitude - b.sw.longitude) * 0.35
        let s = b.sw.latitude - padLat, n = b.ne.latitude + padLat
        let w = b.sw.longitude - padLon, e = b.ne.longitude + padLon
        let cityHits = cities.values.filter { $0.north >= s && $0.south <= n && $0.east >= w && $0.west <= e }
        let zoneHits = zones.filter { $0.north >= s && $0.south <= n && $0.east >= w && $0.west <= e }
        let key = cityHits.map { "\($0.id)" }.sorted().joined(separator: ",")
            + "#" + zoneHits.map { "\($0.id)" }.sorted().joined(separator: ",")
        guard key != drawingKey else { return }
        drawingKey = key
        cityDrawing = Self.overlay(cityHits, stroke: UIColor(red: 0.85, green: 0.93, blue: 1, alpha: 0.95),
                                   fill: UIColor(red: 0.55, green: 0.75, blue: 1, alpha: 0.05), line: 1.6)
        zoneDrawing = Self.overlay(zoneHits, stroke: UIColor(red: 0.25, green: 0.9, blue: 0.5, alpha: 0.95),
                                   fill: UIColor(red: 0.2, green: 0.85, blue: 0.4, alpha: 0.07), line: 2.2)
        touch()
    }

    private func touch() {
        revision += 1
        onChange?()
    }

    nonisolated private static func overlay(_ shapes: [Shape], stroke: UIColor, fill: UIColor, line: CGFloat) -> CityRingOverlay? {
        var rings: [[CLLocationCoordinate2D]] = []
        for shape in shapes {
            for poly in shape.polygons {
                for ring in poly where ring.count >= 4 {
                    rings.append(ring.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) })
                }
            }
        }
        guard !rings.isEmpty else { return nil }
        return CityRingOverlay(rings: rings, stroke: stroke, fill: fill, line: line)
    }

    private func coversCenter(_ c: CLLocationCoordinate2D) -> Bool {
        let p = LatLng(c.latitude, c.longitude)
        return cities.values.contains { shape in
            p.lat >= shape.south && p.lat <= shape.north && p.lng >= shape.west && p.lng <= shape.east
                && Self.contains(shape, lat: p.lat, lon: p.lng)
        }
    }

    // MARK: Network

    private func fetchIDs(_ region: MKCoordinateRegion) async {
        let c = region.center
        let halfLat = min(max(region.span.latitudeDelta, 0.02), 0.55) / 2
        let halfLon = min(max(region.span.longitudeDelta, 0.02), 0.7) / 2
        let s = c.latitude - halfLat, n = c.latitude + halfLat
        let w = c.longitude - halfLon, e = c.longitude + halfLon
        let cell = String(format: "%.2f,%.2f,%.2f,%.2f", (s * 20).rounded() / 20, (w * 20).rounded() / 20,
                          (n * 20).rounded() / 20, (e * 20).rounded() / 20)
        guard askedCells.insert(cell).inserted else { return }
        let q = """
        [out:json][timeout:22];
        rel["boundary"="administrative"]["admin_level"~"^(4|6|7|8)$"](\(s),\(w),\(n),\(e));
        out tags;
        """
        guard let data = await Self.postOverpass(q) else {
            askedCells.remove(cell)
            return
        }
        let found = Self.parseIDs(data)
        for item in found where cities[item.id] == nil && !queued.contains(item.id) {
            queued.insert(item.id)
            jobs.append(Job(id: item.id, name: item.name))
        }
    }

    private func pump(max: Int) async {
        guard !pumping else { return }
        pumping = true
        defer { pumping = false }
        var left = max
        while left > 0, !jobs.isEmpty {
            let job = jobs.removeFirst()
            left -= 1
            if cities[job.id] != nil { continue }
            if let shape = await Self.polygon(id: job.id, name: job.name) {
                cities[shape.id] = shape
                saveCache()
                rebuild()
            } else {
                queued.remove(job.id)
            }
            try? await Task.sleep(nanoseconds: 180_000_000)
        }
    }

    private func reverseCity(_ center: CLLocationCoordinate2D) async {
        guard Date().timeIntervalSince(lastGeo) > 1.2 else { return }
        lastGeo = Date()
        var parts = URLComponents(string: "https://nominatim.openstreetmap.org/reverse")!
        parts.queryItems = [
            URLQueryItem(name: "format", value: "jsonv2"),
            URLQueryItem(name: "zoom", value: "10"),
            URLQueryItem(name: "polygon_geojson", value: "1"),
            URLQueryItem(name: "lat", value: String(center.latitude)),
            URLQueryItem(name: "lon", value: String(center.longitude)),
        ]
        guard let url = parts.url, let data = await Self.get(url) else { return }
        guard let shape = Self.parseNominatim(data) else { return }
        guard cities[shape.id] == nil else { return }
        cities[shape.id] = shape
        saveCache()
    }

    nonisolated private static func postOverpass(_ query: String) async -> Data? {
        let body = "data=" + (query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query)
        for endpoint in endpoints {
            guard let url = URL(string: endpoint) else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 26
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.setValue("ApexNav/0.7 (iOS navigation)", forHTTPHeaderField: "User-Agent")
            req.httpBody = body.data(using: .utf8)
            if let data = await send(req), Self.looksLikeOverpass(data) { return data }
        }
        return nil
    }

    nonisolated private static func polygon(id: Int, name: String) async -> Shape? {
        if let url = URL(string: "https://polygons.openstreetmap.fr/get_geojson.py?id=\(id)&params=0"),
           let data = await get(url),
           let shape = shapeFromGeoJSON(data, id: id, name: name, sticker: nil) {
            return shape
        }
        var parts = URLComponents(string: "https://nominatim.openstreetmap.org/lookup")!
        parts.queryItems = [
            URLQueryItem(name: "osm_ids", value: "R\(id)"),
            URLQueryItem(name: "format", value: "jsonv2"),
            URLQueryItem(name: "polygon_geojson", value: "1"),
        ]
        guard let url = parts.url, let data = await get(url) else { return nil }
        return parseNominatim(data, forcedID: id, forcedName: name)
    }

    nonisolated private static func get(_ url: URL) async -> Data? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 25
        req.setValue("ApexNav/0.7 (iOS navigation)", forHTTPHeaderField: "User-Agent")
        req.setValue("pl,de;q=0.8,en;q=0.6", forHTTPHeaderField: "Accept-Language")
        return await send(req)
    }

    nonisolated private static func send(_ req: URLRequest) async -> Data? {
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            guard data.count > 20, data.count < 8_000_000 else { return nil }
            return data
        } catch {
            return nil
        }
    }

    // MARK: Parse

    nonisolated private static func looksLikeOverpass(_ data: Data) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        if obj["remark"] != nil { return false }
        return obj["elements"] != nil
    }

    nonisolated private static func parseIDs(_ data: Data) -> [(id: Int, name: String)] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = obj["elements"] as? [[String: Any]] else { return [] }
        var out: [(Int, String)] = []
        for el in elements {
            guard let id = el["id"] as? Int ?? (el["id"] as? NSNumber)?.intValue,
                  let tags = el["tags"] as? [String: Any],
                  let name = tags["name"] as? String, !name.isEmpty else { continue }
            let level = (tags["admin_level"] as? String) ?? ""
            let place = (tags["place"] as? String) ?? ""
            guard keep(name: name, level: level, place: place) else { continue }
            out.append((id, name))
        }
        return out
    }

    /// Towns and cities. Counties and boroughs are not a city outline.
    nonisolated private static func keep(name: String, level: String, place: String) -> Bool {
        let low = name.lowercased()
        if low.contains("landkreis") || low.contains("powiat") || low.contains("okres")
            || low.contains("arrondissement") || low.contains("county") || low.contains("regierungsbezirk")
            || low.hasPrefix("kreis ") || low.contains(" kreis") { return false }
        switch level {
        case "8", "7": return true
        case "6":
            if place == "city" || place == "town" { return true }
            if low.contains("landkreis") || low.contains("kreis") || low.contains("powiat") || low.contains("okres") { return false }
            return name.count < 32
        case "4":
            return place == "city" || ["berlin", "hamburg", "bremen", "wien", "praha", "prague", "warszawa"].contains(low)
        default: return false
        }
    }

    nonisolated private static func parseNominatim(_ data: Data, forcedID: Int? = nil, forcedName: String? = nil) -> Shape? {
        let obj = try? JSONSerialization.jsonObject(with: data)
        let dict: [String: Any]?
        if let one = obj as? [String: Any] {
            dict = one
        } else if let arr = obj as? [[String: Any]] {
            dict = arr.first
        } else {
            dict = nil
        }
        guard let dict else { return nil }
        let id = forcedID ?? (dict["osm_id"] as? Int) ?? (dict["osm_id"] as? NSNumber)?.intValue ?? 0
        guard id != 0 else { return nil }
        let name = forcedName
            ?? (dict["name"] as? String)
            ?? ((dict["address"] as? [String: Any])?["city"] as? String)
            ?? ((dict["address"] as? [String: Any])?["town"] as? String)
            ?? ((dict["address"] as? [String: Any])?["village"] as? String)
            ?? "Miasto"
        guard let geo = dict["geojson"] else { return nil }
        let geoData = try? JSONSerialization.data(withJSONObject: geo)
        guard let geoData else { return nil }
        return shapeFromGeoJSON(geoData, id: id, name: name, sticker: nil)
    }

    nonisolated private static func shapeFromGeoJSON(_ data: Data, id: Int, name: String, sticker: String?) -> Shape? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let polys = polygons(from: obj)
        guard !polys.isEmpty else { return nil }
        return makeShape(id: id, name: name, sticker: sticker, polygons: polys)
    }

    nonisolated private static func loadBundled() -> [Shape] {
        guard let url = Bundle.main.url(forResource: "CityLines", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        var out: [Shape] = []
        for item in arr {
            let name = (item["name"] as? String) ?? "Strefa"
            let full = (item["full"] as? String) ?? name
            let sticker = item["sticker"] as? String
            let idKey = (item["id"] as? String) ?? full
            guard let polysAny = item["polys"] as? [Any] else { continue }
            var polys: [[[LL]]] = []
            for polyAny in polysAny {
                guard let ringsAny = polyAny as? [Any] else { continue }
                var rings: [[LL]] = []
                for ringAny in ringsAny {
                    guard let pts = ringAny as? [Any] else { continue }
                    var ring: [LL] = []
                    for p in pts {
                        guard let pair = p as? [Any], pair.count >= 2,
                              let lat = number(pair[0]), let lon = number(pair[1]) else { continue }
                        ring.append(LL(lat: lat, lon: lon))
                    }
                    if ring.count >= 4 { rings.append(ring) }
                }
                if !rings.isEmpty { polys.append(rings) }
            }
            if let shape = makeShape(id: stable(idKey), name: name, sticker: sticker, polygons: polys) {
                out.append(shape)
            }
        }
        return out
    }

    nonisolated private static func polygons(from obj: Any) -> [[[LL]]] {
        if let arr = obj as? [Any], let first = arr.first as? [String: Any], first["geojson"] != nil || first["type"] != nil {
            return polygons(from: first["geojson"] ?? first)
        }
        guard let dict = obj as? [String: Any] else { return [] }
        if let geom = dict["geometry"] { return polygons(from: geom) }
        if let geo = dict["geojson"] { return polygons(from: geo) }
        let type = dict["type"] as? String ?? ""
        guard let coords = dict["coordinates"] as? [Any] else { return [] }
        if type == "Polygon" { return [rings(from: coords)].compactMap { $0.isEmpty ? nil : $0 } }
        if type == "MultiPolygon" {
            return coords.compactMap { one -> [[LL]]? in
                guard let ringsAny = one as? [Any] else { return nil }
                let r = rings(from: ringsAny)
                return r.isEmpty ? nil : r
            }
        }
        return []
    }

    nonisolated private static func rings(from raw: [Any]) -> [[LL]] {
        var rings: [[LL]] = []
        for ringAny in raw {
            guard let pts = ringAny as? [Any] else { continue }
            var ring: [LL] = []
            for p in pts {
                guard let pair = p as? [Any], pair.count >= 2,
                      let lon = number(pair[0]), let lat = number(pair[1]) else { continue }
                ring.append(LL(lat: lat, lon: lon))
            }
            let thinned = thin(ring, maxCount: 420)
            if thinned.count >= 4 { rings.append(thinned) }
        }
        return rings
    }

    nonisolated private static func makeShape(id: Int, name: String, sticker: String?, polygons: [[[LL]]]) -> Shape? {
        var s = 90.0, w = 180.0, n = -90.0, e = -180.0
        var any = false
        for poly in polygons {
            for ring in poly {
                for p in ring {
                    any = true
                    s = min(s, p.lat); n = max(n, p.lat); w = min(w, p.lon); e = max(e, p.lon)
                }
            }
        }
        guard any else { return nil }
        return Shape(id: id, name: name, sticker: sticker, polygons: polygons, south: s, west: w, north: n, east: e)
    }

    nonisolated private static func thin(_ pts: [LL], maxCount: Int) -> [LL] {
        guard pts.count > maxCount else { return pts }
        var step = 0.00035
        var cur = pts
        while cur.count > maxCount && step < 0.08 {
            var out: [LL] = []
            var last: LL?
            for p in pts {
                if let l = last, hypot(p.lat - l.lat, p.lon - l.lon) < step { continue }
                out.append(p)
                last = p
            }
            if let f = pts.last {
                if let l = out.last, hypot(f.lat - l.lat, f.lon - l.lon) > 1e-7 { out.append(f) }
            }
            cur = out
            step *= 1.55
        }
        return cur
    }

    nonisolated private static func contains(_ shape: Shape, lat: Double, lon: Double) -> Bool {
        for poly in shape.polygons {
            guard let outer = poly.first, ringContains(outer, lat: lat, lon: lon) else { continue }
            let hole = poly.dropFirst().contains { ringContains($0, lat: lat, lon: lon) }
            if !hole { return true }
        }
        return false
    }

    nonisolated private static func ringContains(_ ring: [LL], lat: Double, lon: Double) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let yi = ring[i].lat, xi = ring[i].lon
            let yj = ring[j].lat, xj = ring[j].lon
            if (yi > lat) != (yj > lat) {
                let x = (xj - xi) * (lat - yi) / ((yj - yi) == 0 ? 1e-12 : (yj - yi)) + xi
                if lon < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    nonisolated private static func number(_ a: Any) -> Double? {
        if let d = a as? Double { return d }
        if let n = a as? NSNumber { return n.doubleValue }
        if let i = a as? Int { return Double(i) }
        return nil
    }

    nonisolated private static func stable(_ s: String) -> Int {
        var h = 5381
        for b in s.utf8 { h = ((h << 5) &+ h) &+ Int(b) }
        return h
    }

    // MARK: Disk

    private func saveCache() {
        let shapes = Array(cities.values)
        let url = Self.cacheURL()
        Task.detached {
            Self.writeCache(shapes, url)
        }
    }

    nonisolated private static func cacheURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Apex", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("city-outlines.json")
    }

    nonisolated private static func writeCache(_ shapes: [Shape], _ url: URL) {
        let kept = shapes.sorted { ($0.north - $0.south) * ($0.east - $0.west) > ($1.north - $1.south) * ($1.east - $1.west) }
            .prefix(400)
        var arr: [[String: Any]] = []
        for s in kept {
            let polys: [[[[Double]]]] = s.polygons.map { poly in
                poly.map { ring in ring.map { [$0.lat, $0.lon] } }
            }
            arr.append(["id": s.id, "name": s.name, "polys": polys])
        }
        guard let data = try? JSONSerialization.data(withJSONObject: arr) else { return }
        try? data.write(to: url, options: .atomic)
    }

    nonisolated private static func loadCache(_ url: URL) -> [Shape] {
        guard let data = try? Data(contentsOf: url),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        var out: [Shape] = []
        for item in arr {
            guard let id = item["id"] as? Int ?? (item["id"] as? NSNumber)?.intValue,
                  let name = item["name"] as? String,
                  let polysAny = item["polys"] as? [Any] else { continue }
            var polys: [[[LL]]] = []
            for polyAny in polysAny {
                guard let ringsAny = polyAny as? [Any] else { continue }
                var rings: [[LL]] = []
                for ringAny in ringsAny {
                    guard let pts = ringAny as? [Any] else { continue }
                    var ring: [LL] = []
                    for p in pts {
                        guard let pair = p as? [Any], pair.count >= 2,
                              let lat = number(pair[0]), let lon = number(pair[1]) else { continue }
                        ring.append(LL(lat: lat, lon: lon))
                    }
                    if ring.count >= 4 { rings.append(ring) }
                }
                if !rings.isEmpty { polys.append(rings) }
            }
            if let shape = makeShape(id: id, name: name, sticker: nil, polygons: polys) { out.append(shape) }
        }
        return out
    }
}
