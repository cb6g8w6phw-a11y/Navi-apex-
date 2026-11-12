import SwiftUI

/** Turn-by-turn: the green instruction banner, map buttons, and the ETA bar. */
struct NavigationOverlay: View {
    @ObservedObject var model: AppModel
    @ObservedObject var nav: Navigator
    @State private var showSteps = false
    @State private var showAlong = false
    @State private var confirmEnd = false
    @State private var showPlayer = false
    @State private var showClosure = false
    @State private var tripAside = false
    @Namespace private var tripMorph
    @ObservedObject private var music = NowPlay.shared
    @Environment(\.colorScheme) private var scheme
    @Environment(\.sidePanel) private var panel

    /** "On my way to X, arriving around 5:42 PM (25 min)" with a map link. */
    private var etaText: String {
        let left = nav.progress?.remainingSeconds ?? nav.route.durationSeconds
        let link = nav.destination.shareURL.map { "\n\($0.absoluteString)" } ?? ""
        return "On my way to \(nav.destination.name), arriving around \(Fmt.arrival(left)) (\(Fmt.duration(left)) away).\(link)"
    }

    /** Warning cards stacked under the banner (camera, Waze report, average check). */
    private var mainCards: Int {
        nav.arrived ? 0 : [nav.cameraAhead != nil, nav.wazeAhead != nil, nav.roadAhead != nil, nav.averageCheck != nil].filter { $0 }.count
    }

    /** With two other cards up, a police aircraft shrinks to a chip by the speed badge, so the
     *  stack doesn't run into the map buttons. */
    private var aircraftAsChip: Bool { mainCards >= 2 }

    /** The police risk chip, only worth a look while driving when it isn't low. */
    private var showRiskChip: Bool {
        guard let risk = nav.policeRisk, !nav.arrived, mainCards < 2 else { return false }
        return PoliceRisk.level(risk) != .low
    }

    /** A chip above the speed badge sits where the road name goes, so the name steps aside for it. */
    private var chipShowing: Bool { showRiskChip || (nav.aircraftNear != nil && !nav.arrived && aircraftAsChip) }

    /** Price only when it matters: the tank is on reserve, or a cheaper station is coming up. */
    private var fuelCorner: FuelAhead? {
        guard !nav.arrived, model.settings.fuelOn else { return nil }
        if let f = nav.fuelAhead, model.settings.fuelOnReserve || (f.saving != nil && f.meters < 20_000) { return f }
        guard model.settings.fuelOnReserve, let best = model.fuelBest else { return nil }
        let meters = model.userLatLng.map { $0.distance(to: best.location) } ?? 0
        return FuelAhead(station: best, meters: meters, offRoute: meters, saving: nil)
    }

    /** With a camera and a Waze report both up, the average check waits its turn: there's only so much screen. */
    private var showAverage: Bool { !(nav.cameraAhead != nil && nav.wazeAhead != nil) }

    var body: some View {
        // One column, so however many warnings are up, they push the map buttons down rather than cover them.
        VStack(spacing: 6) {
            if nav.isCouch {
                HStack(spacing: 10) {
                    Text("Symulacja · \(nav.couchTitle)")
                        .font(.system(size: 15, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 8)
                    Button { model.endNavigation() } label: {
                        Label("Zamknij", systemImage: "xmark")
                            .font(.system(size: 16, weight: .bold))
                            .padding(.horizontal, 14)
                            .frame(height: 40)
                            .foregroundColor(.white)
                            .background(Capsule().fill(Color(hex: 0xDC2626)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Zamknij symulację")
                }
                .padding(.horizontal, 4)
            }
            VStack(spacing: 6) {
                if nav.arrived {
                    ArrivedCard(name: nav.destination.name, onPark: nav.route.mode == .drive ? { model.saveParking() } : nil,
                                note: nav.wazeWarned > 0 ? "Waze drivers warned you about \(nav.wazeWarned) report\(nav.wazeWarned == 1 ? "" : "s") on the way" : nil) { model.endNavigation() }
                } else {
                    topAlerts
                    InstructionBanner(nav: nav)
                        .fixedSize(horizontal: false, vertical: true)
                    if let f = fuelCorner {
                        FuelAheadChip(ahead: f) { withAnimation { nav.dismissFuel() } }
                    }
                }
                if nav.isCouch, !nav.arrived {
                    ForEach(Array(nav.couchNotes.enumerated()), id: \.offset) { _, note in
                        MindNoteCard(note: note)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let chip = nav.couchChip {
                        HStack {
                            UmweltChip(name: chip.name, blocked: chip.blocked)
                            Spacer(minLength: 0)
                        }
                    }
                } else if let note = nav.guidance, !nav.arrived {
                    MindNoteCard(note: note)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let air = nav.aircraftNear, !nav.arrived, !aircraftAsChip {
                    AircraftCard(aircraft: air.aircraft, meters: air.meters)
                }
                if let check = nav.averageCheck, !nav.arrived, showAverage {
                    AverageCheckCard(check: check)
                }
                if nav.rerouting {
                    Label("Rerouting…", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 18, weight: .bold))
                        .padding(.horizontal, 18).frame(height: 44)
                        .glass(Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .inSidePanel(panel)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: nav.cameraAhead?.startMeters)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: nav.wazeAhead?.alert.id)
            .animation(.spring(response: 0.5, dampingFraction: 0.6), value: nav.roadAhead?.event.id)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: nav.detourOffer?.eventID)

            Spacer(minLength: 0)

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    if let air = nav.aircraftNear, !nav.arrived, aircraftAsChip {
                        AircraftChip(aircraft: air.aircraft, meters: air.meters)
                    }
                    // A Waze police card already says it louder; the chip comes back when it's gone.
                    // Only worth a look while driving when it isn't low; it would otherwise sit by the road name.
                    if showRiskChip, let risk = nav.policeRisk { PoliceRiskChip(score: risk) }
                    SpeedBadge(mps: nav.speedMps, limitKmh: nav.speedLimitKmh)
                }
                Spacer(minLength: 8)
                if nav.following, !nav.arrived, !chipShowing, let road = nav.currentRoad {
                    Text(road)
                        .font(.system(size: 16, weight: .bold))
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .padding(.horizontal, 14).frame(height: 36)
                        .foregroundColor(.white)
                        .background(Capsule().fill(Color(hex: 0x0F172A).opacity(0.92)))
                        .overlay(Capsule().strokeBorder(Color(hex: 0x2DD4BF).opacity(0.8), lineWidth: 1.5))
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 8) {
                    if nav.speedMps < 2 {
                        MapFab(icon: "nosign", tint: Color(hex: 0xDC2626), size: 36) { showClosure = true }
                            .accessibilityLabel("Zgłoś zamknięcie")
                    }
                    MapFab(icon: "location.fill", tint: Vela.accentText(scheme), size: 36) {
                        model.recenterNav()
                    }
                    .accessibilityLabel("Centre on me")
                    MapFab(icon: nav.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", size: 36) { nav.muted.toggle() }
                        .accessibilityLabel(nav.muted ? "Turn voice on" : "Mute voice")
                    if tripAside, !nav.arrived, !confirmEnd {
                        TripSide(nav: nav, onEnd: {
                            if nav.arrived { model.endNavigation() } else {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { confirmEnd = true }
                            }
                        })
                        .matchedGeometryEffect(id: "trip", in: tripMorph)
                    }
                }
            }
            .padding(.horizontal, 16)
            if !nav.following {
                Button { model.recenterNav() } label: {
                    Label("Na środek", systemImage: "location.north.line.fill")
                        .font(.system(size: 15, weight: .bold))
                        .padding(.horizontal, 14).frame(height: 40)
                        .foregroundColor(.white)
                        .background(TripSheen(progress: tripProgress(nav), capsule: true))
                        .shadow(color: .black.opacity(0.28), radius: 6, y: 2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Na środek")
                // Under the car, which drives beside the side panel when there is one.
                .frame(maxWidth: .infinity)
                .padding(.leading, panel)
            }
            // Arriving answers the question: the trip bar's Done takes over.
            if confirmEnd, !nav.arrived {
                EndTripCard(destination: nav.destination.name,
                            onKeep: { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { confirmEnd = false } },
                            onEnd: { model.endNavigation() })
                    .inSidePanel(panel)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if !tripAside {
                TripBar(nav: nav, onEnd: {
                    if nav.arrived { model.endNavigation() } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { confirmEnd = true }
                    }
                }, onSteps: { showSteps = true })
                .matchedGeometryEffect(id: "trip", in: tripMorph)
                .inSidePanel(panel)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onAppear {
            guard !nav.arrived else { return }
            withAnimation(.spring(response: 0.55, dampingFraction: 0.78).delay(0.15)) { tripAside = true }
        }
        .task {
            NowPlay.shared.attach()
            // Screenshot run: the end trip question.
            if DemoScript.step == "endtrip" {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                withAnimation { confirmEnd = true }
            }
        }
        .overlay {
            if showPlayer {
                MusicPlayerOverlay(music: music, shown: $showPlayer)
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }
        }
        .sheet(isPresented: $showClosure) {
            ClosureReportSheet(at: model.userLatLng) { showClosure = false }.kiteType()
        }
        .sheet(isPresented: $showAlong) {
            AlongRouteSheet(nav: nav).kiteType()
        }
        .sheet(isPresented: $showSteps) {
            NavigationView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // The things that used to be buttons on the map, out of the way until wanted.
                        HStack(spacing: 10) {
                            tripAction("magnifyingglass", "Find on route") {
                                showSteps = false
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { showAlong = true }
                            }
                            ShareLink(item: etaText) { tripActionLabel("square.and.arrow.up", "Share ETA") }
                                .buttonStyle(.plain)
                            tripAction("arrow.up.left.and.arrow.down.right", "Overview") {
                                showSteps = false
                                model.overviewNav()
                            }
                        }
                        StepsList(route: nav.route, from: nav.progress?.nextIndex ?? 0)
                    }
                    .padding(.horizontal, 16)
                }
                .navigationTitle("Your trip")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showSteps = false } } }
            }
            .kiteType()
        }
    }

    /** Fotoradar, policja i roboty: cienki pasek nad skrętem, nie duża karta. */
    @ViewBuilder private var topAlerts: some View {
        if let offer = nav.detourOffer {
            let minutes = Int((abs(offer.extraSeconds) / 60).rounded())
            let saved = offer.extraSeconds <= -60 ? "oszczędza \(minutes) min"
                : offer.extraSeconds >= 60 ? "+\(minutes) min" : "tyle samo"
            TopPing(icon: "arrow.triangle.branch", tint: Color(hex: 0x16A34A),
                    title: "Korek · zrób objazd", detail: saved)
                .onTapGesture { withAnimation { nav.acceptDetour() } }
                .transition(.move(edge: .top).combined(with: .opacity))
        }
        if let cam = nav.cameraAhead {
            let title = cam.kind == .speed ? "Fotoradar" : "Kamera tablic"
            let limit = cam.limitKmh.map { "\(Int($0.rounded())) km/h" } ?? ""
            TopPing(icon: "camera.fill", tint: Color(hex: 0xF97316),
                    title: "\(title) za \(Fmt.distance(cam.meters))", detail: limit)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
        if let w = nav.wazeAhead {
            TopPing(icon: "exclamationmark.triangle.fill", tint: Color(uiColor: MapIcons.wazeColor(w.alert.kind)),
                    title: "\(w.alert.plTitle) za \(Fmt.distance(w.meters))", detail: "")
                .onTapGesture { withAnimation { nav.dismissWaze() } }
                .transition(.move(edge: .top).combined(with: .opacity))
        }
        if let r = nav.roadAhead {
            let len = max(r.length, r.event.lengthMeters ?? 0)
            let extra = len >= 200 ? " · \(Fmt.distance(len))" : ""
            TopPing(icon: "road.lanes", tint: Color(hex: 0xF59E0B),
                    title: "\(r.event.kindName) za \(Fmt.distance(r.meters))\(extra)",
                    detail: nav.detourOffer == nil ? "" : "Objazd")
                .onTapGesture { if nav.detourOffer != nil { withAnimation { nav.acceptDetour() } } }
                .transition(.move(edge: .top).combined(with: .opacity))
        }
        if let light = nav.signalAhead {
            TopPing(icon: "lightbulb.fill", tint: Color(hex: 0x22C55E),
                    title: "Światła za \(Fmt.distance(light.meters))", detail: "")
        }
    }

    private func tripAction(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { tripActionLabel(icon, title) }.buttonStyle(.plain)
    }

    private func tripActionLabel(_ icon: String, _ title: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 22, weight: .bold))
            Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
        }
        .foregroundColor(.primary)
        .frame(maxWidth: .infinity, minHeight: 78)
        .background(RoundedRectangle(cornerRadius: 18).fill(Vela.chip(scheme)))
    }
}

/** A thin glass notice that drops in above the turn. */
struct TopPing: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 14, weight: .bold)).foregroundColor(tint)
            Text(title).font(.system(size: 14, weight: .bold)).lineLimit(1).minimumScaleFactor(0.75)
            if !detail.isEmpty {
                Text(detail).font(.system(size: 13, weight: .semibold)).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .glass(Capsule())
    }
}

/**
 * The next turn, as a thin glass pill: arrow, distance, the road.
 */
struct InstructionBanner: View {
    @ObservedObject var nav: Navigator

    var body: some View {
        let m = nav.nextManeuver
        let leftTraffic = Geo.drivesOnLeft(m?.location ?? LatLng(0, 0))
        let line: String = {
            if let parts = Self.split(Self.headline(m)) { return parts.1 }
            return Self.headline(m)
        }()
        HStack(spacing: 8) {
            if m?.type == .roundabout {
                RoundaboutDiagram(shape: m?.roundabout, exit: m?.exit ?? 1, clockwise: leftTraffic)
                    .frame(width: 28, height: 28)
            } else {
                Image(systemName: maneuverSymbol(m?.type ?? .straight))
                    .font(.system(size: 26, weight: .heavy))
                    .frame(width: 32)
            }
            if let p = nav.progress {
                Text(Fmt.distance(p.distanceToNext))
                    .font(.system(size: 26, weight: .heavy))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Text(line)
                .font(.system(size: 16, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 4)
            thenView
        }
        .foregroundColor(.primary)
        .padding(.horizontal, 14)
        .frame(minHeight: 54)
        .glass(Capsule())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var thenView: some View {
        if let then = nav.thenManeuver {
            HStack(spacing: 6) {
                Text("Potem").font(.system(size: 12, weight: .bold)).opacity(0.85)
                Image(systemName: maneuverSymbol(then.type)).font(.system(size: 14, weight: .heavy))
                if then.type == .roundabout, let n = then.exit {
                    // Which exit, so the next roundabout is known before the banner changes.
                    Text("\(n)").font(.system(size: 14, weight: .heavy)).foregroundColor(.white)
                        .frame(minWidth: 22, minHeight: 22).background(Circle().fill(Color(hex: 0x0F766E)))
                }
            }
        }
    }

    /**
     * A long instruction split into what to do and where: "At the end of the road, turn left onto
     * Burgess Road" is "At the end of the road, turn left" and "Burgess Road". Short ones stay whole.
     */
    static func split(_ text: String) -> (String, String)? {
        guard text.count > 26 else { return nil }
        for word in [" onto ", " towards ", " toward "] {
            guard let r = text.range(of: word, options: .backwards) else { continue }
            let place = text[r.upperBound...].trimmingCharacters(in: .whitespaces)
            // "Take the exit toward" keeps its last word, so it still reads as a sentence.
            let action = word == " onto " ? String(text[..<r.lowerBound]) : String(text[..<r.upperBound]).trimmingCharacters(in: .whitespaces)
            guard !place.isEmpty, action.count >= 4 else { continue }
            return (action, place)
        }
        return nil
    }

    /** "6th exit" for a roundabout (the picture says the rest), else the instruction. */
    static func headline(_ m: Maneuver?) -> String {
        guard let m else { return L.t("Jedź za linią", "Der Linie folgen", "Follow the route") }
        if m.type == .roundabout, let n = m.exit {
            return L.t("Zjazd \(n)", "\(n). Ausfahrt", "Exit \(n)")
        }
        return m.instruction
    }

    static func ordinal(_ n: Int) -> String {
        switch n % 100 {
        case 11, 12, 13: return "\(n)th"
        default: break
        }
        switch n % 10 {
        case 1: return "\(n)st"
        case 2: return "\(n)nd"
        case 3: return "\(n)rd"
        default: return "\(n)th"
        }
    }
}

/** Which lanes to show under the turn: the mapped ones, or at a roundabout with none mapped, the Highway Code's. */
enum LaneGuide {
    static func lanes(for m: Maneuver, leftTraffic: Bool) -> (lanes: [Lane], words: String)? {
        if m.lanes.count > 1 { return named(m.lanes) }
        // Google's own advice ("Use the right lane") where the open map has no lanes: words only.
        if let hint = m.laneHint, !hint.localizedCaseInsensitiveContains("any lane"), m.type != .roundabout {
            let words = hint.replacingOccurrences(of: "use the ", with: "", options: .caseInsensitive)
            return ([], words.prefix(1).uppercased() + words.dropFirst())
        }
        // The road's painted arrows, Google's advice, or the Highway Code's lanes, as many as the road in has.
        guard m.type == .roundabout, !m.leavesRoundabout, let lanes = m.roundabout?.ruleLanes(leftTraffic: leftTraffic, hint: m.laneHint) else { return nil }
        return named(lanes)
    }

    /** The lanes with words for the good ones, by the edge they touch: two of three on the left are "Left 2 lanes", not "Middle". */
    static func named(_ lanes: [Lane]) -> (lanes: [Lane], words: String)? {
        let valid = lanes.enumerated().filter(\.element.valid).map(\.offset)
        guard let first = valid.first, let last = valid.last, valid.count < lanes.count else { return nil }
        let n = lanes.count, count = valid.count, many = count > 1 ? "\(count) lanes" : "lane"
        let words: String
        if first == 0 { words = "Left \(many)" }
        else if last == n - 1 { words = "Right \(many)" }
        else if count == 1 && n > 3 { words = "Lane \(first + 1) from left" }
        else { words = count > 1 ? "Middle lanes" : "Middle lane" }
        return (lanes, words)
    }
}

/** Speed and limit as one sign, the way Waze does it: the limit on top, your speed under it, all red when over. */
struct SpeedBadge: View {
    let mps: Double
    var limitKmh: Double?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let metric = Fmt.metric
        let v = Int((mps * (metric ? 3.6 : 2.23694)).rounded())
        // Red once more than a little over the limit.
        let over = limitKmh.map { mps * 3.6 > $0 + 5 } ?? false
        let speed = VStack(spacing: -2) {
            Text("\(v)").font(.system(size: 26, weight: .heavy)).monospacedDigit()
                .foregroundColor(over ? .white : .primary)
            Text(metric ? "km/h" : "mph").font(.system(size: 14, weight: .semibold))
                .foregroundColor(over ? .white.opacity(0.85) : Vela.muted(scheme))
        }
        Group {
            if let limitKmh {
                VStack(spacing: 6) {
                    SpeedLimitSign(kmh: limitKmh, size: 58)
                    speed
                }
                .padding(.top, 6).padding(.bottom, 8)
                .frame(width: 72)
                .background(Capsule().fill(over ? Vela.closed : Color.clear))
                .glass(Capsule())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(v) \(metric ? "kilometres" : "miles") an hour" + (over ? ", over the limit" : ""))
            } else {
                speed
                    .frame(width: 84, height: 84)
                    .glass(Circle())
            }
        }
        .animation(.easeOut(duration: 0.25), value: over)
    }
}

/** The posted limit: a US-style white sign in miles, a round red-ringed one in kilometers. */
struct SpeedLimitSign: View {
    let kmh: Double
    var size: CGFloat = 56

    var body: some View {
        if Fmt.metric || Fmt.yards {
            // Round red ring: kilometers on the Continent, miles in Britain.
            Text("\(Fmt.metric ? Int(kmh.rounded()) : Int((kmh / 1.609344 / 5).rounded()) * 5)")
                .font(.system(size: size * 0.4, weight: .heavy))
                .foregroundColor(.black)
                .frame(width: size, height: size)
                .background(Circle().fill(.white))
                .overlay(Circle().inset(by: size * 0.055).stroke(Color(hex: 0xD93025), lineWidth: size * 0.11))
                .shadow(color: .black.opacity(0.3), radius: 5, y: 2)
        } else {
            // OSM limits in the US are mapped in mph; round back to the posted number.
            let mph = Int((kmh / 1.609344 / 5).rounded()) * 5
            VStack(spacing: 0) {
                Text("SPEED\nLIMIT").font(.system(size: size * 0.14, weight: .bold)).multilineTextAlignment(.center)
                Text("\(mph)").font(.system(size: size * 0.4, weight: .heavy))
            }
            .foregroundColor(.black)
            .frame(width: size * 0.86, height: size * 1.07)
            .background(RoundedRectangle(cornerRadius: 6).fill(.white))
            .overlay(RoundedRectangle(cornerRadius: 6).inset(by: 2).stroke(.black, lineWidth: 2))
            .shadow(color: .black.opacity(0.3), radius: 5, y: 2)
        }
    }
}

/** The bottom card while driving: end, time left (big), and the trip menu. */
/** Asks before ending a trip, in place of the trip bar: two big buttons, easy to hit in a phone holder. */
struct EndTripCard: View {
    let destination: String
    let onKeep: () -> Void
    let onEnd: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 8) {
            VStack(spacing: 1) {
                Text("Zakończyć tę trasę?").font(.system(size: 17, weight: .bold))
                Text("do \(destination)").font(.system(size: 13, weight: .medium))
                    .foregroundColor(Vela.muted(scheme)).lineLimit(1)
            }
            HStack(spacing: 8) {
                Button(action: onKeep) {
                    Text("Jadę dalej").font(.system(size: 15, weight: .bold))
                        .frame(maxWidth: .infinity).frame(height: 40)
                        .foregroundColor(.white)
                        .background(Capsule().fill(Color(hex: 0x14B8A6)))
                }
                Button(action: onEnd) {
                    Text("Zakończ").font(.system(size: 15, weight: .bold))
                        .frame(maxWidth: .infinity).frame(height: 40)
                        .foregroundColor(.white)
                        .background(Capsule().fill(Vela.closed))
                }
            }
            .buttonStyle(.plain)
        }
        .foregroundColor(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glass(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }
}

struct TripBar: View {
    @ObservedObject var nav: Navigator
    let onEnd: () -> Void
    let onSteps: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let remaining = nav.progress?.remainingSeconds ?? nav.route.durationSeconds
        let meters = nav.progress?.remainingMeters ?? nav.route.distanceMeters
        HStack(spacing: 12) {
            Button(action: onEnd) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundColor(scheme == .dark ? Color(hex: 0xFCA5A5) : Vela.closed)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(scheme == .dark ? Color(hex: 0x3B1820) : Color(hex: 0xFEE2E2)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Zakończ trasę")
            VStack(spacing: 1) {
                Text(Fmt.duration(remaining)).font(.system(size: 22, weight: .heavy))
                    .foregroundColor(.primary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text("\(Fmt.distance(meters)) · \(Fmt.arrival(remaining))").font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            Button(action: onSteps) {
                Image(systemName: "list.bullet")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.primary)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Kroki trasy")
        }
        .foregroundColor(.primary)
        .padding(.horizontal, 10)
        .frame(height: 58)
        .glass(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }
}

/** Kilometry i czas w pionie, po prawej, kiedy auto już jedzie. */
struct TripSide: View {
    @ObservedObject var nav: Navigator
    let onEnd: () -> Void

    var body: some View {
        let remaining = nav.progress?.remainingSeconds ?? nav.route.durationSeconds
        let meters = nav.progress?.remainingMeters ?? nav.route.distanceMeters
        VStack(spacing: 5) {
            Button(action: onEnd) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color(hex: 0xDC2626)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Zakończ trasę")
            Text(Fmt.duration(remaining))
                .font(.system(size: 17, weight: .heavy))
                .lineLimit(1).minimumScaleFactor(0.55)
            Text(Fmt.distance(meters))
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.secondary)
                .lineLimit(1).minimumScaleFactor(0.55)
        }
        .foregroundColor(.primary)
        .padding(.vertical, 10)
        .frame(width: 76)
        .glass(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct ArrivedCard: View {
    let name: String
    var onPark: (() -> Void)?
    var note: String?
    let done: () -> Void
    @State private var parked = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "flag.checkered").font(.system(size: 38, weight: .bold))
            VStack(alignment: .leading, spacing: 2) {
                Text("You've arrived").font(.system(size: 26, weight: .heavy))
                Text(name).font(.system(size: 18, weight: .semibold)).lineLimit(1)
                if let note { Text(note).font(.subheadline).opacity(0.85).lineLimit(2) }
            }
            Spacer()
            if let onPark, !parked {
                Button { onPark(); parked = true } label: {
                    Image(systemName: "parkingsign").font(.system(size: 22, weight: .bold))
                        .frame(width: 56, height: 56)
                        .background(Circle().fill(Color.white.opacity(0.22)))
                }
                .accessibilityLabel("Save parking")
            }
            Button(action: done) {
                Text("Done").font(.system(size: 20, weight: .bold))
                    .padding(.horizontal, 20).frame(height: 56)
                    .background(Capsule().fill(Color.white.opacity(0.22)))
            }
        }
        .foregroundColor(.white)
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Vela.navGreen))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 5)
    }
}

/**
 * The camera warning, loud on purpose: bright orange, a big camera, the distance in huge
 * numbers and the limit it checks. It pulses as it appears, and turns red while you're over.
 */
struct CameraCard: View {
    let alert: CameraAlert
    let speedKmh: Double
    @State private var pulse = false

    var body: some View {
        let over = alert.limitKmh.map { speedKmh > $0 + Double(AppSettings.shared.speedSlack) } ?? false
        let left = min(max(alert.meters / alert.startMeters, 0), 1)
        let title = alert.kind == .speed ? "Fotoradar za \(Fmt.distance(alert.meters))" : "Kamera tablic za \(Fmt.distance(alert.meters))"
        let limitLine = alert.limitKmh.map { "Limit \(Int($0.rounded())) km/h" } ?? (alert.kind == .speed ? "Fotoradar" : "Kamera tablic")
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                CameraBadge(kind: alert.kind, size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(over ? "Zwolnij" : title)
                        .font(.system(size: 18, weight: .heavy))
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text(limitLine)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white.opacity(0.82))
                }
                Spacer(minLength: 8)
                if let limit = alert.limitKmh { SpeedLimitSign(kmh: limit, size: 46) }
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.22))
                    Capsule().fill(Color.white).frame(width: g.size.width * left)
                }
            }
            .frame(height: 4)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: 340, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(over ? Vela.closed : Color(hex: 0x1A2744).opacity(0.92)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(pulse ? 0.7 : 0.12), lineWidth: 1))
        .scaleEffect(pulse ? 1.04 : 1)
        .animation(.easeOut(duration: 0.3), value: over)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .task(id: alert.startMeters) {
            // Two quick pulses when it first shows, so it catches the eye.
            for _ in 0..<2 {
                withAnimation(.easeOut(duration: 0.25)) { pulse = true }
                try? await Task.sleep(nanoseconds: 300_000_000)
                withAnimation(.easeIn(duration: 0.3)) { pulse = false }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
    }
}

/** A Waze report on the road ahead, as loud as the camera card, in the report's own color. */
struct WazeCard: View {
    let ahead: WazeAhead

    var body: some View {
        let a = ahead.alert
        let left = min(max(ahead.meters / ahead.startMeters, 0), 1)
        let detail = [a.reportedText, a.thumbsUp > 0 ? "\(a.thumbsUp) 👍" : nil, a.street].compactMap { $0 }.joined(separator: " · ")
        let fill = Color(uiColor: MapIcons.wazeColor(a.kind))
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                WazeBadge(kind: a.kind, size: 58)
                VStack(alignment: .leading, spacing: 1) {
                    Text(Fmt.distance(ahead.meters)).font(.system(size: 38, weight: .heavy)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text(a.plTitle).font(.system(size: 21, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7)
                    Text(detail).font(.system(size: 15, weight: .medium)).opacity(0.9).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text("Waze").font(.system(size: 13, weight: .heavy)).opacity(0.8)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.3))
                    Capsule().fill(Color.white).frame(width: g.size.width * left)
                }
            }
            .frame(height: 8)
        }
        .foregroundColor(.white)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(fill))
        .shadow(color: fill.opacity(0.5), radius: 12, y: 4)
        .accessibilityElement(children: .combine)
    }
}

extension WazeAlert {
    /** "Reported 12 min ago". */
    var reportedText: String {
        let mins = max(Int(Date().timeIntervalSince(reportedAt) / 60), 0)
        let when = mins < 1 ? "przed chwilą" : mins < 60 ? "\(mins) min temu" : mins < 1440 ? "\(mins / 60) godz. temu" : "\(mins / 1440) dni temu"
        return "zgłoszone \(when)"
    }
}

/** A Waze report tapped on the map: what, where, how fresh, how many drivers agree. */
struct WazeInfoCard: View {
    let alert: WazeAlert
    let close: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            WazeBadge(kind: alert.kind, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(alert.plTitle).font(.headline)
                Text([alert.street, alert.reportedText].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline).foregroundColor(.secondary)
                HStack(spacing: 10) {
                    if alert.thumbsUp > 0 {
                        Label("\(alert.thumbsUp) confirmed", systemImage: "hand.thumbsup.fill")
                    }
                    // Waze's 0-10 trust in the report, as five dots.
                    HStack(spacing: 3) {
                        ForEach(0..<5, id: \.self) { i in
                            Circle().fill(i < (alert.reliability + 1) / 2 ? Color(uiColor: MapIcons.wazeColor(alert.kind)) : Color.secondary.opacity(0.25))
                                .frame(width: 6, height: 6)
                        }
                    }
                    .accessibilityLabel("Reliability \(alert.reliability) out of 10")
                    Text("via Waze")
                }
                .font(.caption).foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
            Button(action: close) {
                Image(systemName: "xmark").font(.footnote.weight(.semibold)).foregroundColor(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(14)
        .glass(RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 12)
    }
}

/**
 * Before starting a drive: what Waze drivers have reported along this route right now, like
 * "2 police · 1 crash". Quiet when Waze is off or didn't answer.
 */
struct RouteWazeSummary: View {
    let route: Route
    @ObservedObject private var settings = AppSettings.shared
    @State private var counts: [(WazeAlert.Kind, Int)]?
    /** For the build's screenshots, since Waze turns away the build's computers. */
    static var demo: [(WazeAlert.Kind, Int)]?

    var body: some View {
        // A VStack, not a Group: an empty Group has nothing to hang .task on, so it would never ask.
        VStack(alignment: .leading, spacing: 0) {
            if let counts {
                if counts.isEmpty {
                    Label(L.t("Brak zamknięć na tej trasie", "Keine Sperrungen auf der Route", "No road closures on this route"), systemImage: "checkmark.shield.fill")
                        .font(.system(size: 16, weight: .semibold)).foregroundColor(Vela.open)
                } else {
                    WrapLayout(spacing: 8, lineSpacing: 8) {
                        ForEach(counts, id: \.0) { item in
                            let tint = Color(uiColor: MapIcons.wazeColor(item.0))
                            HStack(spacing: 6) {
                                WazeBadge(kind: item.0, size: 24)
                                Text("\(item.1) \(Self.label(item.0, item.1))").font(.system(size: 16, weight: .bold))
                            }
                            .padding(.leading, 6).padding(.trailing, 12)
                            .frame(height: 38)
                            .background(Capsule().fill(tint.opacity(0.18)))
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .task(id: route.id) {
            if let demo = Self.demo { counts = demo; return }
            guard settings.wazeOn, route.mode == .drive else { counts = nil; return }
            counts = nil
            guard let found = await Waze.alongRoute(route.polyline) else { return }
            let on = Waze.project(found, on: route.polyline).map(\.alert).filter { settings.shows($0) }
            let grouped = Dictionary(grouping: on, by: \.kind)
            counts = WazeAlert.Kind.allCases.compactMap { k in grouped[k].map { (k, $0.count) } }
        }
    }

    static func label(_ k: WazeAlert.Kind, _ n: Int) -> String {
        switch k {
        case .police: return "police"
        case .accident: return n == 1 ? "crash" : "crashes"
        case .hazard: return n == 1 ? "hazard" : "hazards"
        case .weather: return "weather"
        case .roadworks: return "roadworks"
        case .closure: return n == 1 ? "closure" : "closures"
        case .jam: return n == 1 ? "jam" : "jams"
        }
    }
}

/** The heat map's key, top left of the map while it's on: blue for a few police reports, red for many. */
struct HeatLegend: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "flame.fill").font(.system(size: 11, weight: .bold)).foregroundColor(Color(hex: 0xE91E63))
            Text("Police").font(.caption2.weight(.semibold))
            LinearGradient(colors: [Color(hex: 0x4285F4), Color(hex: 0x7C4DFF), Color(hex: 0xE91E63), Color(hex: 0xD50000)],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: 54, height: 6).clipShape(Capsule())
            Text("often").font(.caption2).foregroundColor(.secondary)
        }
        .padding(.horizontal, 10).frame(height: 28)
        .glass(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Police heat map on: red where police are reported most often")
    }
}

/** "Police risk: High" over the speed badge, from past and live Waze police reports ahead. */
struct PoliceRiskChip: View {
    let score: Int

    static func color(_ level: PoliceRisk.Level) -> Color {
        switch level {
        case .high: return Color(hex: 0xDC2626)
        case .medium: return Color(hex: 0xF59E0B)
        case .low: return Color(hex: 0x16A34A)
        }
    }

    var body: some View {
        let level = PoliceRisk.level(score)
        let color = Self.color(level)
        HStack(spacing: 8) {
            Image(systemName: "shield.lefthalf.filled").font(.system(size: 17, weight: .bold))
            Text("Police risk: \(level.rawValue.capitalized)").font(.system(size: 17, weight: .bold))
        }
        .foregroundColor(level == .medium ? Color(hex: 0x1F1300) : .white)
        .padding(.horizontal, 14).frame(height: 42)
        .background(Capsule().fill(color))
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        .accessibilityLabel("Police risk \(level.rawValue), \(score) out of 100")
    }
}

/** The aircraft card made small, for when the screen is already full of warnings. */
struct AircraftChip: View {
    let aircraft: PoliceAircraft
    let meters: Double

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: aircraft.helicopter ? "fanblades.fill" : "airplane").font(.system(size: 17, weight: .bold))
            Text("\(aircraft.title) · \(Fmt.distance(meters))").font(.system(size: 16, weight: .bold)).lineLimit(1)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 14).frame(height: 40)
        .background(Capsule().fill(Color(hex: 0x1E88E5)))
        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
        .accessibilityElement(children: .combine)
    }
}

/** A police plane or helicopter nearby: what, how far, how high. */
struct AircraftCard: View {
    let aircraft: PoliceAircraft
    let meters: Double
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let detail = [aircraft.altitudeFeet.map { !Fmt.metric ? "\(Int($0)) ft up" : "\(Int($0 * 0.3048)) m up" },
                      aircraft.callsign ?? aircraft.registration].compactMap { $0 }.joined(separator: " · ")
        HStack(spacing: 12) {
            Image(systemName: aircraft.helicopter ? "fanblades.fill" : "airplane")
                .font(.system(size: 20, weight: .bold)).foregroundColor(.white)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: 0x1E88E5)))
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Fmt.distance(meters)).font(.system(size: 22, weight: .bold)).monospacedDigit()
                    Text(aircraft.title).font(.headline)
                }
                if !detail.isEmpty { Text(detail).font(.subheadline).foregroundColor(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 4)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 18).fill(Vela.sheet(scheme))
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2))
        .accessibilityElement(children: .combine)
    }
}

struct WazeBadge: View {
    let kind: WazeAlert.Kind
    var size: CGFloat = 28

    var body: some View {
        Image(uiImage: MapIcons.waze(kind)).resizable().frame(width: size, height: size)
    }
}

/** Inside an average speed check: your average so far against the limit, and how much is left. */
struct AverageCheckCard: View {
    let check: AverageCheck
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let over = check.limitKmh.map { check.averageKmh > $0 + 2 } ?? false
        HStack(spacing: 12) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.system(size: 26, weight: .semibold))
                .foregroundColor(over ? .white : Color(hex: 0xF9AB00))
            VStack(alignment: .leading, spacing: 1) {
                Text("Average speed check").font(.subheadline.weight(.semibold))
                Text("\(Fmt.distance(max(check.metersLeft, 0))) left").font(.caption)
                    .foregroundColor(over ? .white.opacity(0.9) : .secondary)
            }
            Spacer(minLength: 4)
            VStack(spacing: -2) {
                Text("\(Fmt.speed(check.averageKmh))").font(.system(size: 24, weight: .bold)).monospacedDigit()
                Text("avg \(Fmt.speedUnit)").font(.system(size: 10, weight: .medium))
                    .foregroundColor(over ? .white.opacity(0.9) : .secondary)
            }
            if let limit = check.limitKmh { SpeedLimitSign(kmh: limit) }
        }
        .foregroundColor(over ? .white : .primary)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 18).fill(over ? Vela.closed : Vela.sheet(scheme))
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2))
        .accessibilityElement(children: .combine)
    }
}

struct CameraBadge: View {
    let kind: RoadCamera.Kind
    var size: CGFloat = 28

    var body: some View {
        Image(uiImage: Self.icon(kind))
            .resizable()
            .frame(width: size, height: size)
    }

    private static func icon(_ kind: RoadCamera.Kind) -> UIImage {
        switch kind {
        case .speed: return MapIcons.speedCamera()
        case .plate: return MapIcons.plateCamera()
        case .watch: return MapIcons.watchCamera()
        }
    }
}

/// A deep card, the same on the turn and on the time bar. Not the washed mint.
struct TripSheen: View {
    var progress: Double
    var capsule: Bool
    var radius: CGFloat = 28

    var body: some View {
        let shape = Capsule()
        let round = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let gloss = LinearGradient(colors: [Color.white.opacity(0.14), Color.white.opacity(0.03), .clear],
                                   startPoint: .top, endPoint: .center)
        Group {
            if capsule {
                shape.fill(tripTint(progress))
                    .overlay(shape.fill(gloss))
                    .overlay(shape.strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
            } else {
                round.fill(tripTint(progress))
                    .overlay(round.fill(gloss))
                    .overlay(round.strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            }
        }
    }
}

@MainActor
func tripProgress(_ nav: Navigator) -> Double {
    let total = max(nav.route.distanceMeters, 1)
    return min(1, max(0, (nav.progress?.alongMeters ?? 0) / total))
}

func tripTint(_ t: Double) -> Color {
    let u = min(1, max(0, t))
    func channel(_ hex: UInt32, _ shift: Int) -> Double { Double((hex >> shift) & 0xFF) / 255 }
    let start: UInt32 = 0x12312C
    let end: UInt32 = 0x1A2740
    return Color(red: channel(start, 16) * (1 - u) + channel(end, 16) * u,
                 green: channel(start, 8) * (1 - u) + channel(end, 8) * u,
                 blue: channel(start, 0) * (1 - u) + channel(end, 0) * u)
}

/** Find a stop ahead without leaving navigation: gas, food, coffee… near the road still to drive. */
struct AlongRouteSheet: View {
    @ObservedObject var nav: Navigator
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var found: [(place: Place, ahead: Double)] = []
    @State private var searching = false
    @State private var picked: String?

    private let kinds: [(String, String, String)] = [
        (Fmt.yards ? "Petrol" : "Gas", "fuelpump.fill", Fmt.yards ? "petrol station" : "gas station"), ("EV charging", "bolt.car.fill", "ev charging station"),
        ("Coffee", "cup.and.saucer.fill", "coffee"), ("Food", "fork.knife", "restaurants"),
        (Fmt.yards ? "Supermarket" : "Groceries", "cart.fill", Fmt.yards ? "supermarket" : "grocery store"),
        (Fmt.yards ? "Toilets" : "Restrooms", "toilet.fill", Fmt.yards ? "public toilets" : "public restroom"),
        ("Parking", "parkingsign", "parking"), ("Pharmacy", "cross.case.fill", "pharmacy"),
    ]

    var body: some View {
        NavigationView {
            List {
                Section {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                        ForEach(kinds, id: \.0) { k in
                            Button { run(k.2, label: k.0) } label: {
                                Label(k.0, systemImage: k.1)
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12).frame(height: 40)
                                    .background(RoundedRectangle(cornerRadius: 10).fill(picked == k.0 ? Vela.routeBlue.opacity(0.22) : Color.secondary.opacity(0.12)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                }
                if searching {
                    HStack { ProgressView(); Text("Looking along your route…").foregroundColor(.secondary) }
                } else if picked != nil && found.isEmpty {
                    Text("Nothing found close to the road ahead.").foregroundColor(.secondary)
                }
                if !found.isEmpty {
                    Section("Ahead on your route") {
                        ForEach(found, id: \.place.id) { f in
                            Button {
                                nav.addStop(f.place)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(f.place.name).foregroundColor(.primary).lineLimit(1)
                                        HStack(spacing: 6) {
                                            if let r = f.place.rating { Text(String(format: "%.1f ★", r)) }
                                            if let st = f.place.statusText { Text(st).lineLimit(1) }
                                        }
                                        .font(.caption).foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text("in \(Fmt.distance(f.ahead))").font(.subheadline.weight(.medium)).foregroundColor(.primary)
                                        Text("Add stop").font(.caption.weight(.semibold)).foregroundColor(Vela.routeBlue)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Search along route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }

    private func run(_ query: String, label: String) {
        picked = label
        searching = true
        found = []
        let line = nav.route.polyline
        let cum = Geo.cumulative(line)
        let here = nav.progress?.alongMeters ?? 0
        let total = cum.last ?? 0
        // The next stretch of road, up to 40 km: search around its middle, wide enough to cover it.
        let end = min(total, here + 40_000)
        let mid = Geo.point(along: line, meters: (here + end) / 2, cumulative: cum)
        let span = max(end - here, 3_000)
        let useGoogle = !settings.noGoogle
        Task {
            let r = await PlaceSearch.search(query, center: mid, spanMeters: span, useGoogle: useGoogle)
            var out: [(Place, Double)] = []
            for p in r.places {
                let at = Geo.project(p.location, on: line, cumulative: cum)
                // Close to the road (a short detour) and still ahead of you.
                guard at.offset < 800, at.along > here + 100 else { continue }
                out.append((p, at.along - here))
            }
            found = out.sorted { $0.1 < $1.1 }.prefix(20).map { (place: $0.0, ahead: $0.1) }
            searching = false
        }
    }
}

/** Road numbers in an instruction ("I-80", "US 50", "CA 113", "A9"), for shields in the banner. */
enum RoadRefs {
    static func find(_ text: String) -> [String] {
        let pattern = #"\b(I|US|CA|SR|State Route|Route|Hwy|Highway|A|B|M|E|N|D|B|SS)[- ]?(\d{1,4}[A-Z]?)\b"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        var out: [String] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let net = ns.substring(with: m.range(at: 1)), num = ns.substring(with: m.range(at: 2))
            let ref: String
            switch net {
            case "I": ref = "I-\(num)"
            case "US": ref = "US \(num)"
            case "CA", "SR", "State Route", "Route", "Hwy", "Highway": ref = "SR \(num)"
            default: ref = net + num
            }
            if !out.contains(ref) { out.append(ref) }
        }
        return Array(out.prefix(3))
    }
}

/** A road number drawn like its sign: Interstate blue-and-red, US white, others a plain plate. */
struct RoadShield: View {
    let ref: String

    var body: some View {
        if ref.hasPrefix("I-") {
            let n = String(ref.dropFirst(2))
            ZStack(alignment: .top) {
                Color(hex: 0x003F87)
                Color(hex: 0xC8102E).frame(height: 9)
                Text(n).font(.system(size: 14, weight: .heavy)).foregroundColor(.white).padding(.top, 10)
            }
            .frame(width: n.count > 2 ? 40 : 32, height: 32)
            .mask(InterstateShape())
            .overlay(InterstateShape().stroke(.white, lineWidth: 1.5))
        } else if ref.hasPrefix("US ") {
            Text(String(ref.dropFirst(3)))
                .font(.system(size: 14, weight: .heavy)).foregroundColor(.black)
                .frame(minWidth: 30).frame(height: 30).padding(.horizontal, 2)
                .background(InterstateShape().fill(.white))
                .overlay(InterstateShape().inset(by: 2).stroke(.black, lineWidth: 1.5))
        } else if let uk = Self.british(ref) {
            // British plates: blue for motorways, green with yellow numbers for primary A roads.
            Text(ref)
                .font(.system(size: 14, weight: .heavy)).foregroundColor(uk == .motorway ? .white : Color(hex: 0xFFD200))
                .padding(.horizontal, 7).frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 4).fill(uk == .motorway ? Color(hex: 0x0079C1) : Color(hex: 0x00703C)))
                .overlay(RoundedRectangle(cornerRadius: 4).inset(by: 1.5).stroke(.white, lineWidth: 1))
        } else {
            Text(ref.hasPrefix("SR ") ? String(ref.dropFirst(3)) : ref)
                .font(.system(size: 14, weight: .heavy)).foregroundColor(.black)
                .padding(.horizontal, 7).frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 5).fill(.white))
                .overlay(RoundedRectangle(cornerRadius: 5).inset(by: 1.5).stroke(.black, lineWidth: 1.5))
        }
    }
}

extension RoadShield {
    enum British { case motorway, primary }

    /** "M4" or "A1(M)" are motorways, "A470" a primary road; only where units are British. */
    static func british(_ ref: String) -> British? {
        guard Fmt.yards else { return nil }
        if ref.range(of: #"^(M\d+|A\d+\(M\))$"#, options: .regularExpression) != nil { return .motorway }
        if ref.range(of: #"^A\d+$"#, options: .regularExpression) != nil { return .primary }
        return nil
    }
}

/** A shield outline: flat top with dips, sides curving into a point. */
struct InterstateShape: InsettableShape {
    var inset: CGFloat = 0

    func inset(by amount: CGFloat) -> InterstateShape { var s = self; s.inset += amount; return s }

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY + r.height * 0.08))
        p.addQuadCurve(to: CGPoint(x: r.midX, y: r.minY + r.height * 0.06), control: CGPoint(x: r.minX + r.width * 0.25, y: r.minY - r.height * 0.04))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.08), control: CGPoint(x: r.maxX - r.width * 0.25, y: r.minY - r.height * 0.04))
        p.addCurve(to: CGPoint(x: r.midX, y: r.maxY), control1: CGPoint(x: r.maxX + r.width * 0.05, y: r.minY + r.height * 0.6),
                   control2: CGPoint(x: r.midX + r.width * 0.3, y: r.maxY - r.height * 0.05))
        p.addCurve(to: CGPoint(x: r.minX, y: r.minY + r.height * 0.08), control1: CGPoint(x: r.midX - r.width * 0.3, y: r.maxY - r.height * 0.05),
                   control2: CGPoint(x: r.minX - r.width * 0.05, y: r.minY + r.height * 0.6))
        p.closeSubpath()
        return p
    }
}

/** Which lanes to be in, the way Waze and Google draw it: the right ones lit up, the rest dim. */
struct LaneStrip: View {
    let lanes: [Lane]
    let turn: ManeuverType
    /** At a roundabout: where the exit is (degrees clockwise from straight ahead). */
    var exitAngle: Double?

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(lanes.prefix(6).enumerated()), id: \.offset) { _, lane in
                Image(systemName: Self.symbol(pick(lane)))
                    .font(.system(size: 26, weight: .heavy))
                    .foregroundColor(lane.valid ? Vela.navBand : .white.opacity(0.4))
                    .frame(width: 48, height: 48)
                    .background(RoundedRectangle(cornerRadius: 12).fill(lane.valid ? Color.white : Color.white.opacity(0.1)))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Use the highlighted lanes")
    }

    /** A lane that goes several ways shows the way this turn goes when it's a good lane. */
    private func pick(_ lane: Lane) -> String {
        guard lane.valid, lane.indications.count > 1 else { return lane.indications.first ?? "straight" }
        let want: [String]
        var t = turn
        if t == .roundabout, let a = exitAngle {
            t = a > 200 && a < 340 ? .turnLeft : (a > 20 && a < 160 ? .turnRight : .straight)
        }
        switch t {
        case .turnLeft, .sharpLeft, .rampLeft: want = ["left", "sharp left", "slight left"]
        case .slightLeft, .forkLeft, .keepLeft: want = ["slight left", "left"]
        case .turnRight, .sharpRight, .rampRight: want = ["right", "sharp right", "slight right"]
        case .slightRight, .forkRight, .keepRight: want = ["slight right", "right"]
        case .uturn: want = ["uturn"]
        default: want = ["straight"]
        }
        return want.first { lane.indications.contains($0) } ?? lane.indications[0]
    }

    static func symbol(_ indication: String) -> String {
        switch indication {
        case "left": return "arrow.turn.up.left"
        case "sharp left": return "arrow.turn.left.down"
        case "slight left": return "arrow.up.left"
        case "right": return "arrow.turn.up.right"
        case "sharp right": return "arrow.turn.right.down"
        case "slight right": return "arrow.up.right"
        case "uturn": return "arrow.uturn.down"
        default: return "arrow.up"
        }
    }
}

/**
 * The roundabout as it really is: the way in at the bottom, every road around the circle, and
 * only your way round and out lit up. Without the real layout, the exits are spread evenly.
 */
struct RoundaboutDiagram: View {
    let shape: RoundaboutShape?
    let exit: Int
    /** Traffic goes round clockwise (keep-left countries). */
    let clockwise: Bool

    private var layout: RoundaboutShape {
        if let shape, shape.exits.indices.contains(shape.taken) { return shape }
        // Evenly spread up to yours, a little short of the full circle.
        let n = max(exit, 1)
        let step = min(90, 300 / Double(n + 1))
        let sign: Double = clockwise ? 1 : -1
        var exits: [Double] = []
        for k in 1...n {
            let a: Double = 180 + sign * Double(k) * step
            exits.append((a + 360).truncatingRemainder(dividingBy: 360))
        }
        return RoundaboutShape(exits: exits, taken: n - 1, clockwise: clockwise, complete: false)
    }

    var body: some View {
        Canvas { ctx, size in
            let l = layout
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let ring = size.width * 0.2
            let edge = size.width * 0.47
            func pt(_ deg: Double, _ r: CGFloat) -> CGPoint {
                let a: Double = deg * .pi / 180
                let dx = CGFloat(sin(a)) * r
                let dy = CGFloat(cos(a)) * r
                return CGPoint(x: c.x + dx, y: c.y - dy)
            }
            let faint = GraphicsContext.Shading.color(.white.opacity(0.32))
            let road = StrokeStyle(lineWidth: size.width * 0.075, lineCap: .round)
            // Every road and the circle, dim.
            for a in l.exits + l.entriesOnly + [180] {
                var p = Path()
                p.move(to: pt(a, ring))
                p.addLine(to: pt(a, l.entriesOnly.contains(a) ? edge * 0.85 : edge))
                ctx.stroke(p, with: faint, style: road)
            }
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - ring, y: c.y - ring, width: ring * 2, height: ring * 2)), with: faint, style: road)
            // Yours: in from the bottom, round the way traffic goes, and out.
            let out = l.exits[l.taken]
            let sweep = l.turn(l.taken)
            var path = Path()
            path.move(to: pt(180, edge))
            path.addLine(to: pt(180, ring))
            let steps = max(Int(sweep / 6), 2)
            let sign: Double = l.clockwise ? 1 : -1
            for i in 1...steps {
                let f = Double(i) / Double(steps)
                let a: Double = 180 + sign * sweep * f
                path.addLine(to: pt(a, ring))
            }
            let tip = pt(out, edge - size.width * 0.07)
            path.addLine(to: tip)
            ctx.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: size.width * 0.1, lineCap: .round, lineJoin: .round))
            // The arrowhead on the way out.
            let a = out * .pi / 180
            let dir = CGPoint(x: CGFloat(sin(a)), y: CGFloat(-cos(a)))
            let side = CGPoint(x: -dir.y, y: dir.x)
            let w = size.width * 0.12, len = size.width * 0.14
            let base = CGPoint(x: tip.x - dir.x * 2, y: tip.y - dir.y * 2)
            let nose = CGPoint(x: base.x + dir.x * len, y: base.y + dir.y * len)
            let left = CGPoint(x: base.x + side.x * w, y: base.y + side.y * w)
            let right = CGPoint(x: base.x - side.x * w, y: base.y - side.y * w)
            var head = Path()
            head.move(to: nose)
            head.addLine(to: left)
            head.addLine(to: right)
            head.closeSubpath()
            ctx.fill(head, with: .color(.white))
            // The exit number in the middle, as well as "6th exit" beside the picture.
            let digits = Text("\(exit)")
                .font(.system(size: size.width * (exit >= 10 ? 0.17 : 0.22), weight: .heavy))
                .foregroundColor(.white)
            ctx.draw(digits, at: c)
        }
        .accessibilityLabel("Roundabout, take exit \(exit)")
    }
}
