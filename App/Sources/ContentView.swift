import CoreLocation
import MapKit
import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var model = AppModel()
    @ObservedObject private var launch = LaunchAction.shared
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.horizontalSizeClass) private var hClass
    @Environment(\.verticalSizeClass) private var vClass
    @State private var screen: CGSize = .zero
    /** The side panel's width on a big screen held sideways (the open iPhone Duo), 0 on a phone. */
    private var panel: CGFloat { SidePanel.width(for: screen, h: hClass, v: vClass) }

    /** Where the weather is asked for: your position rounded to about 10 km, so it only asks again after you've moved. */
    private var weatherSpot: String {
        guard let p = model.userLatLng else { return "" }
        return "\((p.lat * 10).rounded() / 10),\((p.lng * 10).rounded() / 10)"
    }

    @State private var showWeather = false
    @State private var showPlayer = false
    @State private var fuelPeek = false
    @ObservedObject private var music = NowPlay.shared

    /** The pieces on the row under the search bar: only on the plain map, with nothing picked or being planned. */
    private var plainMap: Bool {
        model.tab == .map && model.nav == nil && model.directions == nil && model.selected == nil && model.results.isEmpty
    }
    private var showFuelChip: Bool {
        plainMap && settings.fuelOn && model.fuelBest != nil && model.fuelInfo == nil && model.roadInfo == nil
            && (settings.fuelOnReserve || fuelPeek)
    }
    private var showWeatherBall: Bool { plainMap && settings.weatherOn }
    /** Weather and fuel stand in a column on the left while the search is open or a notice or card is showing. */
    private var columnMode: Bool { model.searchActive || model.topBannerShowing }
    /** Room kept on the left of those cards while the column is there. */
    private var stripPad: CGFloat {
        plainMap && (settings.weatherOn || (settings.fuelOn && model.fuelBest != nil)) ? 58 : 0
    }

    private var dark: Bool { settings.colorScheme.map { $0 == .dark } ?? (systemScheme == .dark) }

    var body: some View {
        ZStack {
            VelaMapView(model: model, settings: settings, dark: dark)
                .ignoresSafeArea()
            // The pages are drawn again when the Black theme comes on or goes off (the map is left alone).
            Group {
                if let nav = model.nav {
                    NavigationOverlay(model: model, nav: nav)
                } else if model.directions != nil {
                    DirectionsOverlay(model: model).inSidePanel(panel)
                } else {
                    switch model.tab {
                    case .map: BrowseOverlay(model: model)
                    case .saved: SavedPage(model: model).sidePage(panel).transition(.opacity)
                    case .settings: SettingsPage(model: model).sidePage(panel).transition(.opacity)
                    }
                }
            }
            .id(settings.theme == .black)
            if let ask = model.pump {
                VStack {
                    FuelPumpCard(settings: settings, ask: ask,
                                 no: { withAnimation { model.pumpNo() } },
                                 yes: { withAnimation { model.pumpYes() } },
                                 add: { litres in withAnimation { model.pumpAdd(litres: litres) } })
                        .padding(.horizontal, 12)
                        .padding(.top, model.nav?.isCouch == true ? 118 : 62)
                    Spacer()
                }
                .inSidePanel(panel)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            if let info = model.wazeInfo, model.nav == nil, model.tab == .map {
                VStack {
                    WazeInfoCard(alert: info) { withAnimation { model.wazeInfo = nil } }
                        .padding(.leading, stripPad)
                        .padding(.top, 64)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    Spacer()
                }
                .inSidePanel(panel)
                .task(id: info.id) {
                    // Out of the way by itself after a while, like a toast.
                    guard !DemoScript.active else { return }
                    try? await Task.sleep(nanoseconds: 9_000_000_000)
                    if model.wazeInfo?.id == info.id { withAnimation { model.wazeInfo = nil } }
                }
            }
            // Fuel, the tiny music square and weather share the row under the search bar.
            if plainMap && !model.searchActive {
                VStack {
                    if columnMode {
                        HStack {
                            VStack(spacing: 8) {
                                if showWeatherBall { WeatherBall { showWeather = true } }
                                if showFuelChip, let best = model.fuelBest {
                                    FuelMini(station: best) { withAnimation { model.fuelInfo = best } }
                                }
                            }
                            .padding(.top, 8)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                    } else {
                        HStack(alignment: .top) {
                            Spacer()
                            if showWeatherBall { WeatherBall { showWeather = true } }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                    }
                    Spacer()
                }
                .inSidePanel(panel)
                .animation(.easeOut(duration: 0.2), value: columnMode)
                .task(id: weatherSpot) {
                    if settings.weatherOn, let p = model.userLatLng { await WeatherNow.shared.refresh(lat: p.lat, lng: p.lng) }
                }
            }
            if let st = model.fuelInfo, model.tab == .map, model.nav == nil {
                VStack {
                    FuelCard(station: st, meters: model.userLatLng.map { $0.distance(to: st.location) },
                             go: {
                                 model.fuelInfo = nil
                                 model.select(Place(id: "fuel:\(st.id)", name: st.title, location: st.location, source: "osm"))
                             },
                             close: { withAnimation { model.fuelInfo = nil } })
                        .padding(.leading, stripPad)
                        .padding(.top, 64)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    Spacer()
                }
                .inSidePanel(panel)
            }
            if let event = model.roadInfo, model.tab == .map, model.nav == nil {
                VStack {
                    VStack(spacing: 8) {
                        RoadEventCard(event: event) { withAnimation { model.roadInfo = nil } }
                        if event.id.hasPrefix("user-") {
                            Button("Usuń zgłoszenie") {
                                ClosureBoard.shared.remove(event.id)
                                withAnimation { model.roadInfo = nil }
                            }
                            .font(.system(size: 15, weight: .bold))
                            .padding(.horizontal, 16)
                        }
                    }
                    .padding(.leading, stripPad)
                    .padding(.top, 64)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    Spacer()
                }
                .inSidePanel(panel)
                .task(id: event.id) {
                    try? await Task.sleep(nanoseconds: 12_000_000_000)
                    if model.roadInfo?.id == event.id { withAnimation { model.roadInfo = nil } }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if DemoScript.step == "wazemap" || DemoScript.step == "wazeuk" || DemoScript.step == "wazesizes" {
                // Screenshot run only: what Waze answered, since the build's computers can't be trusted to get through.
                TimelineView(.periodic(from: .now, by: 2)) { _ in
                    Text((Waze.lastStatus.map { "Waze: HTTP \($0.code), \($0.count) reports\($0.viaPage ? " via page" : ""): \($0.summary)" } ?? "Waze: not asked yet")
                         + "\n" + WazeWeb.shared.note + (DemoScript.wazeProbe.isEmpty ? "" : "\n" + DemoScript.wazeProbe))
                        .font(.caption.monospaced()).padding(6).background(Color.red).foregroundColor(.white)
                        .padding(.bottom, 120)
                }
            }
        }
        .background(GeometryReader { g in
            Color.clear
                .onAppear { screen = g.size }
                .onChange(of: g.size) { screen = $0 }
        })
        .environment(\.sidePanel, panel)
        .onAppear { model.sideInset = panel }
        .onChange(of: panel) { model.sideInset = $0 }
        .animation(.easeOut(duration: 0.25), value: model.wazeInfo?.id)
        .animation(.easeOut(duration: 0.25), value: model.roadInfo?.id)
        .animation(.easeOut(duration: 0.2), value: model.tab)
        .kiteType()
        .preferredColorScheme(settings.colorScheme)
        .overlay {
            if showPlayer && model.nav == nil {
                MusicPlayerOverlay(music: music, shown: $showPlayer)
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }
        }
        .sheet(isPresented: $showWeather) {
            WeatherSheet(spot: model.userLatLng, settings: settings)
                .presentationDetents([.medium, .large])
        }
        .task { await DemoScript.run(model) }
        .onReceive(launch.$pending) { kind in
            guard let kind else { return }
            launch.pending = nil
            Task { await model.perform(kind) }
        }
        .onChange(of: model.showSettings) { on in
            // Older ways in (a shortcut, the demo) open the Settings page of the dock.
            guard on else { return }
            model.showSettings = false
            model.tab = .settings
        }
        .onChange(of: model.showSaved) { on in
            guard on else { return }
            model.showSaved = false
            model.tab = .saved
        }
        .sheet(isPresented: $model.showLayers) {
            LayersSheet(settings: settings).kiteType()
        }
        .fullScreenCover(isPresented: $model.showCalibrate) {
            CalibrateSheet(location: model.location).kiteType()
        }
        .fullScreenCover(isPresented: .constant(DemoScript.step?.hasPrefix("svtest") == true)) {
            // Screenshot run only: the viewer on a test pattern, turned right by the step's number.
            GoogleStreetViewScreen(name: "Test pattern", pano: StreetView.Panorama(id: PanoramaViewer.testID, location: LatLng(0, 0)),
                                   heading: Double(DemoScript.step?.dropFirst(6) ?? "") ?? 0)
        }
        .fullScreenCover(isPresented: Binding(get: {
            (!settings.welcomed || settings.needsWazeChoice)
                && (!DemoScript.active || DemoScript.step == "welcome" || DemoScript.step == "wazeintro")
        }, set: { _ in })) {
            // First the Google choice, then (also once for people updating) the Waze one.
            Group {
                if settings.welcomed { WazeIntroView(settings: settings) } else { WelcomeView(settings: settings) }
            }
            .kiteType()
        }
        .sheet(isPresented: $model.addingStop) {
            StopPicker(model: model).kiteType()
        }
        .sheet(item: $model.picking) { kind in
            PlacePicker(model: model, kind: kind).kiteType()
        }
        .onChange(of: settings.welcomed && !settings.needsWazeChoice) { ready in
            if ready { model.location.start() }
        }
    }
}

/** Auto, on foot, or by bike: swaps the map and the routes that follow. */
struct ModeMapSwitch: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        HStack(spacing: 6) {
            ForEach([TravelMode.drive, .walk, .bike]) { m in
                let on = settings.defaultMode == m
                Button { settings.defaultMode = m } label: {
                    HStack(spacing: 4) {
                        Image(systemName: icon(m))
                        Text(title(m))
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .foregroundColor(on ? .white : .primary)
                    .background(Capsule().fill(on ? Color(hex: tint(m)) : Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title(m))
            }
            Spacer(minLength: 0)
        }
    }

    private func icon(_ m: TravelMode) -> String {
        switch m {
        case .drive: return "car.fill"
        case .walk: return "figure.walk"
        case .bike: return "bicycle"
        }
    }

    private func title(_ m: TravelMode) -> String {
        switch m {
        case .drive: return "Auto"
        case .walk: return "Pieszo"
        case .bike: return "Rower"
        }
    }

    private func tint(_ m: TravelMode) -> UInt32 {
        switch m {
        case .drive: return 0x0F766E
        case .walk: return 0x16A34A
        case .bike: return 0x2563EB
        }
    }
}

/** The map page: a big "Where to?" bar, Home and Work one tap away, and the results or place sheet. */
struct BrowseOverlay: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var voice = VoiceSearch()
    @FocusState private var searchFocused: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.sidePanel) private var panel
    @State private var showClosure = false
    @State private var keyboard: CGFloat = 0
    @State private var fuelPeek = false

    private var hasSheet: Bool { model.selected != nil || !model.results.isEmpty }
    /** Room on the left of the notice for the weather and fuel pills, when they stand there. */
    private var noticeInset: CGFloat {
        let pills: Bool = settings.weatherOn || (settings.fuelOn && model.fuelBest != nil)
        let clear: Bool = model.results.isEmpty && model.selected == nil
        return (pills && clear) ? 58 : 0
    }
    /** Only the map and the dock when nothing is open. */
    private var idle: Bool { !hasSheet && !searchFocused && !voice.listening }

    var body: some View {
        GeometryReader { geo in
            let full = geo.size.height + geo.safeAreaInsets.bottom
            let sheetH = hasSheet ? BottomSheet<EmptyView, EmptyView>.height(model.detent, container: full, peek: 230) : 0
            // Room the dock takes at the bottom, from the screen's edge.
            let dockTop = KiteDock.height + KiteDock.bottomGap(geo.safeAreaInsets.bottom)
            ZStack(alignment: .top) {
                if idle {
                    WazeMapChips(model: model)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 12)
                        .padding(.trailing, 96)
                        .padding(.top, 2)
                }
                // Map buttons: layers and the compass on the right, under the top cards.
                VStack {
                    HStack(alignment: .top) {
                        Spacer()
                        VStack(spacing: 12) {
                            MapFab(icon: "square.3.layers.3d", size: 56) { model.showLayers = true }
                                .accessibilityLabel("Map layers")
                            if settings.parkingButton || settings.parking != nil {
                                Menu {
                                    Button { model.saveParking() } label: { Label("Tu stoję", systemImage: "parkingsign") }
                                    if settings.parking != nil {
                                        Button { model.walkToCar() } label: { Label("Prowadź pieszo do auta", systemImage: "figure.walk") }
                                        Button(role: .destructive) { model.clearParking() } label: { Label("Zapomnij miejsce", systemImage: "trash") }
                                    }
                                } label: {
                                    Image(systemName: "parkingsign")
                                        .font(.system(size: 22, weight: .semibold))
                                        .foregroundColor(settings.parking != nil ? Vela.routeBlue : .primary)
                                        .frame(width: 56, height: 56)
                                        .glassButton(Circle())
                                }
                            }
                            if model.mapHeading > 1 && model.mapHeading < 359 {
                                Button { model.map?.setDirection(0, animated: true) } label: {
                                    CompassNeedle()
                                        .rotationEffect(.degrees(-model.mapHeading))
                                        .frame(width: 56, height: 56)
                                        .glass(Circle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Face north")
                                .transition(.scale.combined(with: .opacity))
                            }
                        }
                    }
                    // With a side panel the search box isn't above them: they go to the top right.
                    .padding(.top, panel > 0 ? 10 : idle ? 64 : 16)
                    Spacer()
                    if sheetH < full * 0.6 || panel > 0 {
                        HStack(alignment: .bottom) {
                            Spacer()
                            VStack(alignment: .trailing, spacing: 10) {
                                MapFab(icon: "nosign", tint: Color(hex: 0xDC2626), size: 56) { showClosure = true }
                                    .accessibilityLabel("Zgłoś zamknięcie")
                                MapFab(icon: "location.fill", tint: Vela.accentText(scheme), size: 64) {
                                    model.centerOnUser()
                                }
                                .accessibilityLabel("Centre on me")
                                .contextMenu {
                                    if let u = model.userLatLng {
                                        ShareLink(item: URL(string: "https://maps.google.com/?q=\(u.lat),\(u.lng)")!) {
                                            Label("Share my location", systemImage: "square.and.arrow.up")
                                        }
                                        Button { UIPasteboard.general.string = String(format: "%.6f, %.6f", u.lat, u.lng) } label: {
                                            Label("Copy my coordinates", systemImage: "doc.on.doc")
                                        }
                                    }
                                    Button { showClosure = true } label: { Label("Zgłoś zamknięcie", systemImage: "nosign") }
                                    Button { model.saveParking() } label: { Label("Tu stoję", systemImage: "parkingsign") }
                                }
                            }
                        }
                        .padding(.bottom, panel > 0 ? 16
                                 : hasSheet ? max(sheetH - geo.safeAreaInsets.bottom, 0) + 14
                                 : max(dockTop - geo.safeAreaInsets.bottom, 0) + (idle ? 108 : 16))
                        .padding(.leading, panel)
                    }
                }
                .padding(.horizontal, 16)

                if hasSheet {
                    VStack {
                        Spacer()
                        sheet(full: full)
                    }
                    .ignoresSafeArea(edges: .bottom)
                    .inSidePanel(panel)
                    .transition(.move(edge: .bottom))
                }

                if idle || searchFocused || voice.listening {
                    Color.clear
                        .frame(width: geo.size.width, height: geo.size.height)
                        .overlay(alignment: .bottom) {
                            VStack(spacing: 8) {
                                if searchFocused {
                                    SuggestionsPanel(model: model) { searchFocused = false }
                                        .frame(maxHeight: 280)
                                }
                                if voice.listening { ListeningCard(voice: voice) }
                                if !searchFocused && !voice.listening && !hasSheet {
                                    HStack(spacing: 6) {
                                        ModeMapSwitch(settings: settings)
                                        if settings.fuelOn, let best = model.fuelBest, model.fuelInfo == nil, model.roadInfo == nil {
                                            if settings.fuelOnReserve || fuelPeek {
                                                FuelChip(station: best, meters: model.userLatLng.map { $0.distance(to: best.location) }) {
                                                    withAnimation { model.fuelInfo = best }
                                                }
                                            } else {
                                                Button { withAnimation { fuelPeek = true } } label: {
                                                    Image(systemName: "fuelpump.fill")
                                                        .font(.system(size: 13, weight: .semibold))
                                                        .foregroundColor(Color(hex: 0x16A34A))
                                                        .frame(width: 34, height: 28)
                                                        .glassButton(Capsule())
                                                }
                                                .buttonStyle(.plain)
                                                .accessibilityLabel("Pokaż ceny paliw")
                                            }
                                        }
                                    }
                                    .padding(.horizontal, 12)
                                }
                                SearchBar(model: model, voice: voice, focused: $searchFocused)
                                if idle && keyboard == 0 {
                                    KiteDock(model: model, bottomInset: geo.safeAreaInsets.bottom)
                                }
                            }
                            .padding(.bottom, searchFocused || voice.listening ? 8 : 0)
                        }
                        .ignoresSafeArea(edges: searchFocused ? [] : .bottom)
                        .inSidePanel(panel)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                VStack(spacing: 12) {
                    if hasSheet && !searchFocused {
                        SearchBar(model: model, voice: voice, focused: $searchFocused)
                    }
                    if let n = model.notice, !searchFocused {
                        NoticeBanner(text: n) { model.notice = nil }
                            .padding(.leading, noticeInset)
                    }
                    if !searchFocused { StatusCards(location: model.location) }
                }
                .padding(.top, 6)
                .inSidePanel(panel)
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: hasSheet)
            .animation(.easeOut(duration: 0.2), value: idle)
        }
        .onChange(of: searchFocused) { model.searchActive = $0 }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .zero
            let h = max(0, UIScreen.main.bounds.height - end.origin.y)
            withAnimation(.easeOut(duration: 0.25)) { keyboard = h }
        }
        .onDisappear { model.searchActive = false }
        .task {
            // Screenshot run only: the search box open, to check nothing sits on its panel.
            guard DemoScript.step == "searchfocus" else { return }
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            searchFocused = true
        }
        .sheet(isPresented: $showClosure) {
            ClosureReportSheet(at: model.userLatLng) { showClosure = false }.kiteType()
        }
    }

    @ViewBuilder
    private func sheet(full: CGFloat) -> some View {
        if let place = model.selected {
            BottomSheet(detent: $model.detent, containerHeight: full, peekHeight: 230) {
                PlaceHeader(model: model, place: place)
            } content: {
                PlaceBody(model: model, place: place)
            }
            .id(place.id)
        } else {
            BottomSheet(detent: $model.detent, containerHeight: full, peekHeight: 230) {
                ResultsHeader(model: model)
            } content: {
                ResultsList(model: model)
            }
        }
    }
}

/** "Where to?": the one way into search, big enough to hit from a phone holder. */
struct SearchBar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var voice: VoiceSearch
    var focused: FocusState<Bool>.Binding
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 14) {
            if focused.wrappedValue || !model.results.isEmpty || model.selected != nil {
                Button {
                    if focused.wrappedValue { focused.wrappedValue = false } else { model.clearSearch() }
                } label: {
                    Image(systemName: "arrow.left").font(.system(size: 22, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
            } else {
                Image(systemName: "magnifyingglass").font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Vela.muted(scheme))
                    .padding(.leading, 8)
            }
            TextField("Where to?", text: $model.query)
                .font(.system(size: 16, weight: .medium))
                .focused(focused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit { model.search() }
                .onChange(of: model.query) { q in
                    if focused.wrappedValue { model.typed(q) }
                }
            if model.searching {
                ProgressView().frame(width: 48, height: 48)
            } else if !model.query.isEmpty || !model.results.isEmpty || model.selected != nil {
                Button {
                    model.clearSearch()
                    focused.wrappedValue = false
                } label: {
                    Image(systemName: "xmark").font(.system(size: 19, weight: .bold))
                        .frame(width: 48, height: 48)
                        .background(Circle().fill(Vela.chip(scheme)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            } else {
                Button {
                    focused.wrappedValue = false
                    voice.start(onDone: { text in
                        model.query = text
                        model.search(text)
                    }, onError: { model.notice = $0 })
                } label: {
                    Image(systemName: "mic.fill").font(.system(size: 16, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Vela.chip(scheme)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Search by voice")
            }
        }
        .foregroundColor(.primary)
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 44)
        .glass(Capsule())
        .padding(.horizontal, 16)
    }
}

struct SuggestionsPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings = AppSettings.shared
    let done: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var copiedLink = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !model.query.isEmpty && !(model.suggestions.places.isEmpty && model.suggestions.queries.isEmpty) {
                    ForEach(model.suggestions.places.prefix(6)) { p in
                        Button { done(); model.openSuggestion(p) } label: {
                            HStack(spacing: 16) {
                                Image(systemName: "mappin.circle.fill").font(.system(size: 20)).frame(width: 22).foregroundColor(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.name).foregroundColor(.primary).lineLimit(1)
                                    if let a = p.address { Text(a).font(.caption).foregroundColor(.secondary).lineLimit(1) }
                                }
                                Spacer()
                                if let d = p.distanceMeters { Text(Fmt.distance(d)).font(.caption).foregroundColor(.secondary) }
                            }
                            .padding(.horizontal, 18)
                            .frame(minHeight: 40)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(model.suggestions.queries.prefix(5), id: \.self) { q in
                        row(icon: "magnifyingglass", text: q) { done(); model.search(q) }
                    }
                } else {
                    if copiedLink {
                        // The system Paste button reads the clipboard without iOS asking first.
                        HStack(spacing: 16) {
                            Image(systemName: "link").frame(width: 22).foregroundColor(.secondary)
                            Text("Open a copied map link").foregroundColor(.primary)
                            Spacer()
                            PasteButton(payloadType: String.self) { strings in
                                guard let text = strings.first else { return }
                                Task { @MainActor in
                                    done()
                                    model.openLink(text)
                                }
                            }
                            .labelStyle(.titleOnly)
                            .buttonBorderShape(.capsule)
                            .tint(Vela.routeBlue)
                        }
                        .padding(.horizontal, 18)
                        .frame(height: 50)
                    }
                    Shortcuts(model: model, done: done)
                    if !settings.recentPlaces.isEmpty || !settings.recents.isEmpty {
                        HStack {
                            Text("Recent").font(.subheadline.weight(.semibold)).foregroundColor(.secondary)
                            Spacer()
                            Button("Clear") { settings.recents = []; settings.recentPlaces = [] }
                                .font(.subheadline).foregroundColor(Vela.routeBlue)
                        }
                        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 4)
                        ForEach(settings.recentPlaces.prefix(5)) { p in
                            Button { done(); model.openSuggestion(p) } label: {
                                HStack(spacing: 16) {
                                    Image(systemName: "clock").frame(width: 22).foregroundColor(.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(p.name).foregroundColor(.primary).lineLimit(1)
                                        if let a = p.address ?? p.category { Text(a).font(.caption).foregroundColor(.secondary).lineLimit(1) }
                                    }
                                    Spacer()
                                    if let d = model.userLatLng?.distance(to: p.location) {
                                        Text(Fmt.distance(d)).font(.caption).foregroundColor(.secondary)
                                    }
                                }
                                .padding(.horizontal, 18)
                                .frame(minHeight: 38)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) { settings.recentPlaces.removeAll { $0.id == p.id } } label: {
                                    Label("Remove from recents", systemImage: "trash")
                                }
                            }
                        }
                        ForEach(settings.recents.filter { q in !settings.recentPlaces.prefix(5).contains { $0.name == q } }.prefix(6), id: \.self) { q in
                            row(icon: "magnifyingglass", text: q) { done(); model.search(q) }
                                .contextMenu {
                                    Button(role: .destructive) { settings.recents.removeAll { $0 == q } } label: {
                                        Label("Remove from recents", systemImage: "trash")
                                    }
                                }
                        }
                    }
                    // Recents first, like every maps app: most searches are for somewhere you've been.
                    Text("Nearby").font(.subheadline.weight(.semibold)).foregroundColor(.secondary)
                        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 4)
                    ForEach(Category.all) { c in
                        row(icon: c.icon, text: c.label) { done(); model.search(c.query, title: c.label) }
                    }
                }
            }
            .padding(.vertical, 6)
            .font(.system(size: 15))
        }
        // Smaller and see-through: the map stays readable behind it.
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.ultraThinMaterial).opacity(0.72)
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: 0.75))
        )
        .padding(.horizontal, 12)
        .frame(maxHeight: 260)
        .task {
            // Only checks whether the clipboard looks like a link; it doesn't read it.
            guard UIPasteboard.general.hasStrings || UIPasteboard.general.hasURLs else { return }
            UIPasteboard.general.detectPatterns(for: [.probableWebURL]) { result in
                let found = (try? result.get())?.contains(.probableWebURL) ?? false
                Task { @MainActor in copiedLink = found }
            }
        }
    }

    private func row(icon: String, text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon).frame(width: 22).foregroundColor(.secondary)
                Text(text).foregroundColor(.primary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct NoticeBanner: View {
    let text: String
    let dismiss: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle").foregroundColor(.secondary)
            Text(text).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) { Image(systemName: "xmark").font(.footnote) }.buttonStyle(.plain)
        }
        .padding(12)
        .glass(RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 12)
    }
}

/** Home, Work and the parked car at the top of the search panel. */
struct Shortcuts: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings = AppSettings.shared
    let done: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            PlaceTile(model: model, icon: "house.fill", color: Vela.routeBlue, title: "Dom", place: settings.home) {
                done()
                model.picking = .home
            } go: { done() }
            PlaceTile(model: model, icon: "briefcase.fill", color: Color(hex: 0x8B5CF6), title: "Praca", place: settings.work) {
                done()
                model.picking = .work
            } go: { done() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

struct PlaceTile: View {
    @ObservedObject var model: AppModel
    let icon: String
    let color: Color
    let title: String
    let place: Place?
    let unset: () -> Void
    var go: () -> Void = {}
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let subtitle: String = {
            guard let p = place else { return "Stuknij, aby ustawić" }
            let usual = TripExtras.usual(id: p.id)
            let dist = model.userLatLng.map { Fmt.distance($0.distance(to: p.location)) }
            return [dist, usual].compactMap { $0 }.joined(separator: " · ")
        }()
        Button {
            if let p = place { go(); model.openDirections(to: p) } else { unset() }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(place == nil ? Color.gray : color))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 15, weight: .bold)).lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium)).foregroundColor(Vela.muted(scheme)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 74)
            .glass(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 22))
        }
        .buttonStyle(.plain)
        .foregroundColor(.primary)
        .contextMenu {
            if place != nil, title == "Dom" || title == "Praca" {
                Button { model.picking = title == "Dom" ? .home : .work } label: { Label("Zmień", systemImage: "pencil") }
            }
        }
        .accessibilityLabel(place == nil ? "\(title), not set" : "Go to \(title)")
    }
}

/** Red-and-gray needle pointing north, like Vela's compass. */
struct CompassNeedle: View {
    var body: some View {
        ZStack {
            Triangle().fill(Color(hex: 0xEA4335)).frame(width: 10, height: 14).offset(y: -7)
            Triangle().fill(Color.secondary).frame(width: 10, height: 14).rotationEffect(.degrees(180)).offset(y: 7)
        }
    }
}

struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/** Why the map can't do its job right now: location turned off, or no internet. */
struct StatusCards: View {
    @ObservedObject var location: LocationService
    @ObservedObject private var net = Connectivity.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if location.denied || DemoScript.step == "locationoff" {
            card(icon: "location.slash.fill", color: Vela.closed, title: "Location is off",
                 detail: "Navapp needs it to show where you are and to guide you.", button: "Turn on") { LocationService.openSettings() }
        } else if !net.online {
            card(icon: "wifi.slash", color: Color(hex: 0xF59E0B), title: "No internet connection",
                 detail: "Search, routes and live traffic need one. The map you've already seen still works.", button: nil) {}
        }
    }

    private func card(icon: String, color: Color, title: String, detail: String, button: String?, action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 20, weight: .bold)).foregroundColor(.white)
                .frame(width: 44, height: 44).background(Circle().fill(color))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 18, weight: .bold))
                Text(detail).font(.system(size: 15)).foregroundColor(Vela.muted(scheme)).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let button {
                Button(action: action) {
                    Text(button).font(.system(size: 17, weight: .bold)).foregroundColor(Vela.onAccent(scheme))
                        .padding(.horizontal, 16).frame(height: 44).background(Capsule().fill(Vela.accent(scheme)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .glass(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
    }
}
