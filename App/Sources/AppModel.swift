import Combine
import CoreLocation
import Foundation
import MapKit
import SwiftUI
import UIKit

/** The dock's pages. */
enum AppTab: Equatable {
    case map, saved, settings
}

/** Which of your places the "pick a place" sheet is choosing. */
enum PickKind: String, Identifiable {
    case home, work
    var id: String { rawValue }
}

enum SheetDetent: Equatable {
    case peek, half, full
}

enum SortMode: String, CaseIterable, Identifiable {
    case relevance = "Relevance", distance = "Distance", rating = "Rating"
    var id: String { rawValue }
}

struct Category: Identifiable, Hashable {
    let label: String
    let icon: String
    let query: String
    var id: String { label }

    /** British words where units are British: petrol, supermarkets, chemists, cash machines. */
    static var all: [Category] { Fmt.yards ? british : american }

    static let british = [
        Category(label: "Restaurants", icon: "fork.knife", query: "restaurants"),
        Category(label: "Coffee", icon: "cup.and.saucer.fill", query: "coffee"),
        Category(label: "Petrol", icon: "fuelpump.fill", query: "petrol station"),
        Category(label: "Supermarkets", icon: "cart.fill", query: "supermarket"),
        Category(label: "Pubs", icon: "mug.fill", query: "pub"),
        Category(label: "Hotels", icon: "bed.double.fill", query: "hotels"),
        Category(label: "Parking", icon: "parkingsign", query: "car park"),
        Category(label: "EV charging", icon: "bolt.car.fill", query: "ev charging station"),
        Category(label: "Chemists", icon: "cross.case.fill", query: "pharmacy"),
        Category(label: "Cash machines", icon: "banknote.fill", query: "atm"),
    ]

    static let american = [
        Category(label: "Restaurants", icon: "fork.knife", query: "restaurants"),
        Category(label: "Coffee", icon: "cup.and.saucer.fill", query: "coffee"),
        Category(label: "Gas", icon: "fuelpump.fill", query: "gas stations"),
        Category(label: "Groceries", icon: "cart.fill", query: "grocery stores"),
        Category(label: "Hotels", icon: "bed.double.fill", query: "hotels"),
        Category(label: "Parking", icon: "parkingsign", query: "parking"),
        Category(label: "Pharmacies", icon: "cross.case.fill", query: "pharmacy"),
        Category(label: "ATMs", icon: "banknote.fill", query: "atm"),
    ]
}

/** Directions to one place: routes for every mode, the one picked, and where from. */
struct DirectionsState {
    var destination: Place
    /** True when the trip goes from the place back to you. */
    var reversed = false
    var mode: TravelMode
    var routes: [TravelMode: [Route]] = [:]
    var loading: Set<TravelMode> = []
    var errors: [TravelMode: String] = [:]
    var selected = 0
    /** The Transit tab is showing (its trips come from Transitous, not the road routers). */
    /** Places to stop at on the way, in order. */
    var stops: [Place] = []
    var transit = false
    var trips: [TransitTrip]?
    var tripsError: String?
    /** Nil for "leave now". */
    var transitTime: Date?
    var arriveBy = false
    var trip = 0
    /// One line under the route title when the drive still has to enter a low-emission zone.
    var stickerNote: String?

    var current: [Route] { transit ? [] : routes[mode] ?? [] }
    var route: Route? { current.indices.contains(selected) ? current[selected] : current.first }
    var pickedTrip: TransitTrip? { transit ? trips.flatMap { $0.indices.contains(trip) ? $0[trip] : $0.first } : nil }
}

/** The whole app's state; the map and every sheet read it. */
@MainActor
final class AppModel: ObservableObject {
    let settings = AppSettings.shared
    let location: LocationService

    @Published var query = ""
    /** Autocomplete while typing: Google's, or OpenStreetMap's without Google. */
    @Published var suggestions = SuggestParser.Result()
    private var suggestTask: Task<Void, Never>?
    @Published var results: [Place] = []
    @Published var resultsTitle = ""
    @Published var selected: Place?
    @Published var searching = false
    /** The search box is open (so weather and fuel step aside to the left edge). */
    @Published var searchActive = false
    /** Something is showing in the strip under the search bar (a notice, a report, roadworks, a station). */
    var topBannerShowing: Bool { notice != nil || wazeInfo != nil || roadInfo != nil || fuelInfo != nil }
    @Published var notice: String?
    @Published var detent: SheetDetent = .half
    @Published var openNowOnly = false
    @Published var rating4Only = false
    @Published var sort: SortMode = .relevance
    @Published var directions: DirectionsState?
    @Published var nav: Navigator?
    @Published var showLayers = false
    /** Which page of the dock is open. */
    @Published var tab: AppTab = .map
    /** Live Waze reports in view, for the "Live from Waze" chip; nil until Waze answers. */
    @Published var wazeLiveCount: Int?
    /** The police risk around you (0 to 100), for the chip on the map. */
    @Published var areaRisk: Int?
    @Published var showSettings = false
    /** A Waze report tapped on the map, shown in a small card. */
    @Published var wazeInfo: WazeAlert?
    /** A roadworks sign or closure tapped on the map, or one coming up on the route, in a small card. */
    @Published var roadInfo: RoadEvent?
    /** A petrol station tapped on the map, and the cheapest one near you (for the chip). */
    @Published var fuelInfo: FuelStation?
    @Published var fuelBest: FuelStation?
    /** Forecourt prompt: are you filling up, and for how much. */
    @Published var pump: PumpAsk?
    private var pumpInside: String?
    /** The "Add stop" search sheet. */
    @Published var addingStop = false
    /** Places from Add stop, drawn on the map without changing the route yet. */
    @Published var stopPreviews: [Place] = []
    @Published var showSaved = false
    /** The sheet for choosing home or work by searching for it. */
    @Published var picking: PickKind?
    @Published var showSteps = false
    /** "Start" on a place: begin the drive as soon as its route arrives. */
    @Published var autoStart = false
    /** Bumped when the map should redraw overlays that don't come from a published value. */
    @Published var mapTick = 0
    /** Which way the map faces, for the compass button. */
    @Published var mapHeading: Double = 0
    /** Compass figure-eight, opened only from Settings › Trasy. */
    @Published var showCalibrate = false

    weak var map: MKMapView? { didSet { glide.map = map } }
    /** How wide the side panel is on a big screen (the open iPhone Duo), so the map centres
     *  things in the part you can see; 0 on a phone. */
    var sideInset: CGFloat = 0 { didSet { glide.leftInset = sideInset } }
    /** Moves the nav arrow and camera every frame between GPS fixes. */
    let glide = NavGlide()
    /** Bumped on every new route or transit request, so answers to an older one (before a
     *  reverse, a new stop or another time) are dropped instead of replacing the new ones. */
    private var routesRequest = 0
    private var transitRequest = 0
    private var searchTask: Task<Void, Never>?
    private var navSub: AnyCancellable?

    init() {
        location = LocationService()
        location.onUpdate = { [weak self] loc in self?.locationChanged(loc) }
    }

    var userLatLng: LatLng? {
        location.last.map { LatLng($0.coordinate.latitude, $0.coordinate.longitude) }
            ?? map?.userLocation.location.map { LatLng($0.coordinate.latitude, $0.coordinate.longitude) }
    }

    // MARK: Search

    var visibleResults: [Place] {
        var r = results
        if openNowOnly { r = r.filter { $0.openNow == true } }
        if rating4Only { r = r.filter { ($0.rating ?? 0) >= 4 } }
        switch sort {
        case .relevance: break
        case .distance: r.sort { ($0.distanceMeters ?? .infinity) < ($1.distanceMeters ?? .infinity) }
        case .rating: r.sort { ($0.rating ?? 0) > ($1.rating ?? 0) }
        }
        return r
    }

    var viewport: (center: LatLng, span: Double?) {
        guard let map, map.bounds.width > 0 else { return (userLatLng ?? LatLng(40.7484, -73.9857), nil) }
        let c = map.centerCoordinate
        let b = map.visibleCoordinateBounds
        let span = LatLng(b.sw.latitude, b.sw.longitude).distance(to: LatLng(b.ne.latitude, b.ne.longitude)) / 1.4
        return (LatLng(c.latitude, c.longitude), span.isFinite && span > 0 ? span : nil)
    }

    func search(_ text: String? = nil, title: String? = nil) {
        let q = (text ?? query).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        if title == nil, MapLinks.looksLikeLink(q) {
            openLink(q)
            return
        }
        query = title ?? q
        settings.addRecent(title ?? q)
        searchTask?.cancel()
        selected = nil
        directions = nil
        searching = true
        notice = nil
        openNowOnly = false
        rating4Only = false
        sort = .relevance
        let vp = viewport
        let useGoogle = !settings.noGoogle
        let user = userLatLng
        searchTask = Task {
            var r = await PlaceSearch.search(q, center: vp.center, spanMeters: vp.span, useGoogle: useGoogle)
            guard !Task.isCancelled else { return }
            // Distances read from you, not from the middle of the map.
            if let user {
                r.places = r.places.map { var p = $0; p.distanceMeters = user.distance(to: p.location); return p }
            }
            searching = false
            resultsTitle = title ?? q
            results = r.places
            if r.places.isEmpty {
                notice = Connectivity.explain("No results for \"\(q)\" here. Try another word, or move the map.")
            } else if r.googleError != nil && useGoogle {
                notice = "Google didn't answer, so these results are from OpenStreetMap."
            }
            if r.places.count == 1 {
                select(r.places[0])
            } else {
                detent = .half
                frame(r.places.map(\.location))
            }
        }
    }

    func typed(_ text: String) {
        suggestTask?.cancel()
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2, !MapLinks.looksLikeLink(q) else { suggestions = SuggestParser.Result(); return }
        let vp = viewport
        let useGoogle = !settings.noGoogle
        let user = userLatLng
        suggestTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            var r = SuggestParser.Result()
            if useGoogle {
                r = (try? await GoogleClient.shared.suggest(q, near: vp.center, spanMeters: vp.span ?? 20_000)) ?? r
            }
            if r.places.isEmpty && r.queries.isEmpty, let pc = await Postcodes.lookup(q) {
                // A UK postcode, like the Set home box finds: the open geocoder often misses them.
                r.places = [pc]
            }
            if r.places.isEmpty && r.queries.isEmpty {
                r.places = (try? await Photon.search(q, near: vp.center, limit: 8)) ?? []
            }
            guard !Task.isCancelled else { return }
            if let user {
                r.places = r.places.map { var p = $0; p.distanceMeters = user.distance(to: p.location); return p }
            }
            suggestions = r
        }
    }

    /** A pasted Google Maps, Waze or Apple Maps link (or coordinates): show the spot it points at. */
    func openLink(_ text: String) {
        searchTask?.cancel()
        suggestTask?.cancel()
        suggestions = SuggestParser.Result()
        selected = nil
        directions = nil
        results = []
        notice = nil
        searching = true
        query = "Opening link…"
        searchTask = Task {
            let target = await MapLinks.resolve(text)
            guard !Task.isCancelled else { return }
            searching = false
            switch target {
            case let .spot(point, name?)?:
                query = name
                resolve(Place(id: "link:\(point.lat),\(point.lng)", name: name, location: point, source: "osm"))
            case let .spot(point, nil)?:
                query = ""
                dropPin(at: point, name: "Shared location")
            case let .search(q, near)?:
                if let near, let map {
                    map.setCenter(CLLocationCoordinate2D(latitude: near.lat, longitude: near.lng), zoomLevel: 14, animated: false)
                }
                search(q)
            case nil:
                query = ""
                notice = Connectivity.explain("Couldn't find a location in that link.")
            }
        }
    }

    /** A place picked from the suggestions: show it now, then fill in its details from Google. */
    func openSuggestion(_ place: Place) {
        suggestTask?.cancel()
        // A search still loading would otherwise land afterwards and replace this place.
        searchTask?.cancel()
        searching = false
        notice = nil
        settings.addRecent(place.name)
        query = place.name
        results = []
        directions = nil
        resolve(place)
    }

    func clearSearch() {
        searchTask?.cancel()
        query = ""
        results = []
        resultsTitle = ""
        selected = nil
        searching = false
        notice = nil
    }

    func select(_ place: Place) {
        var p = place
        if !DemoScript.active { settings.addRecentPlace(place) }
        if p.distanceMeters == nil, let u = userLatLng { p.distanceMeters = u.distance(to: p.location) }
        selected = p
        detent = .half
        guard let map else { return }
        let target = CLLocationCoordinate2D(latitude: p.location.lat, longitude: p.location.lng)
        let pad = sideInset > 0 ? UIEdgeInsets(top: 0, left: sideInset, bottom: 0, right: 0)
                                : UIEdgeInsets(top: 120, left: 0, bottom: map.bounds.height * 0.45, right: 0)
        // About 900 m across, or what you already have when you're zoomed in closer than that.
        let nowMeters = map.visibleMapRect.width / MKMapPointsPerMeterAtLatitude(target.latitude)
        map.show(MKMapView.rect(around: target, meters: min(900, max(250, nowMeters))), padding: pad, animated: true)
    }

    func closePlace() {
        selected = nil
        if !results.isEmpty { detent = .half }
    }

    /** A tap on a place the basemap draws: show the route there at once, then fill in Google's name. */
    func resolveTapped(name: String, at point: LatLng) {
        var place = Place(id: "tap:\(point.lat),\(point.lng)", name: name, location: point, source: "osm")
        place.distanceMeters = userLatLng?.distance(to: point)
        openDirections(to: place)
        guard !settings.noGoogle else { return }
        let pid = place.id
        Task {
            let found = (try? await GoogleClient.shared.search(name, center: point, spanMeters: 1_000, pages: 1)) ?? []
            guard directions?.destination.id == pid else { return }
            if let best = found.filter({ $0.location.distance(to: point) < 150 })
                .min(by: { $0.location.distance(to: point) < $1.location.distance(to: point) }) {
                var b = best
                b.id = pid
                b.distanceMeters = userLatLng?.distance(to: b.location)
                directions?.destination = b
                if !DemoScript.active { settings.addRecentPlace(b) }
            }
        }
    }

    /** Show [placeholder] right away, then swap in Google's full place found at the same spot. */
    private func resolve(_ placeholder: Place) {
        var placeholder = placeholder
        let name = placeholder.name, point = placeholder.location
        placeholder.distanceMeters = userLatLng?.distance(to: point)
        select(placeholder)
        guard !settings.noGoogle else { return }
        let q = [name, placeholder.address].compactMap { $0 }.joined(separator: " ")
        let pid = placeholder.id
        Task {
            let found = (try? await GoogleClient.shared.search(q, center: point, spanMeters: 1_000, pages: 1)) ?? []
            guard selected?.id == pid else { return }
            if let best = found.filter({ $0.location.distance(to: point) < 150 })
                .min(by: { $0.location.distance(to: point) < $1.location.distance(to: point) }) {
                var b = best
                b.distanceMeters = userLatLng?.distance(to: b.location)
                selected = b
                if !DemoScript.active { settings.addRecentPlace(b) }
            }
        }
    }

    static let locationOffText = "Location is off for Navapp. Turn it on in Settings to get directions from where you are."

    // MARK: My places

    /** A Siri or Shortcuts request: directions home or to work, or back to the car. */
    func perform(_ kind: LaunchAction.Kind) async {
        // At a cold start, give location a few seconds to come in first.
        for _ in 0..<20 where userLatLng == nil { try? await Task.sleep(nanoseconds: 250_000_000) }
        if nav != nil { endNavigation() }
        let target: Place?
        switch kind {
        case .home: target = settings.home
        case .work: target = settings.work
        case .car: target = settings.parking
        }
        guard let target else {
            if kind == .car { notice = "No parking spot saved yet. Tap P on the map when you park." }
            else { picking = kind == .home ? .home : .work }
            return
        }
        openDirections(to: target)
        if kind == .car { directions?.mode = .walk }
    }

    /** Home, work, the parked car or a saved place, by id, for a tap on its map icon. */
    func myPlace(_ id: String) -> Place? {
        [settings.home, settings.work, settings.parking].compactMap { $0 }.first { $0.id == id }
            ?? settings.saved.first { $0.id == id }
    }

    func setHome(_ p: Place?) {
        settings.home = p.map { var h = $0; h.distanceMeters = nil; return h }
        if p != nil { notice = "Saved as your home." }
    }

    func setWork(_ p: Place?) {
        settings.work = p.map { var w = $0; w.distanceMeters = nil; return w }
        if p != nil { notice = "Saved as your work." }
    }

    /** Remember where the car is: here, now, with the street name when one is found. */
    func saveParking() {
        guard let me = userLatLng else {
            notice = location.denied ? "Location is off for Navapp. Turn it on in Settings to save where you parked." : "Still finding your location. Try again in a moment."
            return
        }
        var p = Place(id: "parking:\(Int(Date().timeIntervalSince1970))", name: "Parked car", location: me, source: "osm")
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        p.category = "Parked at \(f.string(from: Date()))"
        settings.parking = p
        notice = "Parking spot saved. Tap the P button to find your car."
        let pid = p.id
        Task {
            guard let found = await Photon.reverse(me), settings.parking?.id == pid else { return }
            settings.parking?.address = [found.name, found.address].compactMap { $0 }.joined(separator: ", ")
        }
    }

    func clearParking() {
        if selected?.id == settings.parking?.id { selected = nil }
        settings.parking = nil
    }

    /** Long press: a dropped pin with the address there. */
    func dropPin(at point: LatLng, name: String = "Dropped pin") {
        var pin = Place(id: "pin:\(point.lat),\(point.lng)", name: name, location: point, source: "osm")
        pin.category = String(format: "%.5f, %.5f", point.lat, point.lng)
        select(pin)
        Task {
            guard let found = await Photon.reverse(point), selected?.id == pin.id else { return }
            var p = pin
            p.address = [found.name, found.address].compactMap { $0 }.joined(separator: ", ")
            selected = p
        }
    }

    // MARK: Directions

    func openDirections(to place: Place) {
        autoStart = false
        directions = DirectionsState(destination: place, mode: settings.defaultMode)
        detent = .half
        loadAllModes()
    }

    func closeDirections() {
        autoStart = false
        directions = nil
        showSteps = false
        if let p = selected { select(p) }
    }

    func reverseDirections() {
        directions?.reversed.toggle()
        directions?.routes = [:]
        directions?.selected = 0
        directions?.trips = nil
        directions?.trip = 0
        loadAllModes()
    }

    func setMode(_ m: TravelMode) {
        directions?.transit = false
        directions?.mode = m
        directions?.selected = 0
        settings.defaultMode = m
        frameRoute()
    }

    func addStop(_ p: Place) {
        guard directions != nil, (directions?.stops.count ?? 0) < 8 else { return }
        stopPreviews = []
        directions?.stops.append(p)
        reloadRoutes()
    }

    /** Leave the sheet and drop these places on the map so the stop can be seen before it is added. */
    func showStopsOnMap(_ places: [Place]) {
        let pins = Array(places.prefix(30))
        guard !pins.isEmpty else { return }
        stopPreviews = pins
        addingStop = false
        frame(pins.map(\.location), bottomFraction: 0.42, top: 80)
    }

    func removeStop(_ i: Int) {
        guard let d = directions, d.stops.indices.contains(i) else { return }
        directions?.stops.remove(at: i)
        reloadRoutes()
    }

    /** 0 leave now, 1 depart at, 2 arrive by. */
    func setTransitTime(kind: Int, at date: Date) {
        directions?.transitTime = kind == 0 ? nil : date
        directions?.arriveBy = kind == 2
        loadTransit()
    }

    func showTransit() {
        directions?.transit = true
        frameRoute()
    }

    func selectTrip(_ i: Int) {
        directions?.trip = i
        frameRoute()
    }

    func selectRoute(_ i: Int) {
        directions?.selected = i
        mapTick += 1
    }

    func reloadRoutes() {
        guard directions != nil else { return }
        directions?.routes = [:]
        directions?.errors = [:]
        directions?.selected = 0
        loadAllModes()
    }

    private func loadAllModes() {
        guard let d = directions else { return }
        guard let me = userLatLng else {
            // Say so on the trip card itself, not just in passing.
            let why = location.denied ? Self.locationOffText : "Waiting for your location…"
            for m in TravelMode.allCases { directions?.errors[m] = why }
            directions?.tripsError = why
            directions?.trips = []
            if !location.denied {
                // GPS is on but hasn't answered yet: try again once it does.
                location.start()
                Task {
                    for _ in 0..<40 where userLatLng == nil { try? await Task.sleep(nanoseconds: 250_000_000) }
                    if userLatLng != nil, directions?.destination.id == d.destination.id, directions?.routes.isEmpty == true { reloadRoutes() }
                }
            }
            return
        }
        let (from, to) = d.reversed ? (d.destination.location, me) : (me, d.destination.location)
        let via = (d.reversed ? d.stops.reversed() : d.stops).map(\.location)
        routesRequest += 1
        let req = routesRequest
        let hw = settings.avoidHighways, tolls = settings.avoidTolls, google = !settings.noGoogle
        // Already driving (asked at a red light, say): no route that starts with a U-turn.
        let moving = location.last.flatMap { l in l.speed >= 4 && l.course >= 0 && l.courseAccuracy >= 0 && l.courseAccuracy < 45 ? l.course : nil }
        let heading = d.reversed ? nil : moving
        directions?.stickerNote = nil
        for m in TravelMode.allCases {
            directions?.loading.insert(m)
            Task {
                let r = await Directions.routes(from: from, to: to, mode: m, avoidHighways: hw, avoidTolls: tolls, useGoogle: google, via: via,
                                                heading: m == .drive ? heading : nil, alternatives: true)
                guard directions?.destination.id == d.destination.id, routesRequest == req else { return }
                directions?.loading.remove(m)
                var ranked = ClosureBoard.prefer(r.routes, mode: m)
                if m == .drive { ranked = easierFirst(ranked) }
                directions?.routes[m] = ranked
                if m == .drive { directions?.stickerNote = stickerLine(from: from, to: to, line: r.routes.first?.polyline ?? []) }
                if r.routes.isEmpty {
                    directions?.errors[m] = Connectivity.explain(r.error == "No route found." ? "No route found." : "Couldn't get a route just now. Try again in a moment.")
                }
                if m == directions?.mode {
                    frameRoute()
                    if autoStart, !r.routes.isEmpty {
                        autoStart = false
                        startNavigation()
                    }
                }
            }
        }
        loadTransit()
    }

    /// The green line under the route title. Says the zone is on the trip; it does not pretend the route avoids it.
    private func stickerLine(from: LatLng, to: LatLng, line: [LatLng]) -> String? {
        guard MindSettings.shared.umwelt,
              let z = RouteMind.umweltToShow(me: from, destination: to, line: line, along: 0, driving: false) else { return nil }
        if settings.mayEnterUmwelt {
            let kind = z.sticker == "SCT" ? "strefa czystego transportu" : "zielona plakietka"
            return "Wymagana \(kind) · \(z.name)"
        }
        return "Bez plakietki nie wjeżdżaj · \(z.name)"
    }

    /// When the switch is on, a slightly slower route with fewer left turns, U-turns and roundabouts wins.
    private func easierFirst(_ routes: [Route]) -> [Route] {
        guard MindSettings.shared.avoidHardJunctions, routes.count > 1 else { return routes }
        func hard(_ r: Route) -> Int {
            r.maneuvers.reduce(0) { n, m in
                switch m.type {
                case .uturn, .sharpLeft, .sharpRight: return n + 3
                case .roundabout: return n + ((m.exit ?? 1) > 2 ? 2 : 1)
                case .turnLeft: return n + 1
                default: return n
                }
            }
        }
        let fastest = routes.map(\.durationSeconds).min() ?? 0
        let cap = fastest + min(480, max(90, fastest * 0.2))
        guard let easy = routes.filter({ $0.durationSeconds <= cap }).min(by: { hard($0) < hard($1) }),
              let i = routes.firstIndex(where: { $0.id == easy.id }), i != 0 else { return routes }
        var out = routes
        out.remove(at: i)
        out.insert(easy, at: 0)
        return out
    }

    /** Transit trips for the current trip, leaving now or at the picked time. */
    func loadTransit() {
        guard let d = directions, let me = userLatLng else { return }
        let (from, to) = d.reversed ? (d.destination.location, me) : (me, d.destination.location)
        let destId = d.destination.id
        let time = d.transitTime, arriveBy = d.arriveBy
        transitRequest += 1
        let req = transitRequest
        directions?.trips = nil
        directions?.tripsError = nil
        directions?.trip = 0
        Task {
            do {
                let trips = try await Transitous.plan(from: from, to: to, time: time, arriveBy: arriveBy)
                guard directions?.destination.id == destId, transitRequest == req else { return }
                directions?.trips = trips
                if trips.isEmpty { directions?.tripsError = "No transit trips found here." }
            } catch {
                guard directions?.destination.id == destId, transitRequest == req else { return }
                directions?.trips = []
                directions?.tripsError = Connectivity.explain("Couldn't reach the transit planner.")
            }
            if directions?.transit == true { frameRoute() }
        }
    }

    func frameRoute() {
        if let t = directions?.pickedTrip {
            if t.path.count >= 2 { frame(t.path, bottomFraction: 0.42) }
            mapTick += 1
            return
        }
        guard let r = directions?.route else { mapTick += 1; return }
        frame(r.polyline, bottomFraction: 0.42, top: 170 + CGFloat(directions?.stops.count ?? 0) * 42)
    }

    /** Police risk within about a kilometre of you, from remembered and live Waze police reports. */
    func updateAreaRisk(live: [WazeAlert]) {
        let center = map.map { LatLng($0.centerCoordinate.latitude, $0.centerCoordinate.longitude) }
        guard settings.wazeOn, settings.policeRisk, settings.wazePolice, let here = userLatLng ?? center else { areaRisk = nil; return }
        let d = 0.0096 / max(cos(here.lat * .pi / 180), 0.2) * 0.62
        let line = [LatLng(here.lat, here.lng - d), LatLng(here.lat, here.lng + d)]
        let near = live.filter { $0.kind == .police && $0.location.distance(to: here) < 1_500 }.count
        areaRisk = PoliceRisk.score(ahead: line, past: WazeHistory.shared.reports, live: near, radius: 900)
    }

    // MARK: Navigation

    func startNavigation() {
        guard let d = directions, let route = d.route, !d.reversed else { return }
        let n = Navigator(route: route, destination: d.destination, stops: d.stops, settings: settings)
        nav = n
        navSub = n.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        n.onFinished = { [weak self, weak n] in
            guard let self, let n, self.nav === n else { return }
            self.endNavigation()
        }
        location.setNavigating(true, mode: route.mode.rawValue)
        NowPlay.shared.attach()
        map?.showsUserLocation = false
        if let loc = location.last { n.handle(loc); followCamera(n, loc, animated: false) }
    }

    func endNavigation() {
        nav?.stop()
        glide.stop()
        nav = nil
        navSub = nil
        location.setNavigating(false)
        map?.showsUserLocation = true
        directions = nil
        showSteps = false
        if pump?.simulated == true { pump = nil }
        resetCamera()
    }

    func recenterNav() {
        guard let n = nav else { return }
        n.following = true
        if let loc = location.last { followCamera(n, loc, animated: true) }
    }

    /** Show the whole remaining trip; the camera stops following until re-centered. */
    func overviewNav() {
        guard let n = nav else { return }
        n.following = false
        let line = n.progress.map { Geo.slice(n.route.polyline, from: $0.alongMeters, to: Geo.length(n.route.polyline)) } ?? n.route.polyline
        frame(line, bottomFraction: 0.25, top: 200)
    }

    private func locationChanged(_ loc: CLLocation) {
        watchPump(loc)
        guard let n = nav, !n.isCouch else { return }
        n.handle(loc)
        followCamera(n, loc, animated: true)
        mapTick += 1
    }

    /// On a forecourt: ask once. Leaving the station closes the card, whichever answer was showing.
    private func watchPump(_ loc: CLLocation) {
        if nav?.isCouch == true || settings.carFuel == "electric" { return }
        let here = LatLng(loc.coordinate.latitude, loc.coordinate.longitude)
        FuelPrices.shared.lookForVisit(here)
        let slow = loc.speed < 0 || loc.speed < 9
        if let st = FuelPrices.shared.nearestVisit(here, within: 75), slow || pumpInside == st.id {
            if pumpInside != st.id {
                pumpInside = st.id
                pump = PumpAsk(stationID: st.id, name: st.title, price: st.price, typing: false, simulated: false)
            }
            return
        }
        guard pumpInside != nil else { return }
        if FuelPrices.shared.nearestVisit(here, within: 140)?.id != pumpInside {
            pumpInside = nil
            pump = nil
        }
    }

    func pumpNo() { pump = nil }

    func pumpYes() {
        guard var ask = pump else { return }
        ask.typing = true
        pump = ask
    }

    /// Adds the filled litres to the tank, never past the tank size.
    func pumpAdd(litres: Double) {
        let room = max(0, settings.fuelTank - settings.fuelLeft)
        let put = min(room, max(0, Int(litres.rounded())))
        guard put > 0 else { pump = nil; return }
        settings.fuelLeft += put
        notice = "Dolano \(put) l · w baku \(settings.fuelLeft) l"
        pump = nil
    }

    private func followCamera(_ n: Navigator, _ loc: CLLocation, animated: Bool) {
        let p = n.progress
        let speed = max(0, loc.speed)
        var across = n.route.mode == .drive ? min(1400, max(450, 300 + speed * 30)) : 300
        // Close to a roundabout, zoom in so the whole of it and its exits fill the view.
        if n.nextManeuver?.type == .roundabout, let d = p?.distanceToNext, d < 350 { across = min(across, 380) }
        glide.fix(n, loc, across: across, jump: !animated)
    }

    // MARK: Map

    func centerOnUser() {
        guard let map, let loc = location.last ?? map.userLocation.location else {
            if location.denied { LocationService.openSettings() } else { location.start() }
            return
        }
        map.show(MKMapView.rect(around: loc.coordinate, meters: 1200),
                 padding: UIEdgeInsets(top: 0, left: sideInset, bottom: 0, right: 0), animated: true)
    }

    private func resetCamera() {
        guard let map else { return }
        let cam = map.camera.copy() as! MKMapCamera
        cam.pitch = 0
        cam.heading = 0
        map.setCamera(cam, animated: true)
    }

    func frame(_ points: [LatLng], bottomFraction: CGFloat = 0.45, top: CGFloat = 130) {
        guard let map, let first = points.first else { return }
        if points.count == 1 {
            let c = CLLocationCoordinate2D(latitude: first.lat, longitude: first.lng)
            map.show(MKMapView.rect(around: c, meters: 1200),
                     padding: UIEdgeInsets(top: 0, left: sideInset, bottom: 0, right: 0), animated: true)
            return
        }
        let start = MKMapPoint(CLLocationCoordinate2D(latitude: first.lat, longitude: first.lng))
        var rect = MKMapRect(x: start.x, y: start.y, width: 0, height: 0)
        for p in points.dropFirst() {
            let mp = MKMapPoint(CLLocationCoordinate2D(latitude: p.lat, longitude: p.lng))
            rect = rect.union(MKMapRect(x: mp.x, y: mp.y, width: 0, height: 0))
        }
        // Never closer than about 500 m across.
        let minSide = 500 * MKMapPointsPerMeterAtLatitude(first.lat)
        if rect.width < minSide { rect = rect.insetBy(dx: -(minSide - rect.width) / 2, dy: 0) }
        if rect.height < minSide { rect = rect.insetBy(dx: 0, dy: -(minSide - rect.height) / 2) }
        // With a side panel the cards are on the left, not at the bottom.
        let pad = sideInset > 0 ? UIEdgeInsets(top: 60, left: sideInset + 40, bottom: 60, right: 40)
                                : UIEdgeInsets(top: top, left: 40, bottom: map.bounds.height * bottomFraction + 20, right: 40)
        map.show(rect, padding: pad, animated: true)
    }

    /// Fetches a real drive and opens it on the map, without using the phone's GPS.
    func startCouch(_ scene: CouchScene, done: @escaping (String?) -> Void) {
        if nav != nil { endNavigation() }
        let leg = Self.couchLeg(scene)
        let google = !settings.noGoogle
        Task { @MainActor in
            let r = await Directions.routes(from: leg.from, to: leg.to, mode: .drive,
                                            avoidHighways: scene == .highways, avoidTolls: false,
                                            useGoogle: google, via: [], heading: nil, alternatives: false)
            guard let route = r.routes.first, route.polyline.count >= 2 else {
                done("Nie udało się pobrać trasy. Sprawdź sieć i stuknij jeszcze raz.")
                return
            }
            let dest = Place(id: "couch-\(scene.rawValue)", name: leg.place, location: leg.to, source: "sim")
            let n = Navigator(route: route, destination: dest, stops: [], settings: settings)
            let along = Self.couchAlong(scene, route.polyline)
            let built = Self.couchCards(scene, line: route.polyline, along: along, settings: settings)
            n.holdCouch(title: leg.title, along: along, notes: built.notes, chip: built.chip, speed: 22)
            self.nav = n
            self.navSub = n.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
            n.onFinished = { [weak self, weak n] in
                guard let self, let n, self.nav === n else { return }
                self.endNavigation()
            }
            self.location.setNavigating(true, mode: route.mode.rawValue)
            self.map?.showsUserLocation = false
            self.tab = .map
            let point = Geo.point(along: route.polyline, meters: along)
            let fix = CLLocation(coordinate: CLLocationCoordinate2D(latitude: point.lat, longitude: point.lng),
                                 altitude: 0, horizontalAccuracy: 5, verticalAccuracy: -1,
                                 course: n.progress?.routeBearing ?? -1, speed: 0, timestamp: Date())
            self.glide.fix(n, fix, across: 1400, jump: true)
            self.frame(route.polyline, bottomFraction: 0.28, top: 200)
            self.mapTick += 1
            if scene == .haptic {
                UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                }
            }
            if scene == .pump {
                self.pump = PumpAsk(stationID: "sim-aral", name: "Aral", price: 1.759, typing: false, simulated: true)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard self?.nav?.isCouch == true else { return }
                self?.frame(route.polyline, bottomFraction: 0.28, top: 200)
            }
            done(nil)
        }
    }

    private struct CouchLeg {
        var from: LatLng
        var to: LatLng
        var title: String
        var place: String
    }

    private static func couchLeg(_ scene: CouchScene) -> CouchLeg {
        switch scene {
        case .tunnel:
            return CouchLeg(from: LatLng(53.529, 9.986), to: LatLng(53.581, 9.882), title: "Elbtunnel", place: "Elbtunnel")
        case .border:
            return CouchLeg(from: LatLng(52.228, 10.974), to: LatLng(52.406, 16.925), title: "Granica DE–PL", place: "Poznań")
        case .umwelt:
            return CouchLeg(from: LatLng(52.172, 11.642), to: LatLng(52.120, 11.630), title: "Umwelt · Magdeburg", place: "Magdeburg")
        case .highways:
            return CouchLeg(from: LatLng(52.256, 11.508), to: LatLng(52.271, 11.856), title: "Bez autostrad", place: "Burg")
        case .junctions:
            return CouchLeg(from: LatLng(52.148, 11.618), to: LatLng(52.112, 11.639), title: "Trudne skrzyżowanie", place: "Centrum")
        case .detour:
            return CouchLeg(from: LatLng(52.230, 11.620), to: LatLng(52.263, 11.980), title: "Prawdziwy czas", place: "Objazd")
        case .wave:
            return CouchLeg(from: LatLng(52.142, 11.612), to: LatLng(52.128, 11.668), title: "Zielona fala", place: "Światła")
        case .haptic:
            return CouchLeg(from: LatLng(52.168, 11.628), to: LatLng(52.151, 11.671), title: "Wibracja", place: "Skręt")
        case .pump:
            return CouchLeg(from: LatLng(52.155, 11.632), to: LatLng(52.140, 11.655), title: "Stacja", place: "Aral")
        }
    }

    private static func couchAlong(_ scene: CouchScene, _ line: [LatLng]) -> Double {
        let total = Geo.length(line)
        switch scene {
        case .tunnel: return total * 0.42
        case .umwelt: return max(80, total - 1_200)
        case .border: return nearestAlong(line, LatLng(52.33, 14.45))
        case .highways, .junctions, .detour, .wave, .haptic, .pump: return total * 0.4
        }
    }

    private static func nearestAlong(_ line: [LatLng], _ target: LatLng) -> Double {
        let cum = Geo.cumulative(line)
        let total = cum.last ?? 0
        var best = total * 0.7
        var bestD = Double.greatestFiniteMagnitude
        var m = 0.0
        while m <= total {
            let d = Geo.point(along: line, meters: m, cumulative: cum).distance(to: target)
            if d < bestD { bestD = d; best = m }
            m += 500
        }
        return best
    }

    private static func couchCards(_ scene: CouchScene, line: [LatLng], along: Double, settings: AppSettings) -> (notes: [GuidanceNote], chip: CouchChip?) {
        let here = Geo.point(along: line, meters: along)
        switch scene {
        case .tunnel:
            let trust = MindSettings.shared.gpsTrust
            return ([GuidanceNote(title: "Tunel · czujniki",
                                  body: "Pozycja jedzie z czujników i jest trzymana na osi drogi. GPS gorszy niż \(trust) m, więc nie skacze na ulicę nad tunelem.",
                                  tone: "info")], nil)
        case .border:
            var notes: [GuidanceNote] = []
            notes.append(RouteMind.borderNote(near: here)
                         ?? GuidanceNote(title: "Granica", body: "Brak krótszej kolejki przy tym punkcie trasy.", tone: "info"))
            let tank = max(settings.fuelTank, 1)
            var left = settings.fuelLeft
            if settings.carFuel == "electric" || left * 10 >= tank * 9 { left = max(8, tank / 4) }
            if let fuel = RouteMind.borderFuelNote(here: here, destination: LatLng(52.406, 16.925),
                                                    tripMeters: Geo.length(line), fuelLeft: left, fuelTank: tank,
                                                    consumption: settings.carConsumption, electric: false) {
                notes.append(fuel)
            }
            return (notes, nil)
        case .umwelt:
            let probes = [here, LatLng(52.120, 11.630), LatLng(52.131, 11.639), LatLng(52.127, 11.615)]
            let hit = probes.compactMap { CityAtlas.hit($0) }.first
            let name = hit?.name ?? "Magdeburg"
            let blocked = !settings.mayEnterUmwelt
            let note = GuidanceNote(title: "Umweltzone \(name)", body: hit?.body ?? "Do wjazdu potrzebna zielona plakietka.", tone: "info")
            return ([note], CouchChip(name: name, blocked: blocked))
        case .highways:
            return ([GuidanceNote(title: "Unikaj autostrad",
                                  body: "Ta trasa idzie bocznymi drogami. Autostrady i bramki są poza nią.",
                                  tone: "info")], nil)
        case .junctions:
            return ([GuidanceNote(title: "Unikaj trudnych skrzyżowań",
                                  body: "Omijam wjazd bez świateł i skrzyżowanie, na którym trzeba przeciąć dwa pasy naraz.",
                                  tone: "info")], nil)
        case .detour:
            return ([GuidanceNote(title: "Prawdziwy czas objazdu",
                                  body: "Korek dodaje 6 min. Boczna droga jest szybsza o 4 min, więc ją biorę. Gdyby stała razem z resztą, zostałbym na trasie.",
                                  tone: "good")], nil)
        case .wave:
            return ([GuidanceNote(title: "Zielona fala · 45 km/h",
                                  body: "Tyle, żeby wjechać na następne światła na zielonym. Szybciej i tak złapiesz czerwone.",
                                  tone: "good")], nil)
        case .haptic:
            return ([GuidanceNote(title: "Wibracja przed skrętem",
                                  body: "Za około 80 m skręt. Telefon wibruje raz, bez głosu, żebyś nie musiał patrzeć.",
                                  tone: "info")], nil)
        case .pump:
            return ([GuidanceNote(title: "Stacja benzynowa",
                                  body: "Wjazd na stację. Pytanie jest na karcie: za ile i ile litrów. Cena przelicza euro na litry i dopisuje je do baku.",
                                  tone: "info")], nil)
        }
    }
}
