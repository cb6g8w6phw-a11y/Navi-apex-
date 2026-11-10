import SwiftUI

/** Route preview: the from/to card on top, routes on the map, the trip sheet below. */
struct DirectionsOverlay: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var mind = MindSettings.shared
    /** How tall the from/to card is, so the sheet at full height stops below it. */
    @State private var cardHeight: CGFloat = 110

    /// The zone this pin or this line still has to enter. Hidden once you're already inside.
    private var zone: RouteMind.Zone? {
        guard mind.umwelt, let d = model.directions else { return nil }
        let me = d.reversed ? d.destination.location : model.userLatLng
        let dest = d.reversed ? model.userLatLng : d.destination.location
        return RouteMind.umweltToShow(me: me, destination: dest, line: d.route?.polyline ?? [], along: 0, driving: false)
    }

    var body: some View {
        GeometryReader { geo in
            let full = geo.size.height + geo.safeAreaInsets.bottom
            ZStack(alignment: .top) {
                VStack {
                    Spacer()
                    BottomSheet(detent: $model.detent, containerHeight: full, peekHeight: model.directions?.transit == true ? 170 : 215,
                                topClearance: cardHeight + 16) {
                        TripHeader(model: model)
                    } content: {
                        TripBody(model: model)
                    }
                }
                .ignoresSafeArea(edges: .bottom)
                if let d = model.directions {
                    EndpointsCard(model: model, state: d)
                        .padding(.top, 6)
                        .background(GeometryReader { g in
                            Color.clear
                                .onAppear { cardHeight = g.size.height }
                                .onChange(of: g.size.height) { cardHeight = $0 }
                        })
                }
                if let zone {
                    // Upper left, under the from/to card: the sheet must not cover it.
                    VStack {
                        HStack {
                            UmweltChip(name: zone.name, blocked: !settings.mayEnterUmwelt && model.directions?.mode == .drive)
                            Spacer(minLength: 0)
                        }
                        .padding(.leading, 16)
                        .padding(.trailing, 72)
                        .padding(.top, cardHeight + 12)
                        Spacer()
                    }
                    .allowsHitTesting(false)
                }
            }
            // Never wider than the screen, whatever a row inside asks for: a long trip's row once
            // pushed the whole screen, from/to box included, off the right edge.
            .frame(width: geo.size.width)
        }
    }
}

struct EndpointsCard: View {
    @ObservedObject var model: AppModel
    let state: DirectionsState
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 10) {
            Button { withAnimation { model.closeDirections() } } label: {
                Image(systemName: "arrow.left").font(.system(size: 18, weight: .bold))
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Wróć")
            VStack(spacing: 0) {
                endpoint(icon: "circle", color: Vela.tealLight, text: state.reversed ? state.destination.name : "Twoja lokalizacja")
                ForEach(Array(state.stops.enumerated()), id: \.offset) { i, stop in
                    Divider().padding(.leading, 30)
                    HStack(spacing: 12) {
                        Text("\(i + 1)").font(.system(size: 11, weight: .bold)).foregroundColor(.white)
                            .frame(width: 18, height: 18).background(Circle().fill(Color.secondary))
                        Text(stop.name).font(.body.weight(.medium)).lineLimit(1)
                        Spacer()
                        Button { model.removeStop(i) } label: { Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)) }
                            .buttonStyle(.plain).foregroundColor(.secondary)
                            .accessibilityLabel("Usuń postój")
                    }
                    .frame(height: 38)
                }
                Divider().padding(.leading, 30)
                endpoint(icon: "mappin.circle.fill", color: Vela.closed, text: state.reversed ? "Twoja lokalizacja" : state.destination.name)
                if !state.transit && state.stops.count < 8 {
                    Divider().padding(.leading, 30)
                    Button { model.addingStop = true } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "plus").font(.system(size: 14, weight: .bold)).frame(width: 18)
                            Text("Dodaj postój").font(.system(size: 15, weight: .semibold))
                            Spacer()
                        }
                        .foregroundColor(Vela.accentText(scheme))
                        .frame(height: 34)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Button { model.reverseDirections() } label: {
                Image(systemName: "arrow.up.arrow.down").font(.system(size: 15, weight: .bold))
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Vela.chip(scheme)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Zamień start i cel")
        }
        .foregroundColor(.primary)
        .padding(.leading, 4)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .glass(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 16)
    }

    private func endpoint(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 16, weight: .bold)).foregroundColor(color).frame(width: 18)
            Text(text).font(.system(size: 16, weight: .semibold)).lineLimit(1)
            Spacer()
        }
        .frame(height: 38)
    }
}

/** The part of the trip sheet always in view: how long, how you go, and a giant Go. */
struct TripHeader: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let d = model.directions {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    if d.transit {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d.pickedTrip.map { Fmt.duration($0.durationSeconds) } ?? "Transit")
                                .font(.system(size: 30, weight: .heavy)).foregroundColor(Vela.accentText(scheme))
                            Text("Komunikacją").font(.system(size: 17, weight: .medium)).foregroundColor(Vela.muted(scheme))
                        }
                    } else if let r = d.route {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Fmt.duration(r.durationSeconds))
                                .font(.system(size: 32, weight: .heavy))
                                .foregroundColor(TripBody.delayColor(r, scheme))
                                .lineLimit(1).minimumScaleFactor(0.7)
                            Text("\(Fmt.distance(r.distanceMeters)) · przyjazd \(Fmt.arrival(r.durationSeconds))")
                                .font(.system(size: 14, weight: .medium)).foregroundColor(Vela.muted(scheme))
                                .lineLimit(1).minimumScaleFactor(0.8)
                            if r.mode == .drive {
                                let fact = TripExtras.costLine(meters: r.distanceMeters, consumption: settings.carConsumption,
                                                               litresLeft: settings.fuelLeft, price: model.fuelBest?.price)
                                Text(fact.text)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(fact.short ? Color(hex: 0xDC2626) : Vela.muted(scheme))
                                    .lineLimit(2)
                            }
                        }
                    } else if d.loading.contains(d.mode) {
                        HStack(spacing: 10) { ProgressView(); Text("Szukam tras…").font(.system(size: 19, weight: .semibold)) }
                            .frame(height: 52)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(d.errors[d.mode] ?? "Nie znaleziono trasy.").font(.system(size: 18, weight: .semibold))
                                .foregroundColor(Vela.muted(scheme))
                                .fixedSize(horizontal: false, vertical: true)
                            if model.location.denied {
                                PillButton(title: "Otwórz ustawienia", icon: "location.fill", filled: true) { LocationService.openSettings() }
                            } else if d.errors[d.mode] != nil {
                                PillButton(title: "Spróbuj ponownie", icon: "arrow.clockwise") { model.reloadRoutes() }
                            }
                        }
                        .frame(minHeight: 52)
                    }
                    Spacer(minLength: 8)
                    if !d.transit {
                        Menu {
                            Toggle("Unikaj opłat", isOn: $settings.avoidTolls)
                            Toggle("Unikaj autostrad", isOn: $settings.avoidHighways)
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.primary)
                                .frame(width: 38, height: 38)
                                .background(Circle().fill(Vela.chip(scheme)))
                        }
                        .accessibilityLabel("Opcje trasy")
                        .onChange(of: settings.avoidTolls) { _ in model.reloadRoutes() }
                        .onChange(of: settings.avoidHighways) { _ in model.reloadRoutes() }
                    }
                }
                ModeTabs(model: model, state: d)
                if !d.transit, !d.reversed, d.route != nil {
                    Button { model.startNavigation() } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "location.north.fill").font(.system(size: 19, weight: .bold))
                            Text("Jedź").font(.system(size: 21, weight: .heavy))
                        }
                        .foregroundColor(Vela.onAccent(scheme))
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Capsule().fill(Vela.accent(scheme)))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Jedź")
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 10)
        }
    }
}

struct ModeTabs: View {
    @ObservedObject var model: AppModel
    let state: DirectionsState
    @Environment(\.colorScheme) private var scheme

    private func icon(_ m: TravelMode) -> String {
        switch m {
        case .drive: return "car.fill"
        case .bike: return "bicycle"
        case .walk: return "figure.walk"
        }
    }

    var body: some View {
        // Four equal tiles, always all in view, so the right one is easy to hit.
        HStack(spacing: 8) {
            ForEach(TravelMode.allCases) { m in
                let on = !state.transit && m == state.mode
                tile(icon: icon(m), on: on, loading: state.loading.contains(m),
                     time: state.routes[m]?.first.map { Fmt.shortDuration($0.durationSeconds) }) { model.setMode(m) }
                    .accessibilityLabel(m.label)
            }
            tile(icon: "tram.fill", on: state.transit, loading: state.trips == nil,
                 time: state.trips?.map(\.durationSeconds).min().map(Fmt.shortDuration)) { model.showTransit() }
                .accessibilityLabel("Komunikacja")
        }
    }

    private func tile(icon: String, on: Bool, loading: Bool, time: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 17, weight: .semibold))
                if loading {
                    ProgressView().scaleEffect(0.7).frame(height: 16)
                } else {
                    Text(time ?? "–").font(.system(size: 13, weight: .bold)).lineLimit(1).minimumScaleFactor(0.6)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 46)
            .foregroundColor(on ? Vela.onAccent(scheme) : .primary)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(on ? Vela.accent(scheme) : Vela.chip(scheme)))
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }
}

struct TripBody: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var scheme
    @State private var pathNote: String?
    @State private var findingParking = false

    var body: some View {
        if let d = model.directions {
            ScrollView {
                SheetTopMarker()
                VStack(alignment: .leading, spacing: 12) {
                    if d.transit {
                        TransitBody(model: model, state: d)
                    } else if let r = d.route {
                        summary(r, d)
                        if let url = d.destination.shareURL { shareButton(url) }
                        if d.current.count > 1 { alternates(d, picked: r) }
                        Divider()
                        Text("Kroki").font(.headline)
                        StepsList(route: r)
                    } else if d.loading.contains(d.mode) {
                        HStack { ProgressView(); Text("Szukam tras…").foregroundColor(.secondary) }
                            .padding(.vertical, 20)
                    } else {
                        Text(d.errors[d.mode] ?? "Nie znaleziono trasy.").foregroundColor(.secondary).padding(.vertical, 20)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 80)
            }
            .sheetScroll()
            .task(id: d.route?.id) {
                guard let r = model.directions?.route else { pathNote = nil; return }
                pathNote = await TripExtras.pathNote(line: r.polyline, mode: r.mode)
            }
        }
    }

    static func delayColor(_ r: Route, _ scheme: ColorScheme) -> Color {
        switch r.delayLevel {
        case 2: return scheme == .dark ? Vela.closedDark : Vela.closed
        case 1: return Color(hex: 0xE37400)
        default: return Vela.accentText(scheme)
        }
    }

    private func delayColor(_ r: Route) -> Color { Self.delayColor(r, scheme) }

    private func summary(_ r: Route, _ d: DirectionsState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            let best = d.current.map(\.durationSeconds).min() ?? r.durationSeconds
            let lead = r.durationSeconds <= best + 30 ? (r.trafficSeconds != nil ? "Najszybsza trasa teraz" : "Najlepsza trasa") : "Wolniejsza trasa"
            Text([lead, r.summary.map { "przez \($0)" }].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 18, weight: .semibold))
            if r.mode == .drive, r.trafficSeconds != nil {
                Text(r.delayLevel == 0 ? "Ruch lekki" : "\(Fmt.duration(r.durationSeconds - r.typicalSeconds)) wolniej niż zwykle")
                    .font(.system(size: 17, weight: .semibold)).foregroundColor(delayColor(r))
            }
            if r.mode == .drive { RouteWazeSummary(route: r).padding(.top, 4) }
            if r.mode == .drive {
                let fact = TripExtras.costLine(meters: r.distanceMeters, consumption: AppSettings.shared.carConsumption,
                                               litresLeft: AppSettings.shared.fuelLeft, price: model.fuelBest?.price)
                Text(fact.text).font(.system(size: 16, weight: .semibold))
                    .foregroundColor(fact.short ? Color(hex: 0xDC2626) : Vela.muted(scheme))
            }
            if let pathNote {
                Text(pathNote).font(.subheadline).foregroundColor(Vela.muted(scheme))
            }
            if let usual = TripExtras.usual(id: d.destination.id) {
                Text(usual).font(.subheadline).foregroundColor(Vela.muted(scheme))
            }
            HStack(spacing: 8) {
                Button {
                    guard !findingParking else { return }
                    findingParking = true
                    Task {
                        let pins = await TripExtras.parking(near: d.destination.location)
                        findingParking = false
                        if pins.isEmpty { model.notice = "Brak parkingu w danych mapy przy celu." }
                        else { model.showStopsOnMap(pins) }
                    }
                } label: {
                    Text(findingParking ? "Szukam parkingu…" : "Parking przy celu")
                        .font(.system(size: 15, weight: .bold))
                        .padding(.horizontal, 14).frame(height: 40)
                        .background(Capsule().fill(Vela.chip(scheme)))
                }
                .buttonStyle(.plain)
                if let url = TripExtras.sms(arrive: Date().addingTimeInterval(r.durationSeconds), place: d.destination.name) {
                    Link(destination: url) {
                        Text("Wyślij że dojadę")
                            .font(.system(size: 15, weight: .bold))
                            .padding(.horizontal, 14).frame(height: 40)
                            .background(Capsule().fill(Vela.chip(scheme)))
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    private func shareButton(_ url: URL) -> some View {
        ShareLink(item: url) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.arrow.up").font(.system(size: 17, weight: .bold))
                Text("Udostępnij miejsce").font(.system(size: 17, weight: .bold))
            }
            .padding(.horizontal, 20)
            .frame(height: 52)
            .foregroundColor(Vela.onTonal(scheme))
            .background(Capsule().fill(Vela.tonal(scheme)))
        }
        .buttonStyle(.plain)
    }

    /** How much of route [a] runs along route [b] (0 to 1), by looking at about 60 points of [a]. Remembered per pair. */
    private static var overlapCache: [String: Double] = [:]
    static func overlap(_ a: Route, _ b: Route) -> Double {
        let key = "\(a.id)-\(b.id)"
        if let hit = overlapCache[key] { return hit }
        let pa = a.polyline, pb = b.polyline
        guard !pa.isEmpty, !pb.isEmpty else { return 1 }
        let step = max(1, pa.count / 60)
        var near = 0, total = 0
        for i in stride(from: 0, to: pa.count, by: step) {
            total += 1
            let p = pa[i]
            // A cheap look first: a point far away in degrees can't be within 100 m.
            if pb.contains(where: { abs($0.lat - p.lat) < 0.002 && abs($0.lng - p.lng) < 0.003 && $0.distance(to: p) < 100 }) { near += 1 }
        }
        let share = total == 0 ? 1 : Double(near) / Double(total)
        overlapCache[key] = share
        return share
    }

    private func alternates(_ d: DirectionsState, picked: Route) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(d.current.enumerated()), id: \.element.id) { i, r in
                if r.id != picked.id {
                    Button { model.selectRoute(i) } label: {
                        HStack {
                            Image(systemName: "arrow.triangle.branch").foregroundColor(.secondary).frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(Fmt.duration(r.durationSeconds)) · \(Fmt.distance(r.distanceMeters))").font(.subheadline.weight(.medium))
                                if let s = r.summary { Text("przez \(s)").font(.caption).foregroundColor(.secondary) }
                                if Self.overlap(r, picked) < 0.4 {
                                    Text("Inne drogi: omija najbardziej zatłoczoną")
                                        .font(.caption2.weight(.bold)).foregroundColor(Vela.accentText(scheme))
                                }
                            }
                            Spacer()
                            let diff = r.durationSeconds - picked.durationSeconds
                            // Under half a minute apart would round to "+1 min": call it the same.
                            Text(abs(diff) < 30 ? "Tyle samo" : diff > 0 ? "+\(Fmt.duration(diff))" : "−\(Fmt.duration(-diff))")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct StepsList: View {
    let route: Route
    /** While driving: start at the next step, so turns already made aren't listed. */
    var from = 0

    /** The steps worth saying, each with the length of the quiet name changes after it added on. */
    private var shown: [Maneuver] {
        var out: [Maneuver] = []
        for m in route.maneuvers.dropFirst(min(max(from, 0), route.maneuvers.count)) {
            if m.silent, !out.isEmpty { out[out.count - 1].distanceMeters += m.distanceMeters }
            else if !m.silent { out.append(m) }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, m in
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: maneuverSymbol(m.type))
                        .font(.system(size: 22, weight: .bold))
                        .frame(width: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.instruction).font(.system(size: 18, weight: .medium))
                        if let lane = m.laneHint { Text(lane).font(.subheadline).foregroundColor(.secondary) }
                        if m.distanceMeters > 0 {
                            Text(Fmt.distance(m.distanceMeters)).font(.subheadline).foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 9)
                Divider().padding(.leading, 40)
            }
        }
    }
}

/** The Transit tab: each trip as a row of line chips with its times, the picked one's legs below. */
struct TransitBody: View {
    @ObservedObject var model: AppModel
    let state: DirectionsState
    @Environment(\.colorScheme) private var scheme

    @State private var kind = 0
    @State private var when = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $kind) {
                Text("Wyjedź teraz").tag(0)
                Text("Wyjazd o").tag(1)
                Text("Przyjazd do").tag(2)
            }
            .pickerStyle(.segmented)
            if kind != 0 {
                DatePicker("Time", selection: $when, in: Date().addingTimeInterval(-3600)..., displayedComponents: [.date, .hourAndMinute])
                    .font(.subheadline)
            }
        }
        .onAppear {
            kind = state.transitTime == nil ? 0 : (state.arriveBy ? 2 : 1)
            when = state.transitTime ?? Date()
        }
        .onChange(of: kind) { k in model.setTransitTime(kind: k, at: when) }
        .onChange(of: when) { w in if kind != 0 { model.setTransitTime(kind: kind, at: w) } }
        trips
    }

    @ViewBuilder
    private var trips: some View {
        if let trips = state.trips, !trips.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(trips.enumerated()), id: \.element.id) { i, t in
                    Button { model.selectTrip(i) } label: { TripRow(trip: t, picked: t.id == state.pickedTrip?.id) }
                        .buttonStyle(.plain)
                    Divider()
                }
            }
            if let t = state.pickedTrip {
                Text("Kroki").font(.headline).padding(.top, 6)
                TransitSteps(trip: t)
            }
            Text("Rozkłady z Transitous").font(.caption).foregroundColor(.secondary).padding(.top, 4)
        } else if state.trips == nil {
            HStack { ProgressView(); Text("Szukam połączeń…").foregroundColor(.secondary) }
                .padding(.vertical, 20)
        } else {
            Text(state.tripsError ?? "No transit trips found.").foregroundColor(.secondary).padding(.vertical, 20)
        }
    }
}

private let clock: DateFormatter = {
    let f = DateFormatter()
    f.timeStyle = .short
    return f
}()

struct TripRow: View {
    let trip: TransitTrip
    let picked: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                if let a = trip.depart, let b = trip.arrive {
                    Text("\(clock.string(from: a)) – \(clock.string(from: b))").font(.subheadline.weight(.semibold))
                }
                Spacer()
                Text(Fmt.duration(trip.durationSeconds)).font(.headline)
            }
            // Wraps onto more lines for trips with many changes, like Google Maps does.
            WrapLayout(spacing: 4, lineSpacing: 6) {
                ForEach(Array(trip.legs.enumerated()), id: \.offset) { i, leg in
                    HStack(spacing: 4) {
                        if i > 0 { Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundColor(.secondary) }
                        if leg.isWalk {
                            HStack(spacing: 1) {
                                Image(systemName: "figure.walk").font(.system(size: 13))
                                if leg.durationSeconds >= 60 { Text("\(Int((leg.durationSeconds / 60).rounded()))").font(.caption2) }
                            }
                            .foregroundColor(.secondary)
                        } else {
                            LineChip(leg: leg)
                        }
                    }
                }
            }
            .lineLimit(1)
            HStack(spacing: 6) {
                if let first = trip.rides.first, let dep = first.depart {
                    Text("\(clock.string(from: dep)) from \(first.fromName)").lineLimit(1)
                }
                if let late = trip.rides.first?.delayMinutes {
                    Text(late > 0 ? "\(late) min late" : late < 0 ? "\(-late) min early" : "On time")
                        .foregroundColor(late > 1 ? Vela.closed : Vela.open)
                }
            }
            .font(.caption).foregroundColor(.secondary)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(picked ? Color.secondary.opacity(0.14) : Color.clear))
        .contentShape(Rectangle())
    }
}

/** Lays its views out left to right, starting a new line when the next one doesn't fit. */
struct WrapLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews, width: width)
        let used = rows.map { $0.width }.max() ?? 0
        let height = rows.map { $0.height }.reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: min(used, width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                  proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
                x += min(size.width, bounds.width) + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        var items: [Int] = [], x: CGFloat = 0, h: CGFloat = 0
        for (i, v) in subviews.enumerated() {
            let size = v.sizeThatFits(ProposedViewSize(width: width, height: nil))
            let w = min(size.width, width)
            if !items.isEmpty && x + spacing + w > width {
                rows.append((items, x, h))
                items = []; x = 0; h = 0
            }
            x += (items.isEmpty ? 0 : spacing) + w
            h = max(h, size.height)
            items.append(i)
        }
        if !items.isEmpty { rows.append((items, x, h)) }
        return rows
    }
}

/** A line's name on its own color, the way stations sign it. */
struct LineChip: View {
    let leg: TransitLeg

    var body: some View {
        let bg = leg.color.map { Color(hex: $0) } ?? Vela.routeBlue
        let fg = leg.textColor.map { Color(hex: $0) } ?? .white
        HStack(spacing: 3) {
            Image(systemName: vehicleSymbol(leg.vehicle)).font(.system(size: 10, weight: .bold))
            Text(leg.line.isEmpty ? leg.mode.capitalized : leg.line).font(.caption.weight(.bold))
        }
        .padding(.horizontal, 6)
        .frame(height: 22)
        .foregroundColor(fg)
        .background(RoundedRectangle(cornerRadius: 5).fill(bg))
    }
}

func vehicleSymbol(_ v: TransitLeg.Vehicle) -> String {
    switch v {
    case .walk: return "figure.walk"
    case .bus: return "bus.fill"
    case .metro: return "tram.fill.tunnel"
    case .tram: return "tram.fill"
    case .train: return "train.side.front.car"
    case .ferry: return "ferry.fill"
    case .other: return "tram.fill"
    }
}

struct TransitSteps: View {
    let trip: TransitTrip

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(trip.legs.enumerated()), id: \.offset) { _, leg in
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: vehicleSymbol(leg.vehicle))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(leg.isWalk ? .secondary : (leg.color.map { Color(hex: $0) } ?? Vela.routeBlue))
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 3) {
                        if leg.isWalk {
                            Text(leg.toName.isEmpty || leg.toName == "END" ? "Walk to the destination" : "Walk to \(leg.toName)").font(.subheadline)
                            Text("\(Fmt.duration(leg.durationSeconds)) · \(Fmt.distance(leg.distanceMeters))").font(.caption).foregroundColor(.secondary)
                        } else {
                            HStack(spacing: 6) {
                                LineChip(leg: leg)
                                if let h = leg.headsign { Text("to \(h)").font(.subheadline).lineLimit(1) }
                            }
                            Text(times(leg.depart, leg.fromName)).font(.subheadline)
                            Text("\(leg.stops) przystanków · \(Fmt.duration(leg.durationSeconds))")
                                .font(.caption).foregroundColor(.secondary)
                            Text(times(leg.arrive, "Get off at \(leg.toName)")).font(.caption).foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 9)
                Divider().padding(.leading, 40)
            }
        }
    }

    private func times(_ d: Date?, _ text: String) -> String {
        d.map { "\(clock.string(from: $0))  \(text)" } ?? text
    }
}

/** Search for a place to stop at on the way. Home, work and saved places are one tap. */
struct StopPicker: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings = AppSettings.shared
    @State private var query = ""
    @State private var found: [Place] = []
    @State private var searching = false
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    private let along: [(String, String)] = [
        ("Stacje benzynowe", "stacja benzynowa"),
        ("Kawa", "kawa"),
        ("Restauracje", "restauracja"),
        ("Ładowanie auta", "ładowarka samochodowa"),
    ]

    var body: some View {
        NavigationStack {
            List {
                if !found.isEmpty {
                    Section {
                        Button { model.showStopsOnMap(found) } label: {
                            Label("Pokaż na mapie", systemImage: "map")
                                .font(.system(size: 16, weight: .semibold))
                        }
                        ForEach(found) { row($0, icon: "mappin.circle.fill") }
                    } header: {
                        Text("Wyniki")
                    }
                } else if searching {
                    HStack { ProgressView(); Text("Szukam…").foregroundColor(.secondary) }
                }
                let mine = [settings.home.map { ($0, "house.fill") }, settings.work.map { ($0, "briefcase.fill") }].compactMap { $0 }
                    + settings.saved.prefix(12).map { ($0, "bookmark.fill") }
                if !mine.isEmpty && found.isEmpty {
                    Section("Twoje miejsca") { ForEach(mine, id: \.0.id) { row($0.0, icon: $0.1) } }
                }
                if found.isEmpty && !searching {
                    Section("Po drodze") {
                        ForEach(along, id: \.0) { item in
                            Button { query = item.1; run() } label: { Label(item.0, systemImage: "magnifyingglass") }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .listRowSeparator(.hidden)
            .listRowBackground(StopGlassRow())
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Szukaj przystanku")
            .onSubmit(of: .search) { run() }
            .navigationTitle("Dodaj przystanek")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Anuluj") { dismiss() } } }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .modifier(StopSheetBackdrop())
    }

    private func row(_ p: Place, icon: String) -> some View {
        HStack(spacing: 10) {
            Button {
                model.addStop(p)
                dismiss()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: icon).foregroundColor(.secondary).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.name).foregroundColor(.primary).lineLimit(1)
                        if let a = p.address { Text(a).font(.caption).foregroundColor(.secondary).lineLimit(1) }
                    }
                    Spacer(minLength: 0)
                    if let d = model.userLatLng?.distance(to: p.location) {
                        Text(Fmt.distance(d)).font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            Button { model.showStopsOnMap([p]) } label: {
                Image(systemName: "map")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Pokaż na mapie")
        }
    }

    private func run() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        found = []
        // Look between you and where you're going, so stops fall along the way.
        let a = model.userLatLng ?? model.viewport.center
        let b = model.directions?.destination.location ?? a
        let mid = LatLng((a.lat + b.lat) / 2, (a.lng + b.lng) / 2)
        let span = max(a.distance(to: b) * 1.2, 5_000)
        let useGoogle = !settings.noGoogle
        Task {
            let r = await PlaceSearch.search(q, center: mid, spanMeters: span, useGoogle: useGoogle)
            found = Array(r.places.prefix(30))
            searching = false
        }
    }
}

/** The sheet itself is glass, with no colour painted behind it. */
private struct StopSheetBackdrop: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.4, *) {
            content.presentationBackground { StopSheetGlass() }
        } else {
            content.background(StopSheetGlass().ignoresSafeArea())
        }
    }
}

private struct StopSheetGlass: View {
    var body: some View {
        if #available(iOS 26.0, *) {
            Rectangle().fill(.clear).glassEffect(.regular, in: Rectangle())
        } else {
            Rectangle().fill(.ultraThinMaterial)
        }
    }
}

/** One stop row, glass only, not a tinted card. */
private struct StopGlassRow: View {
    var body: some View {
        if #available(iOS 26.0, *) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.vertical, 3)
                .padding(.horizontal, 2)
        } else {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .padding(.vertical, 3)
                .padding(.horizontal, 2)
        }
    }
}
