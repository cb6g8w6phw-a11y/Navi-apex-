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
    /** The 3D launch film, dropped again after a couple of seconds. */
    @State private var splash = true

    /** The pieces on the row under the search bar: only on the plain map, with nothing picked or being planned. */
    private var plainMap: Bool {
        model.tab == .map && model.nav == nil && model.directions == nil && model.selected == nil && model.results.isEmpty
    }
    private var showFuelChip: Bool {
        plainMap && settings.fuelOn && model.fuelBest != nil && model.fuelInfo == nil && model.roadInfo == nil
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
            // Fuel and weather share one row under the search bar; while searching they stand in a column on the left.
            if showFuelChip || showWeatherBall {
                VStack {
                    if columnMode {
                        HStack {
                            VStack(spacing: 10) {
                                if showWeatherBall { WeatherBall { showWeather = true } }
                                if showFuelChip, let best = model.fuelBest {
                                    FuelMini(station: best) { withAnimation { model.fuelInfo = best } }
                                }
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 78)
                    } else {
                        HStack(alignment: .center) {
                            if showFuelChip, let best = model.fuelBest {
                                FuelChip(station: best, meters: model.userLatLng.map { $0.distance(to: best.location) }) {
                                    withAnimation { model.fuelInfo = best }
                                }
                            }
                            Spacer()
                            if showWeatherBall { WeatherBall { showWeather = true } }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 78)
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
                    RoadEventCard(event: event) { withAnimation { model.roadInfo = nil } }
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
        // The launch film sits over everything until it's played out (or tapped away).
        .overlay { if splash { SplashView(isShown: $splash) } }
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

/** The map page: a big "Where to?" bar, Home and Work one tap away, and the results or place sheet. */
struct BrowseOverlay: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var voice = VoiceSearch()
    @FocusState private var searchFocused: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.sidePanel) private var panel

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
                // Map buttons: layers and the compass on the right, under the top cards.
                VStack {
                    HStack(alignment: .top) {
                        Spacer()
                        VStack(spacing: 12) {
                            MapFab(icon: "square.3.layers.3d", size: 56) { model.showLayers = true }
                                .accessibilityLabel("Map layers")
                            if settings.parkingButton || settings.parking != nil {
                                MapFab(icon: "parkingsign", tint: settings.parking != nil ? Vela.routeBlue : .primary, size: 56) {
                                    if let p = settings.parking { model.select(p) } else { model.saveParking() }
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
                    .padding(.top, panel > 0 ? 10 : idle ? 176 : 86)
                    Spacer()
                    if sheetH < full * 0.6 || panel > 0 {
                        HStack(alignment: .bottom) {
                            if idle { WazeMapChips(model: model) }
                            Spacer()
                            MapFab(icon: "location.fill", tint: Vela.accentText(scheme), size: 64) { model.centerOnUser() }
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
                                    Button { model.saveParking() } label: { Label("I parked here", systemImage: "parkingsign") }
                                }
                        }
                        .padding(.bottom, panel > 0 ? 16
                                 : hasSheet ? max(sheetH - geo.safeAreaInsets.bottom, 0) + 14
                                 : max(dockTop - geo.safeAreaInsets.bottom, 0) + 16)
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

                if idle {
                    VStack {
                        Spacer()
                        KiteDock(model: model, bottomInset: geo.safeAreaInsets.bottom)
                    }
                    .ignoresSafeArea(edges: .bottom)
                    .inSidePanel(panel)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                VStack(spacing: 12) {
                    SearchBar(model: model, voice: voice, focused: $searchFocused)
                    if voice.listening { ListeningCard(voice: voice) }
                    // Home, Work and recents are one tap away under "Where to?", so the map itself stays clear.
                    if searchFocused {
                        SuggestionsPanel(model: model) { searchFocused = false }
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
        .onDisappear { model.searchActive = false }
        .task {
            // Screenshot run only: the search box open, to check nothing sits on its panel.
            guard DemoScript.step == "searchfocus" else { return }
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            searchFocused = true
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
                Image(systemName: "magnifyingglass").font(.system(size: 22, weight: .semibold))
                    .foregroundColor(Vela.muted(scheme))
                    .padding(.leading, 8)
            }
            TextField("Where to?", text: $model.query)
                .font(.system(size: 21, weight: .medium))
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
                    Image(systemName: "xmark").font(.system(size: 18, weight: .bold))
                        .frame(width: 48, height: 48)
                        .background(GlassCircle())
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
                    Image(systemName: "mic.fill").font(.system(size: 20, weight: .semibold))
                        .frame(width: 48, height: 48)
                        .background(GlassCircle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Search by voice")
            }
        }
        .foregroundColor(.primary)
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 64)
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
        // See-through, so the map stays readable behind it.
        .glass(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.trailing, 12)
        .padding(.leading, (settings.weatherOn || settings.fuelOn) ? 70 : 12)
        .frame(maxHeight: 300)
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
        .padding(14)
        .glass(RoundedRectangle(cornerRadius: 18, style: .continuous))
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
            PlaceTile(model: model, icon: "house.fill", color: Vela.routeBlue, title: "Home", place: settings.home) {
                done()
                model.picking = .home
            } go: { done() }
            PlaceTile(model: model, icon: "briefcase.fill", color: Color(hex: 0x8B5CF6), title: "Work", place: settings.work) {
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
        Button {
            if let p = place { go(); model.openDirections(to: p) } else { unset() }
        } label: {
            HStack(spacing: 12) {
                IconBadge(icon: icon, color: place == nil ? Color(hex: 0x94A3B8) : color, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 15, weight: .bold)).lineLimit(1)
                    Text(place.flatMap { p in model.userLatLng.map { $0.distance(to: p.location) } }.map(Fmt.distance) ?? (place == nil ? "Tap to set" : "Tap to go"))
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
            if place != nil, title == "Home" || title == "Work" {
                Button { model.picking = title == "Home" ? .home : .work } label: { Label("Change \(title.lowercased())", systemImage: "pencil") }
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
                 detail: "Apex needs it to show where you are and to guide you.", button: "Turn on") { LocationService.openSettings() }
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
