import AudioToolbox
import AVFoundation
import CallKit
import CoreLocation
import Foundation
import OSLog
import UIKit

/**
 * One drive, walk or ride: follows the user along the route, speaks the turns, and reroutes
 * when they leave it.
 */
@MainActor
final class Navigator: ObservableObject {
    @Published private(set) var route: Route
    @Published private(set) var progress: RouteTracker.Progress? { didSet { LiveNav.shared.poke(self) } }
    @Published private(set) var rerouting = false { didSet { LiveNav.shared.poke(self) } }
    @Published private(set) var arrived = false { didSet { LiveNav.shared.poke(self) } }
    @Published var muted: Bool { didSet { if muted { speech.stopSpeaking(at: .immediate) } } }
    /** The camera follows the user until they pan the map. */
    @Published var following = true
    @Published private(set) var speedMps: Double = 0
    @Published private(set) var lastFix: CLLocation?
    /** A camera coming up within about twelve seconds, for the warning card. */
    @Published private(set) var cameraAhead: CameraAlert?
    /** A Waze report coming up on the route (police, a crash…), for its warning card. */
    @Published private(set) var wazeAhead: WazeAhead?
    /** How many Waze reports this drive warned about, for the arrival card. */
    @Published private(set) var wazeWarned = 0
    /** Roadworks, a closure or a warning coming up on the route (Autobahn API), for its card. */
    @Published private(set) var roadAhead: RoadAhead?
    /** A way round a closure ahead, waiting for the driver to take it or ignore it. */
    @Published private(set) var detourOffer: DetourOffer?
    /** The cheapest station just off the route in the next 80 km (Tankerkönig), for its chip. */
    @Published private(set) var fuelAhead: FuelAhead?
    /** How likely police are on the next few km, 0-100, when the risk score is on. */
    @Published private(set) var policeRisk: Int?
    /** The nearest police plane or helicopter within about 10 km, and how far it is. */
    @Published private(set) var aircraftNear: (aircraft: PoliceAircraft, meters: Double)?
    /** An average speed check the user is driving through, with their average so far. */
    @Published private(set) var averageCheck: AverageCheck?
    /** Traffic lights on the route, one per junction, drawn on the map like Waze. */
    @Published private(set) var routeSignals: [LatLng] = []
    /** A quiet note from the driving mind: fuel, border, green wave, tunnel. */
    @Published private(set) var guidance: GuidanceNote?
    /** Set while GPS is being carried by the sensors. */
    @Published private(set) var reckoningLabel: String?
    /** Couch test: the car stays on a fetched route and real GPS is ignored. */
    @Published private(set) var couch = false
    @Published private(set) var couchTitle = ""
    @Published private(set) var couchNotes: [GuidanceNote] = []
    @Published private(set) var couchChip: CouchChip?
    var isCouch: Bool { couch }

    let destination: Place
    /** Stops still ahead, in trip order; each is dropped once reached. */
    @Published private(set) var stops: [Place]
    private var tracker: RouteTracker
    private let speech = AVSpeechSynthesizer()
    private let speechDone = SpeechDone()
    private var rerouteSpokenAt = Date.distantPast
    private var toldNoSignal = false
    private var spokenStage: [Int: Int] = [:]
    private var stoppedNearEnd: Date?
    /** Today's traffic against the route's estimate, from the latest look (1 = as planned). */
    private var trafficScale = 1.0
    private var trafficAt = Date()
    private var trafficLoading = false
    private var cameraSpokenAt = Date.distantPast
    private var cameraSpokenLimit: Double?
    /** The car has been on the route at least once since it was planned. */
    private var joinedRoute = false
    private static let log = Logger(subsystem: "app.vela.ios", category: "voice")
    private let calls = CXCallObserver()
    /** A phone (or FaceTime, WhatsApp...) call is going on. */
    private var onCall: Bool { calls.calls.contains { !$0.hasEnded } }
    /** "left" or "right": which side of the road the place is, at the end of the route. */
    private var destinationSide: String? { route.mode == .drive ? Geo.sideAtEnd(destination.location, of: route.polyline) : nil }
    /** The whole route's road data has come in live, so what's remembered no longer stands in. */
    private var fullRoadData = false
    /** The limits came from the road matcher, which knows every road on the route. */
    private var matchedLimits = false
    /** The roads the route really drives, from the road matcher (empty until it answers). */
    private var matchedWays: [Overpass.LimitWay] = []

    /**
     * Cameras on the roads the route drives, not the other side of a dual carriageway: OSM maps
     * one per carriageway, about 30 m apart on the M27, which is close enough to the route to
     * count. Without the matched roads, all are kept.
     */
    private func onOurSide(_ cams: [(camera: RoadCamera, along: Double)]) -> [(camera: RoadCamera, along: Double)] {
        guard !matchedWays.isEmpty else { return cams }
        return cams.filter { c in
            matchedWays.contains { w in
                w.line.count >= 2 && Geo.project(c.camera.location, on: w.line).offset < 15
            }
        }
    }
    /** Called a few minutes after arriving, to end the trip. */
    var onFinished: (() -> Void)?
    /** Steps already given a "Continue for 7 miles". */
    private var toldContinue: Set<Int> = []
    private var lastReroute = Date.distantPast
    /** Counts reroutes, so only the newest answer is used (adding a stop while one is loading). */
    private var rerouteRequest = 0
    /** Set once the trip is ended, so a late answer never talks or moves anything. */
    private var stopped = false
    private var avoidHighways: Bool
    private var avoidTolls: Bool
    private var routeCameras: [(camera: RoadCamera, along: Double)] = []
    /** Cameras already warned about, by OSM id: the list is replaced as road data comes in, so not by place in it. */
    private var spokenCameras: Set<Int64> = []
    private var zones: [AverageSpeedZone] = []
    private var zoneEntry: (index: Int, time: Date, along: Double)?
    private var demoAlerts = false
    private var speeding = SpeedingAlerts()
    private var routeWaze: [(alert: WazeAlert, along: Double)] = []
    /** Reports already warned about, by Waze's id, so a refresh doesn't warn again. */
    private var spokenWaze: Set<String> = []
    /** Road events on this route, in order, with where each starts and ends along it. */
    private var routeRoad: [(event: RoadEvent, start: Double, end: Double)] = []
    private var routeRoadKey = ""
    private var spokenRoad: Set<String> = []
    private var detourTried: Set<String> = []
    private var detourLoading = false
    private var fuelCheckedAt = Date.distantPast
    private var fuelAlong: Double = 0
    private var fuelDismissed: Set<String> = []
    private var wazeAt = Date.distantPast
    private var wazeLoading = false
    /** Drivers' reports (police, crashes, hazards...) from Waze's app servers, asked every 90 seconds. */
    @Published private(set) var liveAlerts: [WazeAlert] = []
    private var liveAt = Date.distantPast
    /** Closures from the live map, kept for when it doesn't answer. */
    private var closureAlerts: [WazeAlert] = []
    private var riskAt = Date.distantPast
    private var riskPast: [PoliceRisk.Report]?
    private var riskSpokenAt = Date.distantPast
    private var aircraftAt = Date.distantPast
    private var aircraftLoading = false
    private var spokenAircraft: Set<String> = []
    private let reckoning = DeadReckoning()
    private var mindAt = Date.distantPast
    private var hapticTurnAt = -1.0

    init(route: Route, destination: Place, stops: [Place] = [], settings: AppSettings) {
        self.route = route
        self.destination = destination
        self.stops = stops
        tracker = RouteTracker(route: route)
        muted = !settings.voice
        avoidHighways = settings.avoidHighways
        avoidTolls = settings.avoidTolls
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
        NowPlay.shared.prepareForVoice()
        UIApplication.shared.isIdleTimerDisabled = true
        speech.delegate = speechDone
        let first = route.maneuvers.first { $0.type != .depart } ?? route.maneuvers.first
        loadCameras()
        loadWaze()
        loadRoundabouts()
        speak("Startuję trasę do \(destination.name). " + (first.map { "\($0.instruction)." } ?? ""))
        // That was the heads-up for the first step: don't say it again a moment later.
        if let f = first, f.alongMeters < 1500, let i = route.maneuvers.firstIndex(of: f) { spokenStage[i] = f.alongMeters < 100 ? 3 : f.alongMeters < 300 ? 2 : 1 }
    }

    /** The trip has been ended (the Live Activity must not start again). */
    var isStopped: Bool { stopped }

    func stop() {
        stopped = true
        LiveNav.shared.end()
        speech.stopSpeaking(at: .immediate)
        UIApplication.shared.isIdleTimerDisabled = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        reckoning.stop()
    }

    /** The posted limit where the user is now, in km/h. */
    var speedLimitKmh: Double? {
        demoLimitKmh ?? route.speedLimit(at: progress?.alongMeters ?? 0)
    }

    var nextManeuver: Maneuver? {
        if let demoManeuver { return demoManeuver }
        guard let i = progress?.nextIndex, i < route.maneuvers.count else { return route.maneuvers.first }
        return route.maneuvers[i]
    }

    /** The road being driven now, for the name under the arrow. */
    var currentRoad: String? {
        // The last step passed, a name change included.
        guard let along = progress?.alongMeters, let i = route.maneuvers.lastIndex(where: { $0.alongMeters <= along + 8 }) else { return nil }
        let road = route.maneuvers[i].road?.trimmingCharacters(in: .whitespaces)
        return road?.isEmpty == false ? road : nil
    }

    /** The one after next, for the "Then" line when two turns come close together. */
    var thenManeuver: Maneuver? {
        guard let i = progress?.nextIndex, let j = route.maneuvers[(i + 1)...].firstIndex(where: { !$0.silent }) else { return nil }
        let a = route.maneuvers[i], b = route.maneuvers[j]
        // Leaving a roundabout is part of the roundabout, not a turn of its own.
        if b.leavesRoundabout { return nil }
        return b.alongMeters - a.alongMeters < 300 ? b : nil
    }

    func handle(_ raw: CLLocation) {
        guard !couch else { return }
        guard !arrived else { return }
        let loc: CLLocation
        if route.mode == .drive, MindSettings.shared.deadReckoning {
            let fused = reckoning.fuse(raw, route: route.polyline)
            loc = fused.tunnel ? fused.location : raw
            reckoningLabel = fused.tunnel ? fused.label : nil
        } else {
            loc = raw
            reckoningLabel = nil
        }
        lastFix = loc
        // The build's screenshots keep their made-up speed.
        if !demoAlerts { speedMps = max(0, loc.speed) }
        var p = tracker.update(LatLng(loc.coordinate.latitude, loc.coordinate.longitude),
                               accuracy: max(loc.horizontalAccuracy, 5), heading: Self.heading(loc))
        // The arrival time follows the traffic as it changes on the way, not only as it was at the start.
        p.remainingSeconds *= trafficScale
        progress = p
        // Parked in a car park short of the pin, or on the far side of the building: that's
        // arriving too, or the trip (and full-power GPS) would never end.
        if loc.speed >= 0 && loc.speed < 1, p.remainingMeters < 150 {
            if stoppedNearEnd == nil { stoppedNearEnd = loc.timestamp }
        } else {
            stoppedNearEnd = nil
        }
        // Off the road into a car park (or right at the end): 20 seconds stopped. Still on the road
        // short of it, it could be a red light or a queue, so a minute and a half.
        let offRoad = p.offsetMeters > 20 || p.remainingMeters < 40
        let parked = stoppedNearEnd.map { loc.timestamp.timeIntervalSince($0) > (offRoad ? 20 : 90) } ?? false
        if p.arrived || parked {
            arrived = true
            speak("Jesteś na miejscu: \(destination.name)" + (destinationSide.map { ", po stronie \($0)." } ?? "."))
            // Parked, the phone goes in a pocket: let the screen sleep, and a few minutes on, end
            // the trip so full-power GPS doesn't run all day in the background.
            UIApplication.shared.isIdleTimerDisabled = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 180) { [weak self] in
                guard let self, self.arrived, !self.stopped else { return }
                self.onFinished?()
            }
            return
        }
        // Starting in a car park or a driveway, off the road the route begins on: that's not a
        // wrong turn, so no "Rerouting" every few seconds until the car has reached the route once
        // (or has clearly gone another way).
        if p.offsetMeters < 40 { joinedRoute = true }
        if p.offRoute && !rerouting && (joinedRoute || p.offsetMeters > 400) && Date().timeIntervalSince(lastReroute) > 8 {
            reroute(from: loc)
            return
        }
        announce(p)
        checkTraffic(p, loc)
        checkCameras(p)
        checkWaze(p)
        checkRoadEvents(p, loc)
        checkFuel(p)
        checkRisk(p)
        checkAircraft(loc)
        checkZones(p)
        checkStops(p)
        checkMind(p, loc)
        if route.mode == .drive, AppSettings.shared.speedingAlert,
           speeding.update(speedKmh: loc.speed >= 0 ? loc.speed * 3.6 : nil, limitKmh: speedLimitKmh, now: loc.timestamp.timeIntervalSince1970) {
            speak("Przekraczasz dozwoloną prędkość.")
        }
    }

    /** Fuel, border queue, Umwelt sticker, green-wave speed. Spoken only when the note changes. */
    private func checkMind(_ p: RouteTracker.Progress, _ loc: CLLocation) {
        guard route.mode == .drive else { guidance = nil; return }
        let mind = MindSettings.shared
        if mind.haptics, let m = nextManeuver {
            let d = m.alongMeters - p.alongMeters
            if d < 90, d > 35, abs(hapticTurnAt - m.alongMeters) > 1 {
                hapticTurnAt = m.alongMeters
                RouteMind.haptic(.rigid)
            }
        }
        guard Date().timeIntervalSince(mindAt) > 12 else { return }
        mindAt = Date()
        let here = LatLng(loc.coordinate.latitude, loc.coordinate.longitude)
        let next: GuidanceNote?
        if let label = reckoningLabel {
            next = GuidanceNote(title: label, body: "Pozycja jedzie z czujników i jest trzymana na osi drogi.", tone: "info")
        } else if mind.borderAssist, let note = RouteMind.borderNote(near: here) {
            next = note
        } else if mind.umwelt, let z = RouteMind.umwelt(at: here) {
            next = GuidanceNote(title: "Umweltzone \(z.name)", body: z.body, tone: "info")
        } else if mind.greenWave, let sig = routeSignals.first,
                  let kmh = RouteMind.greenWaveKmh(distanceMeters: Geo.project(sig, on: route.polyline).along - p.alongMeters,
                                                   secondsToGreen: 16, limit: speedLimitKmh ?? 50) {
            next = GuidanceNote(title: "Zielona fala \(Int(kmh)) km/h", body: "Tyle, żeby wjechać na światła na zielonym.", tone: "good")
        } else if let note = RouteMind.borderFuelNote(
            here: here, destination: destination.location, tripMeters: route.distanceMeters,
            fuelLeft: AppSettings.shared.fuelLeft, fuelTank: AppSettings.shared.fuelTank,
            consumption: AppSettings.shared.carConsumption,
            electric: AppSettings.shared.carFuel == "electric") {
            next = note
        } else {
            next = nil
        }
        if next != guidance {
            guidance = next
            if let next, !muted, AppSettings.shared.voice { speak(next.body) }
        }
    }

    /** "paliwo", "korek", "granica", "objazd", "koniec". */
    func applyVoice(_ text: String) {
        switch VoiceIntent.parse(text) {
        case .fuel:
            guidance = RouteMind.fuelNote(alongKm: (progress?.alongMeters ?? 0) / 1000, toBorderKm: 180)
        case .traffic:
            guidance = GuidanceNote(title: "Ruch", body: "Patrzę na falę na trasie, nie na sam kolor odcinka.", tone: "info")
        case .border:
            guidance = RouteMind.borderNote(near: lastFix.map { LatLng($0.coordinate.latitude, $0.coordinate.longitude) } ?? destination.location)
                ?? GuidanceNote(title: "Granica", body: "Brak kolejki w pobliżu tej trasy.", tone: "info")
        case .reroute:
            if MindSettings.shared.trueTime {
                guidance = GuidanceNote(title: "Prawdziwy czas", body: "Objazd tylko wtedy, gdy boczna droga naprawdę jedzie, a nie stoi z resztą.", tone: "info")
            }
        case .stop:
            guidance = GuidanceNote(title: "Koniec", body: "Zatrzymuję podpowiedzi.", tone: "info")
        case .unknown:
            guidance = GuidanceNote(title: "Nie złapałem", body: "Powiedz: paliwo, korek, granica albo objazd.", tone: "info")
        }
        if let guidance, !muted { speak("\(guidance.title). \(guidance.body)") }
    }

    /** A stop picked on the way (search along the route): go there first, then on. */
    func addStop(_ p: Place) {
        stops.insert(p, at: 0)
        speak("Dodaję postój: \(p.name).")
        if let fix = lastFix { reroute(from: fix, quiet: true) }
    }

    /** Says when a stop is reached (within 40 m of it along the route) and drops it. */
    private func checkStops(_ p: RouteTracker.Progress) {
        guard let next = stops.first else { return }
        let at = Geo.project(next.location, on: route.polyline)
        guard at.offset < 150, p.alongMeters >= at.along - 40 else { return }
        stops.removeFirst()
        speak("Jesteś w \(next.name). Jedź dalej do \(stops.first?.name ?? destination.name).")
    }

    /** Cameras and speed limits along the route, from OpenStreetMap, in one query per route. */
    /** The real shape of each roundabout ahead, for the picture in the banner. */
    private func loadRoundabouts() {
        guard route.mode != .walk else { return }
        let start = route
        Task {
            var r = start
            // Mini-roundabouts first: they add steps, so the layouts below line up with the steps as driven.
            if let withMinis = await Roundabouts.addMinis(to: r), self.route.id == r.id {
                self.useSteps(withMinis.maneuvers)
                r = self.route
            }
            guard r.maneuvers.contains(where: { $0.type == .roundabout }),
                  let drawn = await Roundabouts.apply(to: r), self.route.id == r.id, self.route.maneuvers.count == drawn.maneuvers.count else { return }
            // Only the roundabout layouts change; the line and steps are the same.
            for i in self.route.maneuvers.indices where i < drawn.maneuvers.count {
                self.route.maneuvers[i].roundabout = drawn.maneuvers[i].roundabout
            }
        }
    }

    /** New steps on the same route line: what was already said stays said, step by step. */
    private func useSteps(_ steps: [Maneuver]) {
        let old = route.maneuvers
        func moved(_ i: Int) -> Int? {
            guard i < old.count else { return nil }
            return steps.firstIndex { $0.alongMeters == old[i].alongMeters }
        }
        spokenStage = Dictionary(spokenStage.compactMap { k, v in moved(k).map { ($0, v) } }, uniquingKeysWith: max)
        toldContinue = Set(toldContinue.compactMap(moved))
        route.maneuvers = steps
        tracker = RouteTracker(route: route)
        if let loc = lastFix {
            var p = tracker.update(LatLng(loc.coordinate.latitude, loc.coordinate.longitude), accuracy: max(loc.horizontalAccuracy, 5))
            p.remainingSeconds *= trafficScale
            progress = p
        }
    }

    private func loadCameras() {
        routeCameras = []
        // Kept across a reroute: a camera already warned about isn't warned about again.
        cameraAhead = nil
        zones = []
        zoneEntry = nil
        averageCheck = nil
        routeSignals = []
        let s = AppSettings.shared
        guard route.mode == .drive else { return }
        let line = route.polyline, id = route.id
        let speed = s.speedCameras, plate = s.plateCameras
        fullRoadData = false
        matchedLimits = false
        matchedWays = []
        // Speed limits from the road matcher first: it answers in about a second.
        let matcher = Task { () -> Bool in
            let found = await Valhalla.speedLimits(along: line) { partial in
                await MainActor.run {
                    guard self.route.id == id, !partial.isEmpty else { return }
                    self.matchedLimits = true
                    self.route.speedLimits = partial
                }
            }
            guard let found, self.route.id == id, !found.limits.isEmpty else { return false }
            self.matchedLimits = true
            self.route.speedLimits = found.limits
            self.matchedWays = found.ways
            self.routeCameras = self.onOurSide(self.routeCameras)
            RoadCache.shared.add(ways: found.ways.filter { $0.kmh != nil }, cameras: [], signals: [])
            return true
        }
        // What's already known about these roads shows straight away; the live answer replaces it.
        func useKnown() async {
            let known = await Task.detached(priority: .userInitiated) { () -> (cams: [(camera: RoadCamera, along: Double)], limits: [SpeedLimit], signals: [LatLng]) in
                let k = RoadCache.shared.along(line)
                let cams = CameraAlerts.project(k.cameras.filter { $0.kind == .speed ? speed : plate }, on: line)
                return (cams, k.ways.isEmpty ? [] : Overpass.speedLimits(k.ways, on: line), k.signals)
            }.value
            // Only while the whole route's live answer hasn't come in yet.
            guard self.route.id == id, !self.fullRoadData else { return }
            if !known.limits.isEmpty, !self.matchedLimits { self.route.speedLimits = known.limits }
            self.routeCameras = self.onOurSide(known.cams)
            self.zones = CameraAlerts.averageZones(known.cams)
            self.routeSignals = known.signals
        }
        Task { await useKnown() }
        // A small question about the first few miles gets answered far sooner by a busy server than
        // the whole route (17 s against a minute or a time-out at night), so the limit shows early.
        let cum = Geo.cumulative(line)
        if (cum.last ?? 0) > 8000 {
            let start = Geo.slice(line, from: 0, to: 6000, cumulative: cum)
            Task {
                let limits = !(await matcher.value)
                guard await Overpass.alongRoute(start, speed: speed, plate: plate, limits: limits) != nil else { return }
                await useKnown()
            }
        }
        Task {
            // With the limits from the road matcher, Overpass is only asked for cameras and lights.
            let limits = !(await matcher.value)
            // The public Overpass servers are sometimes busy: try again a couple of times.
            var result = await Overpass.alongRoute(line, speed: speed, plate: plate, limits: limits)
            for _ in 0..<2 where result == nil && self.route.id == id {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                result = await Overpass.alongRoute(line, speed: speed, plate: plate, limits: limits)
            }
            guard let found = result, self.route.id == id else { return }
            self.fullRoadData = true
            self.routeCameras = self.onOurSide(CameraAlerts.project(found.cameras, on: line))
            if !self.matchedLimits { self.route.speedLimits = Overpass.speedLimits(found.ways, on: line) }
            self.zones = CameraAlerts.merge(found.zones, CameraAlerts.averageZones(self.routeCameras))
            self.routeSignals = found.signals
        }
    }

    private func checkCameras(_ p: RouteTracker.Progress) {
        guard !demoAlerts else { return }
        let meters = routeCameras.map(\.along)
        if let ahead = cameraAhead {
            // Keep the card up, counting down, until the camera is passed.
            if let next = meters.first(where: { $0 > p.alongMeters }), next - p.alongMeters < CameraAlerts.maxLead {
                var a = ahead
                a.meters = next - p.alongMeters
                cameraAhead = a
            } else {
                cameraAhead = nil
            }
        }
        let spoken = Set(routeCameras.indices.filter { spokenCameras.contains(routeCameras[$0].camera.id) })
        guard let i = CameraAlerts.due(cameraMeters: meters, traveled: p.alongMeters, speedMps: speedMps, spoken: spoken) else { return }
        // Cameras close together are one warning: OSM often maps one per direction, or a pole and its
        // sign, and the A33 at Redbridge got three warnings in ten seconds.
        for (j, m) in meters.enumerated() where m >= meters[i] && m - meters[i] < 200 { spokenCameras.insert(routeCameras[j].camera.id) }
        let cam = routeCameras[i].camera
        let ahead = meters[i] - p.alongMeters
        let limit = cam.kind == .speed ? (cam.maxspeedKmh ?? route.speedLimit(at: meters[i])) : nil
        cameraAhead = CameraAlert(kind: cam.kind, meters: ahead, startMeters: max(ahead, 1), limitKmh: limit)
        // Spoken for speed cameras only: number plate cameras are everywhere in Britain, and
        // saying each one would bury the turns. Those get the card alone.
        // A run of cameras (a smart motorway's gantries, every mile or so) is said once: after
        // that, the next ones at the same limit within a couple of minutes get the card and the chime.
        let repeatRun = Date().timeIntervalSince(cameraSpokenAt) < 150 && limit == cameraSpokenLimit
        if AppSettings.shared.cameraWarnings, cam.kind == .speed {
            chime()
            if !repeatRun {
                speak((cam.average ? "Odcinkowy pomiar prędkości" : "Fotoradar") + (limit.map { ", ograniczenie \(Fmt.spokenSpeed($0))." } ?? "."))
            }
            cameraSpokenAt = Date()
            cameraSpokenLimit = limit
        }
    }

    /** Live Waze reports along the route; asked again every 90 seconds, since they come and go. */
    private func loadWaze() {
        guard route.mode == .drive, AppSettings.shared.wazeOn, !wazeLoading, !demoAlerts else { return }
        wazeLoading = true
        wazeAt = Date()
        let line = route.polyline, id = route.id
        // Only the next 60 km: on a long drive the rest will have changed by the time you get there.
        let at = progress?.alongMeters ?? 0
        let window = Geo.slice(line, from: max(at - 200, 0), to: at + 60_000)
        let here = progress.map { Geo.point(along: line, meters: $0.alongMeters) } ?? line[0]
        let ahead = Geo.slice(line, from: max(at - 200, 0), to: at + 40_000)
        Task {
            // Closures from the live map; everything else from Waze's app servers, for the next 40 km.
            async let closures = Waze.alongRoute(window.count >= 2 ? window : line)
            let live = await WazeLive.shared.alongRoute(ahead.count >= 2 ? ahead : line, here: here)
            let found = await closures
            self.wazeLoading = false
            guard self.route.id == id else { return }
            if let found {
                WazeHistory.shared.record(found)
                self.closureAlerts = found
            }
            if let live {
                WazeHistory.shared.record(live)
                self.liveAlerts = live
                self.liveAt = Date()
            } else if !self.liveAlerts.isEmpty, Date().timeIntervalSince(self.liveAt) > 300 {
                // Waze hasn't answered for 5 minutes: don't keep warning about reports that may be long gone.
                self.liveAlerts = []
            }
            var merged: [String: WazeAlert] = [:]
            for a in self.closureAlerts + self.liveAlerts { merged[a.id] = a }
            self.routeWaze = Waze.project(Array(merged.values), on: line)
        }
    }

    private func checkWaze(_ p: RouteTracker.Progress) {
        guard !demoAlerts else { return }
        let s = AppSettings.shared
        if Date().timeIntervalSince(wazeAt) > 90 { loadWaze() }
        if let ahead = wazeAhead {
            // Keep the card up, counting down, until the report is passed.
            if let hit = routeWaze.first(where: { $0.alert.id == ahead.alert.id }), hit.along > p.alongMeters - 10 {
                var a = ahead
                a.meters = max(hit.along - p.alongMeters, 0)
                wazeAhead = a.meters > 0 ? a : nil
            } else {
                wazeAhead = nil
            }
        }
        guard s.wazeOn, speedMps >= CameraAlerts.movingFloor else { return }
        // A little earlier than a camera: police and crashes are worth more notice.
        let lead = min(max(speedMps * 20, 250), 1200)
        guard let next = routeWaze.first(where: {
            !spokenWaze.contains($0.alert.id) && s.shows($0.alert)
                && $0.along > p.alongMeters && $0.along - p.alongMeters <= lead
        }) else { return }
        // Reports a few meters apart are one warning.
        for w in routeWaze where abs(w.along - next.along) < 60 { spokenWaze.insert(w.alert.id) }
        let ahead = next.along - p.alongMeters
        wazeAhead = WazeAhead(alert: next.alert, meters: ahead, startMeters: max(ahead, 1))
        wazeWarned += 1
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        if s.wazeVoice {
            chime()
            // "Police reported ahead, in 400 yards."
            speak("\(String(next.alert.spoken.dropLast())), za \(Fmt.spokenDistance(ahead)).")
        }
    }

    /** The police risk for the next 3 km, worked out again every 20 seconds. */
    private func checkRisk(_ p: RouteTracker.Progress) {
        guard !demoAlerts else { return }
        let s = AppSettings.shared
        guard route.mode == .drive, s.wazeOn, s.policeRisk, s.wazePolice else { policeRisk = nil; return }
        guard Date().timeIntervalSince(riskAt) > 20 else { return }
        riskAt = Date()
        if riskPast == nil { riskPast = WazeHistory.shared.reports }
        let to = p.alongMeters + 3000
        let ahead = Geo.slice(route.polyline, from: p.alongMeters, to: to)
        let live = routeWaze.filter { $0.alert.kind == .police && s.shows($0.alert) && $0.along > p.alongMeters && $0.along < to }.count
        let score = PoliceRisk.score(ahead: ahead, past: riskPast ?? [], live: live)
        let was = policeRisk.map(PoliceRisk.level) ?? .low
        policeRisk = score
        // Like Highway Radar's hot zone sound: once when it turns high, at most every 10 minutes. Only
        // for a place police keep being seen; a live report already has its own warning.
        if PoliceRisk.level(score) == .high, was != .high, s.wazeVoice, Date().timeIntervalSince(riskSpokenAt) > 600,
           live == 0 || PoliceRisk.level(PoliceRisk.score(ahead: ahead, past: riskPast ?? [], live: 0)) == .high {
            riskSpokenAt = Date()
            speak("Przed tobą miejsce, gdzie często stoi policja.")
        }
    }

    /** Police aircraft near the user, asked every 30 seconds while driving. */
    private func checkAircraft(_ loc: CLLocation) {
        guard !demoAlerts else { return }
        guard route.mode == .drive, AppSettings.shared.policeAircraft else { aircraftNear = nil; return }
        let here = LatLng(loc.coordinate.latitude, loc.coordinate.longitude)
        if let near = aircraftNear { aircraftNear = (near.aircraft, near.aircraft.location.distance(to: here)) }
        guard !aircraftLoading, Date().timeIntervalSince(aircraftAt) > 30 else { return }
        aircraftLoading = true
        aircraftAt = Date()
        Task {
            let found = await Aircraft.police(near: here, nauticalMiles: 10)
            self.aircraftLoading = false
            guard let found, !self.stopped else { return }
            let me = self.lastFix.map { LatLng($0.coordinate.latitude, $0.coordinate.longitude) } ?? here
            let nearest = found.map { ($0, $0.location.distance(to: me)) }.filter { $0.1 < 10_000 }.min { $0.1 < $1.1 }
            self.aircraftNear = nearest.map { (aircraft: $0.0, meters: $0.1) }
            if let a = nearest?.0, !self.spokenAircraft.contains(a.id) {
                self.spokenAircraft.insert(a.id)
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                self.chime()
                self.speak("\(a.title) w pobliżu.")
            }
        }
    }

    /** Average speed checks: say when one starts and ends, and keep the user's average on screen. */
    private func checkZones(_ p: RouteTracker.Progress) {
        guard !demoAlerts else { return }
        let at = p.alongMeters
        let inside = zones.firstIndex { at >= $0.startMeters && at <= $0.endMeters }
        if let entry = zoneEntry, entry.index != inside {
            zoneEntry = nil
            averageCheck = nil
            if AppSettings.shared.cameraWarnings { speak("Koniec odcinkowego pomiaru prędkości.") }
        }
        guard let i = inside else { return }
        let z = zones[i]
        let limit = z.kmh ?? route.speedLimit(at: at)
        if zoneEntry == nil {
            zoneEntry = (i, Date(), at)
            if AppSettings.shared.cameraWarnings {
                chime()
                speak("Odcinkowy pomiar przez \(Fmt.spokenDistance(z.endMeters - at))" + (limit.map { ", ograniczenie \(Fmt.spokenSpeed($0))." } ?? "."))
            }
        }
        guard let entry = zoneEntry else { return }
        let secs = Date().timeIntervalSince(entry.time)
        let avg = secs > 5 ? (at - entry.along) / secs * 3.6 : speedMps * 3.6
        averageCheck = AverageCheck(limitKmh: limit, averageKmh: avg, metersLeft: z.endMeters - at)
    }

    /** For the build's screenshots: a camera coming up and an average speed check. */
    /** For the build's screenshots: the next turn swapped for a made-up one. */
    private(set) var demoManeuver: Maneuver?
    private var demoLimitKmh: Double?

    /** For the build's screenshots: the M27 roundabout at Park Gate, 6th exit, with its seven roads. */
    func showDemoRoundabout() {
        var m = Maneuver(type: .roundabout, instruction: "At the roundabout, take the 6th exit onto M27",
                         location: LatLng(50.87, -1.27), alongMeters: 0, distanceMeters: 400, road: "M27", laneHint: nil)
        m.exit = 6
        m.roundabout = RoundaboutShape(exits: [262, 300, 338, 20, 62, 108], taken: 5, entriesOnly: [150],
                                       clockwise: true, complete: true)
        demoManeuver = m
        objectWillChange.send()
    }

    func showDemoAlerts() {
        demoAlerts = true
        cameraAhead = CameraAlert(kind: .speed, meters: 180, startMeters: 400, limitKmh: 48.3)
        averageCheck = AverageCheck(limitKmh: 80.5, averageKmh: 77, metersLeft: 2400)
        // 38 in a 30, so the screenshots show the speed sign gone red.
        showDemoSpeed(limitKmh: 48.3, mph: 38)
    }

    /** For the build's screenshots: a made-up speed and limit. */
    func showDemoSpeed(limitKmh: Double, mph: Double) {
        demoAlerts = true
        demoLimitKmh = limitKmh
        speedMps = mph / 2.23694
    }

    /** Tapping the Waze card puts it away; the report still won't be warned about again. */
    func dismissWaze() { wazeAhead = nil }
    func dismissRoad() { roadAhead = nil; detourOffer = nil }

    func dismissFuel() {
        if let f = fuelAhead { fuelDismissed.insert(f.station.id) }
        fuelAhead = nil
    }

    /** The cheapest open station within 1.5 km of the route in the next 80 km, and what it saves on a fill-up
     *  compared with the others along the way. Looked at every 20 seconds; the distance counts down in between. */
    private func checkFuel(_ p: RouteTracker.Progress) {
        let s = AppSettings.shared
        guard route.mode == .drive, !demoAlerts, s.fuelOn, !s.fuelKey.isEmpty else {
            if fuelAhead != nil { fuelAhead = nil }
            return
        }
        let line = route.polyline
        guard line.count >= 2 else { return }
        FuelPrices.shared.refreshAhead(line: line, from: p.alongMeters)
        let here = p.alongMeters
        if var f = fuelAhead {
            f.meters = max(fuelAlong - here, 0)
            if f.meters < 60 { fuelAhead = nil } else if f != fuelAhead { fuelAhead = f }
        }
        guard Date().timeIntervalSince(fuelCheckedAt) > 20 else { return }
        fuelCheckedAt = Date()
        let list = FuelPrices.shared.ahead.filter { $0.open }
        guard !list.isEmpty else { return }
        let cum = Geo.cumulative(line)
        var found: [(station: FuelStation, along: Double, off: Double)] = []
        for st in list {
            var bestD = Double.greatestFiniteMagnitude
            var bestAlong = 0.0
            for (i, pt) in line.enumerated() where cum[min(i, cum.count - 1)] > here - 100 {
                // A cheap look first: most of the route is nowhere near.
                if abs(pt.lat - st.location.lat) > 0.03 || abs(pt.lng - st.location.lng) > 0.05 { continue }
                let d = pt.distance(to: st.location)
                if d < bestD { bestD = d; bestAlong = cum[min(i, cum.count - 1)] }
            }
            if bestD < 1_500, bestAlong > here + 300, bestAlong < here + 80_000 { found.append((st, bestAlong, bestD)) }
        }
        let shown = found.filter { !fuelDismissed.contains($0.station.id) }
        guard let best = shown.min(by: { $0.station.price < $1.station.price }) else { return }
        let average = found.map(\.station.price).reduce(0, +) / Double(found.count)
        let saving = (average - best.station.price) * Double(s.fuelTank)
        fuelAlong = best.along
        let fresh = FuelAhead(station: best.station, meters: best.along - here, offRoute: best.off, saving: saving > 0 ? saving : nil)
        if fresh != fuelAhead { fuelAhead = fresh }
    }

    /** Takes the way round a closure that was offered. */
    func acceptDetour() {
        guard let offer = detourOffer else { return }
        detourOffer = nil
        roadAhead = nil
        speak("Wybieram objazd.")
        adopt(offer.route)
    }

    // MARK: Roadworks, closures and warnings (Autobahn API)

    /** The events that sit on [line], each with where its stretch starts and ends along it. */
    private static func eventsAlong(_ line: [LatLng], _ events: [RoadEvent]) -> [(event: RoadEvent, start: Double, end: Double)] {
        let cum = Geo.cumulative(line)
        let lats = line.map(\.lat), lngs = line.map(\.lng)
        guard let minLat = lats.min(), let maxLat = lats.max(), let minLng = lngs.min(), let maxLng = lngs.max() else { return [] }
        let pad = 0.0004
        var found: [(event: RoadEvent, start: Double, end: Double)] = []
        for e in events {
            guard e.location.lat > minLat - 0.01, e.location.lat < maxLat + 0.01,
                  e.location.lng > minLng - 0.01, e.location.lng < maxLng + 0.01 else { continue }
            if e.id.hasPrefix("user-") {
                let hit = Geo.project(e.location, on: line, cumulative: cum)
                guard hit.offset < 80 else { continue }
                let top = cum.count - 1
                let at = min(max(hit.along, 0), cum[top])
                found.append((event: e, start: at, end: at))
                continue
            }
            var best = 0
            var bestD = Double.greatestFiniteMagnitude
            for (i, p) in line.enumerated() {
                let d = p.distance(to: e.location)
                if d < bestD { bestD = d; best = i }
            }
            let limit = 40.0
            guard bestD < limit else { continue }
            // The stretch is the part of the route inside the event's box, around the nearest point.
            var lo = best, hi = best
            if let x = e.extent {
                func inside(_ p: LatLng) -> Bool {
                    p.lng >= x.w - pad && p.lng <= x.e + pad && p.lat >= x.s - pad && p.lat <= x.n + pad
                }
                while lo > 0 && inside(line[lo - 1]) { lo -= 1 }
                while hi < line.count - 1 && inside(line[hi + 1]) { hi += 1 }
            }
            let top = cum.count - 1
            found.append((event: e, start: cum[min(lo, top)], end: cum[min(hi, top)]))
        }
        return found.sorted { $0.start < $1.start }
    }

    private func roadWords(_ e: RoadEvent) -> String {
        switch e.kind {
        case .closure: return e.id.hasPrefix("user-") && e.road == "Rower" ? "zamknięta ścieżka" : "zamknięcie drogi"
        case .roadworks: return e.blocked ? "roboty drogowe, droga zablokowana" : "roboty drogowe"
        case .warning: return "ostrzeżenie na drodze"
        }
    }

    private func checkRoadEvents(_ p: RouteTracker.Progress, _ loc: CLLocation) {
        let mine = ClosureBoard.shared.asEvents(for: route.mode)
        let official = (route.mode == .drive && !demoAlerts && AppSettings.shared.traffic) ? RoadEvents.shared.events : []
        let events = official + mine
        guard (route.mode == .drive || route.mode == .bike), !events.isEmpty else {
            if roadAhead != nil { roadAhead = nil }
            if detourOffer != nil { detourOffer = nil }
            return
        }
        let line = route.polyline
        guard line.count >= 2 else { return }
        let key = "\(route.id)-\(events.count)-\(RoadEvents.shared.updatedAt.timeIntervalSince1970)-\(ClosureBoard.shared.revision)"
        if key != routeRoadKey {
            routeRoadKey = key
            routeRoad = Self.eventsAlong(line, events)
        }
        let here = p.alongMeters

        // The card on screen keeps counting down, and goes once the stretch is behind.
        if let shown = roadAhead {
            if let item = routeRoad.first(where: { $0.event.id == shown.event.id }), item.end > here - 20 {
                var a = shown
                a.meters = max(item.start - here, 0)
                a.left = here >= item.start ? max(item.end - here, 0) : nil
                if a != shown { roadAhead = a }
            } else {
                roadAhead = nil
                detourOffer = nil
            }
        }

        if roadAhead == nil, speedMps >= CameraAlerts.movingFloor {
            let lead = min(max(speedMps * 45, 1000), 3000)
            if let next = routeRoad.first(where: { !spokenRoad.contains($0.event.id) && $0.end > here && $0.start - here <= lead }) {
                spokenRoad.insert(next.event.id)
                let meters = max(next.start - here, 0)
                let length = next.end - next.start
                roadAhead = RoadAhead(event: next.event, meters: meters, startMeters: max(meters, 1), length: length,
                                      left: here >= next.start ? max(next.end - here, 0) : nil)
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                chime()
                var words = "\(roadWords(next.event)) przed tobą"
                if meters > 100 { words += ", za \(Fmt.spokenDistance(meters))" }
                if length >= 300 { words += ", przez \(Fmt.spokenDistance(length))" }
                speak(words + ".")
            }
        }

        offerDetour(here, loc)
    }

    /** A closure within 15 km ahead: ask the router for ways that avoid it, and offer the quickest. */
    private func offerDetour(_ here: Double, _ loc: CLLocation) {
        guard !rerouting, !detourLoading, detourOffer == nil,
              let blocked = routeRoad.first(where: {
                  ($0.event.kind == .closure || $0.event.blocked) && !detourTried.contains($0.event.id)
                      && $0.end > here && $0.start - here < 15_000
              }) else { return }
        detourTried.insert(blocked.event.id)
        detourLoading = true
        let from = LatLng(loc.coordinate.latitude, loc.coordinate.longitude)
        let heading = Self.heading(loc), id = route.id, ev = blocked.event
        let to = destination.location, hw = avoidHighways, tolls = avoidTolls
        let mode = route.mode
        Task {
            let r = await Directions.routes(from: from, to: to, mode: mode, avoidHighways: hw, avoidTolls: tolls,
                                            useGoogle: !AppSettings.shared.noGoogle, via: self.stops.map(\.location),
                                            heading: heading)
            self.detourLoading = false
            guard !self.stopped, self.route.id == id, let now = self.progress else { return }
            let clear = r.routes.filter { alt in
                alt.polyline.count >= 2 && Geo.project(ev.location, on: alt.polyline).offset >= 250
            }
            guard let best = clear.min(by: { $0.durationSeconds < $1.durationSeconds }) else { return }
            let extra = best.durationSeconds - now.remainingSeconds
            self.detourOffer = DetourOffer(route: best, extraSeconds: extra, eventID: ev.id)
            let minutes = Int((abs(extra) / 60).rounded())
            let cost = extra >= 60 ? "dokłada \(minutes) minut" : extra <= -60 ? "oszczędza \(minutes) minut" : "zajmuje mniej więcej tyle samo"
            self.speak("Jest objazd zamknięcia, \(cost). Stuknij, żeby go wybrać.")
        }
    }

    /** Park the car on the route and hold the test cards. GPS updates are ignored until the trip ends. */
    func holdCouch(title: String, along: Double, notes: [GuidanceNote], chip: CouchChip?, speed: Double) {
        couch = true
        demoAlerts = true
        couchTitle = title
        couchNotes = notes
        couchChip = chip
        guidance = notes.first
        let point = Geo.point(along: route.polyline, meters: along)
        progress = tracker.update(point, accuracy: 5, heading: nil)
        speedMps = speed
        following = false
        RouteMind.haptic(.rigid)
    }

    /** For the build's screenshots: police reported up the road. */
    func showDemoWaze() {
        demoAlerts = true
        let here = progress.map { Geo.point(along: route.polyline, meters: $0.alongMeters + 300) } ?? route.polyline.first ?? LatLng(0, 0)
        let a = WazeAlert(id: "demo-police", kind: .police, subtype: "POLICE_HIDING", location: here,
                          street: "A9", reportedAt: Date().addingTimeInterval(-7 * 60), thumbsUp: 3, reliability: 8)
        wazeAhead = WazeAhead(alert: a, meters: 260, startMeters: 600)
        policeRisk = 72
        aircraftNear = (PoliceAircraft(id: "demo-heli", callsign: "NPAS15", location: here, altitudeFeet: 1400, helicopter: true), 3200)
    }

    /** A short tone before a camera warning, the way Waze does it. */
    private func chime() {
        guard !muted, !stopped, !onCall else { return }
        AudioServicesPlaySystemSound(1057)
    }

    private func announce(_ p: RouteTracker.Progress) {
        guard let i = p.nextIndex, i < route.maneuvers.count else { return }
        let m = route.maneuvers[i]
        let d = p.distanceToNext
        let stage = spokenStage[i] ?? 0
        let drive = route.mode == .drive
        let now = drive ? max(40, speedMps * 4) : 15
        let near = drive ? max(250, speedMps * 12) : 60
        let far = drive ? max(1000, speedMps * 40) : 250
        if d <= now && stage < 3 {
            spokenStage[i] = 3
            // Arriving is said once, with the place's name, when it's reached.
            if m.type == .arrive { return }
            // Off a small roundabout seconds after "take the 2nd exit onto ..." was said: nothing new to say.
            if m.leavesRoundabout, let r = route.maneuvers[..<i].last(where: { $0.type == .roundabout }),
               m.alongMeters - r.alongMeters < 150 { return }
            // The turn itself matters more than whatever is still being said.
            speak(m.instruction, urgent: true)
        } else if m.leavesRoundabout {
            // Already said with the roundabout ("take the 3rd exit"): only "exit" itself, as it comes up.
            return
        } else if d <= near && d > now + 30 && stage < 2 {
            spokenStage[i] = 2
            // Which lane, like the banner shows, so it's known without looking.
            let lane = LaneGuide.lanes(for: m, leftTraffic: Geo.drivesOnLeft(m.location)).map { ". Użyj: \(Self.lanePolish($0.words))" } ?? ""
            let words = m.type == .arrive ? destinationSide.map { "cel jest po stronie \($0)" } ?? m.instruction.lowercasedFirst
                : m.instruction.lowercasedFirst
            speak("Za \(Fmt.spokenDistance(d)), \(words)\(lane)")
        } else if d <= far && d > near + 150 && stage < 1 && m.type != .arrive {
            spokenStage[i] = 1
            // On a phone call only what's needed now is said; the early heads-up would talk over it.
            if onCall { return }
            speak("Za \(Fmt.spokenDistance(d)), \(m.instruction.lowercasedFirst)")
        } else if drive && d > 3000 && stage < 1 && !toldContinue.contains(i) && justPassed(p) {
            // A long way to the next turn, like after joining a motorway: say so once, the way
            // Google does ("Continue on M27 for 7 miles"), so a quiet stretch doesn't feel lost.
            toldContinue.insert(i)
            if !onCall { speak(continueWords(d)) }
        }
    }

    /**
     * Every few minutes on a drive, asks again for the way from here, like Waze: the arrival time
     * follows the traffic, and a clearly faster way (5 minutes and a tenth of what's left) is taken,
     * with a word about it.
     */
    private func checkTraffic(_ p: RouteTracker.Progress, _ loc: CLLocation) {
        guard route.mode == .drive, !AppSettings.shared.noGoogle, !rerouting, !trafficLoading, !demoAlerts,
              p.remainingMeters > 5000, !p.offRoute, Date().timeIntervalSince(trafficAt) > 240 else { return }
        trafficLoading = true
        trafficAt = Date()
        let from = LatLng(loc.coordinate.latitude, loc.coordinate.longitude)
        let heading = Self.heading(loc), id = route.id, planned = p.remainingSeconds / trafficScale
        let to = destination.location, hw = avoidHighways, tolls = avoidTolls, via = stops.map(\.location)
        Task {
            let r = await Directions.routes(from: from, to: to, mode: .drive, avoidHighways: hw, avoidTolls: tolls, via: via, heading: heading)
            let routes = ClosureBoard.prefer(r.routes, mode: .drive)
            self.trafficLoading = false
            guard let fresh = routes.first, self.route.id == id, !self.rerouting, let now = self.progress,
                  planned > 0, fresh.trafficSeconds != nil else { return }
            let current = now.remainingSeconds
            let saving = current - fresh.durationSeconds
            // The same way, more or less: just a better arrival time.
            let sameWay = abs(fresh.distanceMeters - now.remainingMeters) < max(300, now.remainingMeters * 0.03)
            if !sameWay, saving > max(300, current * 0.1) {
                self.adopt(fresh)
                self.speak("Znalazłem szybszą trasę. Oszczędza \(Int((saving / 60).rounded())) minut.")
            } else if sameWay {
                self.trafficScale = min(3, max(0.5, fresh.durationSeconds / planned))
            }
        }
    }

    /** Just past a step the driver was told about (or the start), so "continue" follows on from it. */
    private func justPassed(_ p: RouteTracker.Progress) -> Bool {
        guard let i = p.nextIndex else { return false }
        let last = route.maneuvers[..<i].last { !$0.silent }?.alongMeters ?? 0
        return p.alongMeters - last < 500
    }

    private func continueWords(_ meters: Double) -> String {
        // The road's name only if it keeps it all the way: Commercial Road out of Totton becomes the
        // Redbridge Causeway and Millbrook Road long before the 3.4 miles are up.
        var road = currentRoad
        if let p = progress, let next = p.nextIndex,
           route.maneuvers[..<next].contains(where: { $0.alongMeters > p.alongMeters && $0.road != nil && $0.road != road }) {
            road = nil
        }
        return "Jedź dalej " + (road.map { "drogą \($0) " } ?? "") + "przez \(Fmt.spokenDistance(meters))."
    }

    /** Right after a reroute: the first thing to do on the new route, so "Rerouting" isn't the last word. */
    private func sayNewRoute() {
        guard let p = progress, let i = p.nextIndex, i < route.maneuvers.count, (spokenStage[i] ?? 0) == 0,
              !toldContinue.contains(i) else { return }
        let m = route.maneuvers[i], d = p.distanceToNext
        let now = max(40, speedMps * 4), near = max(250, speedMps * 12)
        guard d > now + 30, m.type != .arrive else { return }
        if d > 3000 {
            toldContinue.insert(i)
            speak(continueWords(d))
        } else {
            spokenStage[i] = d <= near ? 2 : 1
            speak("Za \(Fmt.spokenDistance(d)), \(m.instruction.lowercasedFirst)")
        }
    }

    /** The way the phone is moving, once it's fast enough (about 9 mph) for that to be trusted. */
    private static func heading(_ loc: CLLocation) -> Double? {
        loc.course >= 0 && loc.speed >= 4 && loc.courseAccuracy >= 0 && loc.courseAccuracy < 45 ? loc.course : nil
    }

    private func reroute(from loc: CLLocation, quiet: Bool = false) {
        rerouting = true
        lastReroute = Date()
        if !Connectivity.shared.online {
            // Without signal there's no new route to get: say so once, not every few seconds.
            if !quiet && !toldNoSignal {
                toldNoSignal = true
                speak("Brak sygnału. Jedź dalej, Apex znajdzie nową trasę, gdy sygnał wróci.")
            }
        } else if !quiet && Date().timeIntervalSince(rerouteSpokenAt) > 45 {
            rerouteSpokenAt = Date()
            speak("Przeliczam trasę.")
        }
        let from = LatLng(loc.coordinate.latitude, loc.coordinate.longitude)
        // Only while driving: on foot or a bike, turning round is fine.
        let heading = route.mode == .drive ? Self.heading(loc) : nil
        let mode = route.mode
        let to = destination.location
        let hw = avoidHighways, tolls = avoidTolls
        rerouteRequest += 1
        let req = rerouteRequest
        Task {
            let r = await Directions.routes(from: from, to: to, mode: mode, avoidHighways: hw, avoidTolls: tolls,
                                            useGoogle: !AppSettings.shared.noGoogle, via: self.stops.map(\.location),
                                            heading: heading)
            let routes = ClosureBoard.prefer(r.routes, mode: mode)
            guard !self.stopped, req == self.rerouteRequest else { return }
            self.rerouting = false
            guard let fresh = routes.first else { return }
            self.toldNoSignal = false
            self.adopt(fresh)
            if !quiet { self.sayNewRoute() }
        }
    }

    /** Drives [fresh] from here on: a reroute, or a faster way found on the way. */
    private func adopt(_ fresh: Route) {
        route = fresh
        tracker = RouteTracker(route: fresh)
        spokenStage = [:]
        toldContinue = []
        trafficScale = 1
        trafficAt = Date()
        loadCameras()
        loadRoundabouts()
        wazeAt = .distantPast
        routeWaze = []
        wazeAhead = nil
        routeRoad = []
        routeRoadKey = ""
        roadAhead = nil
        detourOffer = nil
        fuelAhead = nil
        fuelCheckedAt = .distantPast
        FuelPrices.shared.resetAhead()
        loadWaze()
        if let fix = lastFix { handle(fix) }
    }

    private func speak(_ text: String, urgent: Bool = false) {
        guard !muted, !stopped else { return }
        if urgent && speech.isSpeaking { speech.stopSpeaking(at: .word) }
        NowPlay.shared.prepareForVoice()
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
        try? session.setActive(true)
        let said = SpokenText.forVoice(text)
        // What was said, for checking a drive afterwards (Console, or `log stream` on a simulator).
        Self.log.info("say: \(said, privacy: .public)")
        let u = AVSpeechUtterance(string: said)
        let voice = Self.polishVoice()
        u.voice = voice
        u.prefersAssistiveTechnologySettings = false
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92
        if let voice { Self.log.info("voice: \(voice.language, privacy: .public) \(voice.name, privacy: .public)") }
        speech.speak(u)
    }

    /// Native Polish voice, chosen again each time so a late-downloaded Zosia is picked up.
    /// Enhanced or premium beats the compact voice. Never an English voice reading Polish.
    private static func polishVoice() -> AVSpeechSynthesisVoice? {
        let all = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.lowercased().hasPrefix("pl") }
        func rank(_ v: AVSpeechSynthesisVoice) -> Int {
            var score = v.quality.rawValue * 10
            let name = (v.name + " " + v.identifier).lowercased()
            if name.contains("zosia") { score += 6 }
            if v.language == "pl-PL" { score += 3 }
            return score
        }
        if let best = all.max(by: { rank($0) < rank($1) }) { return best }
        return AVSpeechSynthesisVoice(language: "pl-PL") ?? AVSpeechSynthesisVoice(language: "pl")
    }

    /// Lane advice for the Polish voice. The picture on screen can stay as the router wrote it.
    private static func lanePolish(_ words: String) -> String {
        let known = [
            "Left lane": "lewy pas", "Left 2 lanes": "dwa lewe pasy", "Left 3 lanes": "trzy lewe pasy",
            "Right lane": "prawy pas", "Right 2 lanes": "dwa prawe pasy", "Right 3 lanes": "trzy prawe pasy",
            "Middle lane": "środkowy pas", "Middle lanes": "środkowe pasy",
        ]
        if let hit = known[words] { return hit }
        if words.hasPrefix("Lane "), let n = words.split(separator: " ").dropFirst().first, n.allSatisfy({ $0.isNumber }) {
            return "pas \(n) od lewej"
        }
        return words
            .replacingOccurrences(of: "left", with: "lewy", options: .caseInsensitive)
            .replacingOccurrences(of: "right", with: "prawy", options: .caseInsensitive)
    }
}

/** Hands the sound back once Kite stops talking, so music comes back up between instructions. */
final class SpeechDone: NSObject, AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { release(synthesizer) }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { release(synthesizer) }

    private func release(_ synthesizer: AVSpeechSynthesizer) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard !synthesizer.isSpeaking else { return }
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.ambient, options: [.mixWithOthers])
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            Task { @MainActor in NowPlay.shared.restoreAfterVoice() }
        }
    }
}

extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}

struct CameraAlert: Equatable {
    var kind: RoadCamera.Kind
    /** How far ahead the camera is now. */
    var meters: Double
    /** How far it was when first warned about, so the bar can count down. */
    var startMeters: Double
    /** The limit it checks, when known. */
    var limitKmh: Double?
}

/** A road event coming up on the route, for its card: how far to its start, how long it lasts, how much is left. */
struct RoadAhead: Equatable {
    var event: RoadEvent
    var meters: Double
    var startMeters: Double
    var length: Double
    var left: Double?
}

struct DetourOffer: Equatable {
    let route: Route
    let extraSeconds: Double
    let eventID: String

    static func == (a: DetourOffer, b: DetourOffer) -> Bool { a.eventID == b.eventID && a.route.id == b.route.id }
}

struct WazeAhead: Equatable {
    var alert: WazeAlert
    var meters: Double
    var startMeters: Double
}

struct AverageCheck: Equatable {
    var limitKmh: Double?
    var averageKmh: Double
    var metersLeft: Double
}
