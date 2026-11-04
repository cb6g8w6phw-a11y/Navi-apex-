import SwiftUI

/** Turn-by-turn: the green instruction banner, map buttons, and the ETA bar. */
struct NavigationOverlay: View {
    @ObservedObject var model: AppModel
    @ObservedObject var nav: Navigator
    @State private var showSteps = false
    @State private var showAlong = false
    @State private var confirmEnd = false
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
    private var chipShowing: Bool { showRiskChip || (nav.aircraftNear != nil && !nav.arrived && aircraftAsChip) || (nav.fuelAhead != nil && !nav.arrived) }

    /** With a camera and a Waze report both up, the average check waits its turn: there's only so much screen. */
    private var showAverage: Bool { !(nav.cameraAhead != nil && nav.wazeAhead != nil) }

    var body: some View {
        // One column, so however many warnings are up, they push the map buttons down rather than cover them.
        VStack(spacing: 10) {
            VStack(spacing: 10) {
                if nav.arrived {
                    ArrivedCard(name: nav.destination.name, onPark: nav.route.mode == .drive ? { model.saveParking() } : nil,
                                note: nav.wazeWarned > 0 ? String(format: "waze_warned".localized, nav.wazeWarned) : nil) { model.endNavigation() }
                } else {
                    InstructionBanner(nav: nav)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let cam = nav.cameraAhead, !nav.arrived {
                    CameraCard(alert: cam, speedKmh: nav.speedMps * 3.6)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if let w = nav.wazeAhead, !nav.arrived {
                    WazeCard(ahead: w)
                        .fixedSize(horizontal: false, vertical: true)
                        .onTapGesture { withAnimation { nav.dismissWaze() } }
                        .accessibilityHint("tap_to_hide".localized)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if let r = nav.roadAhead, !nav.arrived {
                    RoadAheadCard(ahead: r, offer: nav.detourOffer,
                                  take: { withAnimation { nav.acceptDetour() } },
                                  hide: { withAnimation { nav.dismissRoad() } })
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.5, anchor: .top).combined(with: .move(edge: .top)).combined(with: .opacity),
                            removal: .move(edge: .top).combined(with: .opacity)))
                }
                if let air = nav.aircraftNear, !nav.arrived, !aircraftAsChip {
                    AircraftCard(aircraft: air.aircraft, meters: air.meters)
                }
                if let check = nav.averageCheck, !nav.arrived, showAverage {
                    AverageCheckCard(check: check)
                }
                if nav.rerouting {
                    Label("rerouting".localized, systemImage: "arrow.triangle.2.circlepath")
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
                    if let f = nav.fuelAhead, !nav.arrived { FuelAheadChip(ahead: f) { withAnimation { nav.dismissFuel() } } }
                    SpeedBadge(mps: nav.speedMps, limitKmh: nav.speedLimitKmh)
                }
                Spacer()
                MapFab(icon: nav.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", size: 64) { nav.muted.toggle() }
                    .accessibilityLabel(nav.muted ? "turn_voice_on".localized : "mute_voice".localized)
            }
            .padding(.horizontal, 16)
            if !nav.following {
                Button { model.recenterNav() } label: {
                    Label("re_centre".localized, systemImage: "location.north.line.fill")
                        .font(.system(size: 20, weight: .bold))
                        .padding(.horizontal, 26).frame(height: 60)
                        .foregroundColor(Vela.onAccent(scheme))
                        .background(Capsule().fill(Vela.accent(scheme)))
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                }
                .buttonStyle(.plain)
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
            } else {
                TripBar(nav: nav, onEnd: {
                    if nav.arrived { model.endNavigation() } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { confirmEnd = true }
                    }
                }, onSteps: { showSteps = true })
                .inSidePanel(panel)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(
            // The road you're on, just under the arrow (the map keeps the arrow at this height while following).
            GeometryReader { g in
                if nav.following, !nav.arrived, !chipShowing, let road = nav.currentRoad {
                    Text(road)
                        .font(.system(size: 17, weight: .bold))
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .padding(.horizontal, 14).frame(height: 36)
                        .foregroundColor(.white)
                        .background(Capsule().fill(Color(hex: 0x0F172A).opacity(0.92)))
                        .overlay(Capsule().strokeBorder(Color(hex: 0x2DD4BF).opacity(0.8), lineWidth: 1.5))
                        // Between the speed sign and the mute button, which sit level with it now the car is lower.
                        .frame(maxWidth: panel > 0 ? g.size.width - panel - 80 : g.size.width - 240)
                        .position(x: panel + (g.size.width - panel) / 2, y: NavGlide.carY(g.size.height) + 50)
                }
            }
            .ignoresSafeArea()
        )
        .task {
            // Screenshot run: the end trip question.
            if DemoScript.step == "endtrip" {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                withAnimation { confirmEnd = true }
            }
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
                            tripAction("magnifyingglass", "find_on_route".localized) {
                                showSteps = false
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { showAlong = true }
                            }
                            ShareLink(item: etaText) { tripActionLabel("square.and.arrow.up", "share_eta".localized) }
                                .buttonStyle(.plain)
                            tripAction("arrow.up.left.and.arrow.down.right", "overview".localized) {
                                showSteps = false
                                model.overviewNav()
                            }
                        }
                        StepsList(route: nav.route, from: nav.progress?.nextIndex ?? 0)
                    }
                    .padding(.horizontal, 16)
                }
                .navigationTitle("your_trip".localized)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("done".localized) { showSteps = false } } }
            }
            .kiteType()
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

/**
 * The next turn, as big as it can be: the real roundabout drawn with every exit and yours lit,
 * the distance, the road, and below it which lane to be in.
 */
struct InstructionBanner: View {
    @ObservedObject var nav: Navigator

    var body: some View {
        let m = nav.nextManeuver
        let leftTraffic = Geo.drivesOnLeft(m?.location ?? LatLng(0, 0))
        let refs = RoadRefs.find(m?.instruction ?? "")
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                if m?.type == .roundabout {
                    RoundaboutDiagram(shape: m?.roundabout, exit: m?.exit ?? 1, clockwise: leftTraffic)
                        .frame(width: 100, height: 100)
                } else {
                    Image(systemName: maneuverSymbol(m?.type ?? .straight))
                        .font(.system(size: 62, weight: .heavy))
                        .frame(width: 100, height: 100)
                }
                VStack(alignment: .leading, spacing: 4) {
                    if let p = nav.progress {
                        Text(Fmt.distance(p.distanceToNext))
                            .font(.system(size: 46, weight: .heavy))
                            .monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.6)
                    }
                    if let parts = Self.split(Self.headline(m)) {
                        // "At the end of the road, turn left" small, the road you turn onto big, like Waze.
                        Text(parts.0)
                            .font(.system(size: 17, weight: .semibold)).opacity(0.9)
                            .lineLimit(1).minimumScaleFactor(0.75)
                        Text(parts.1)
                            .font(.system(size: 25, weight: .heavy))
                            .lineLimit(2).minimumScaleFactor(0.7)
                    } else {
                        Text(Self.headline(m))
                            .font(.system(size: 23, weight: .bold))
                            .lineLimit(2)
                            .minimumScaleFactor(0.75)
                    }
                    if !refs.isEmpty {
                        HStack(spacing: 6) { ForEach(refs, id: \.self) { RoadShield(ref: $0) } }
                            .padding(.top, 2)
                    } else if m?.type == .roundabout, let road = m?.road {
                        Text(String(format: "onto_road".localized, road)).font(.system(size: 18, weight: .semibold)).opacity(0.9).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            if let m, let p = nav.progress, p.distanceToNext < 1_500, let lanes = LaneGuide.lanes(for: m, leftTraffic: leftTraffic) {
                HStack(spacing: 14) {
                    LaneStrip(lanes: lanes.lanes, turn: m.type, exitAngle: m.roundabout.map { $0.exits[$0.taken] })
                    Text(lanes.words).font(.system(size: 19, weight: .bold)).lineLimit(2).minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    thenView
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Vela.navBand)
            } else if nav.thenManeuver != nil {
                HStack { Spacer(); thenView }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Vela.navBand)
            }
        }
        .foregroundColor(.white)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Vela.navGreen))
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 5)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var thenView: some View {
        if let then = nav.thenManeuver {
            HStack(spacing: 6) {
                Text("then".localized).font(.system(size: 16, weight: .bold)).opacity(0.85)
                Image(systemName: maneuverSymbol(then.type)).font(.system(size: 20, weight: .heavy))
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
        guard let m else { return "follow_route".localized }
        if m.type == .roundabout, let n = m.exit { return String(format: "exit_number".localized, n) }
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
        if first == 0 { words = String(format: "left_lanes".localized, many) }
        else if last == n - 1 { words = String(format: "right_lanes".localized, many) }
        else if count == 1 && n > 3 { words = String(format: "lane_from_left".localized, first + 1) }
        else { words = count > 1 ? "middle_lanes".localized : "middle_lane".localized }
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
            Text("\(v)").font(.system(size: 36, weight: .heavy)).monospacedDigit()
                .foregroundColor(over ? .white : .primary)
            Text(metric ? "km/h" : "mph").font(.system(size: 14, weight: .semibold))
                .foregroundColor(over ? .white.opacity(0.85) : Vela.muted(scheme))
        }
        Group {
            if let limitKmh {
                VStack(spacing: 6) {
                    SpeedLimitSign(kmh: limitKmh, size: 76)
                    speed
                }
                .padding(.top, 8).padding(.bottom, 12)
                .frame(width: 92)
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
        VStack(spacing: 14) {
            VStack(spacing: 2) {
                Text("end_this_trip".localized).font(.system(size: 24, weight: .heavy))
                Text(String(format: "to_destination".localized, destination)).font(.system(size: 16, weight: .medium))
                    .foregroundColor(Vela.muted(scheme)).lineLimit(1)
            }
            HStack(spacing: 12) {
                Button(action: onKeep) {
                    Text("keep_going".localized).font(.system(size: 20, weight: .bold))
                        .frame(maxWidth: .infinity).frame(height: 60)
                        .foregroundColor(Vela.onAccent(scheme))
                        .background(Capsule().fill(Vela.accent(scheme)))
                }
                Button(action: onEnd) {
                    Text("end_trip".localized).font(.system(size: 20, weight: .bold))
                        .frame(maxWidth: .infinity).frame(height: 60)
                        .foregroundColor(.white)
                        .background(Capsule().fill(Vela.closed))
                }
            }
            .buttonStyle(.plain)
        }
        .foregroundColor(.primary)
        .padding(18)
        .glass(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding(.horizontal, 12)
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
                    .font(.system(size: 24, weight: .heavy))
                    .foregroundColor(scheme == .dark ? Color(hex: 0xFCA5A5) : Vela.closed)
                    .frame(width: 64, height: 64)
                    .background(Circle().fill(scheme == .dark ? Color(hex: 0x3B1820) : Color(hex: 0xFEE2E2)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("end_trip".localized)
            VStack(spacing: 1) {
                Text(Fmt.duration(remaining)).font(.system(size: 36, weight: .heavy))
                    .foregroundColor(Vela.accentText(scheme))
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text("\(Fmt.distance(meters)) · \(Fmt.arrival(remaining))").font(.system(size: 17, weight: .medium))
                    .foregroundColor(Vela.muted(scheme))
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            Button(action: onSteps) {
                Image(systemName: "list.bullet")
                    .font(.system(size: 24, weight: .bold))
                    .frame(width: 64, height: 64)
                    .background(Circle().fill(Vela.chip(scheme)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("trip_and_steps".localized)
        }
        .foregroundColor(.primary)
        .padding(.horizontal, 16)
        .frame(height: 100)
        .glass(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
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
                Text("arrived".localized).font(.system(size: 26, weight: .heavy))
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
                .accessibilityLabel("save_parking".localized)
            }
            Button(action: done) {
                Text("done".localized).font(.system(size: 20, weight: .bold))
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
        let over = alert.limitKmh.map { speedKmh > $0 + 3 } ?? false
        let left = min(max(alert.meters / alert.startMeters, 0), 1)
        let fill: Color = over ? Vela.closed : (alert.kind == .speed ? Vela.camera : Color(hex: 0x8E44AD))
        // Compact, Waze-style: about half the old card's height and only as wide as it needs,
        // so the road ahead stays in view; the bright color and pulses keep it hard to miss.
        VStack(spacing: 7) {
            HStack(spacing: 10) {
                CameraBadge(kind: alert.kind, size: 42)
                VStack(alignment: .leading, spacing: -2) {
                    Text(Fmt.distance(alert.meters)).font(.system(size: 30, weight: .heavy)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text(over ? "slow_down".localized : alert.kind == .speed ? "speed_camera".localized : "plate_camera".localized)
                        .font(.system(size: 15, weight: .bold))
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                if let limit = alert.limitKmh { SpeedLimitSign(kmh: limit, size: 50).padding(.leading, 4) }
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white