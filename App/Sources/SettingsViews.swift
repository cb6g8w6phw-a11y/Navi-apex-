import SwiftUI

struct LayersSheet: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var cities = CityAtlas.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Warstwy").font(.system(size: 26, weight: .heavy))
                Spacer()
                CircleIconButton(icon: "xmark") { dismiss() }
            }
            Text("Typ mapy").font(.subheadline.weight(.semibold)).foregroundColor(.secondary)
            HStack(spacing: 14) {
                tile("Zwykła", icon: "map", on: !settings.satellite) { settings.satellite = false }
                tile("Satelita", icon: "globe.americas.fill", on: settings.satellite) { settings.satellite = true }
            }
            Text("Szczegóły").font(.subheadline.weight(.semibold)).foregroundColor(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), alignment: .leading, spacing: 14) {
                tile("Ruch", icon: "car.2.fill", on: settings.traffic) { settings.traffic.toggle() }
                tile("Komunikacja", icon: "tram.fill", on: settings.transitLines) { settings.transitLines.toggle() }
                tile("Teren", icon: "mountain.2.fill", on: settings.terrain) { settings.terrain.toggle() }
                tile("Fotoradary", badge: .speed, on: settings.speedCameras) { settings.speedCameras.toggle() }
                tile("Kamery tablic", badge: .plate, on: settings.plateCameras) { settings.plateCameras.toggle() }
                tile("Monitoring", badge: .watch, on: settings.watchCameras) { settings.watchCameras.toggle() }
                tile("Paliwo", icon: "fuelpump.fill", on: settings.fuelOn) { settings.fuelOn.toggle() }
                tile("Radar", icon: "cloud.rain.fill", on: settings.radarOn) { settings.radarOn.toggle() }
                tile("Obrysy miast", icon: "square.dashed", on: cities.enabled) { cities.enabled.toggle() }
                tile("Alerty", waze: Waze.shares.contains(.police) ? .police : .closure, on: settings.wazeOn && settings.wazeOnMap) {
                    if settings.waze && settings.wazeOnMap { settings.wazeOnMap = false } else { settings.waze = true; settings.wazeOnMap = true }
                }
                if Waze.shares.contains(.police) {
                    tile("Mapa policji", icon: "flame.fill", on: settings.wazeOn && settings.wazeHeatmap) {
                        if settings.waze && settings.wazeHeatmap { settings.wazeHeatmap = false } else { settings.waze = true; settings.wazeHeatmap = true }
                    }
                }
            }
            Spacer()
        }
        .padding(20)
        .background(Vela.sheet(scheme).ignoresSafeArea())
        .presentationDetents([.height(640)])
    }

    private func tile(_ title: String, icon: String = "", badge: RoadCamera.Kind? = nil, waze: WazeAlert.Kind? = nil,
                      on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Group {
                    if let badge { CameraBadge(kind: badge, size: 34) }
                    else if let waze { WazeBadge(kind: waze, size: 34) }
                    else { Image(systemName: icon).font(.system(size: 26)) }
                }
                    .frame(width: 74, height: 64)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Vela.chip(scheme)))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(on ? Vela.accent(scheme) : .clear, lineWidth: 3))
                Text(title).font(.caption.weight(on ? .semibold : .regular))
                    .foregroundColor(on ? Vela.accent(scheme) : .primary)
            }
        }
        .buttonStyle(.plain)
    }
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var mind = MindSettings.shared
    /** A page of the dock rather than a sheet: no Done button. */
    var inTab = false
    /** Opens the search for choosing home or work (the dock's page has it). */
    var pick: ((PickKind) -> Void)? = nil
    /** Figure-eight compass sheet. Only from here, never from the map's location button. */
    var calibrate: (() -> Void)? = nil
    /** Opens a real route on the map. The string comes back only when the route could not be fetched. */
    var simulate: ((CouchScene, @escaping (String?) -> Void) -> Void)? = nil
    var rideAgain: ((TripRecord) -> Void)? = nil
    let onChange: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var musicName = ""
    @State private var musicLink = ""
    @State private var musicNote = ""
    @State private var versionTaps = 0
    @State private var loadingSim: CouchScene?
    @State private var simError: String?
    var body: some View {
        if DemoScript.step == "wazesettings" {
            // Straight into the Waze screen, for the build's screenshot of it.
            NavigationView { WazeSettingsView(settings: settings) }.navigationViewStyle(.stack)
        } else {
            main
        }
    }

    private var main: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 14) {
                    carHero
                    settingsGroup {
                        menuRow("Głos i jazda", detail: "Polski lektor i tryb podróży",
                                icon: "speaker.wave.2.fill", color: 0x0F766E, grouped: true) { drivingPage }
                        groupLine
                        menuRow("Trasy", detail: "Objazd, tunel, granica",
                                icon: "signpost.right.fill", color: 0x0891B2, grouped: true) { routesPage }
                        groupLine
                        menuRow("Kamery i prędkość", detail: "Fotoradary, alarm prędkości",
                                icon: "camera.fill", color: 0xDC2626, grouped: true) { camerasPage }
                        groupLine
                        menuRow("Kamery na żywo", detail: "Zdjęcia z autostrad w Niemczech",
                                icon: "video.fill", color: 0x2563EB, grouped: true) { LiveCamerasPage() }
                    }
                    settingsGroup {
                        menuRow("Ostrzeżenia drogowe", detail: "Policja, wypadki, zamknięcia",
                                icon: "exclamationmark.triangle.fill", color: 0x7C3AED, grouped: true,
                                switchOn: $settings.waze) { WazeSettingsView(settings: settings) }
                        groupLine
                        menuRow("Ceny paliw", detail: "Najtańsze w pobliżu i na trasie",
                                icon: "fuelpump.fill", color: 0x2563EB, grouped: true,
                                switchOn: $settings.fuelOn) { FuelSettingsView(settings: settings) }
                    }
                    settingsGroup {
                        menuRow("Mapa i wyświetlanie", detail: "Motyw, jednostki, parking",
                                icon: "circle.lefthalf.filled", color: 0x334155, grouped: true) { mapPage }
                        groupLine
                        menuRow("Muzyka", detail: "Apple Music, Spotify i własne linki",
                                value: MusicCatalog.active(settings).name, icon: "music.note", color: 0xFA2D48, grouped: true) { musicPage }
                        groupLine
                        menuRow("Moje miejsca", detail: "Dom i praca",
                                icon: "house.fill", color: 0x16A34A, grouped: true) { placesPage }
                        groupLine
                        menuRow("Historia jazd", detail: "Kilometry, czas i trasy do powtórzenia",
                                icon: "clock.arrow.circlepath", color: 0x0F766E, grouped: true) {
                            TripHistoryPage { rideAgain?($0) }
                        }
                    }
                    settingsGroup {
                        menuRow("Prywatność", detail: "Navapp bez Google",
                                icon: "lock.fill", color: 0x475569, grouped: true,
                                switchOn: $settings.noGoogle) { privacyPage }
                        groupLine
                        menuRow("O aplikacji", detail: "Wersja " + version,
                                icon: "info.circle.fill", color: 0x64748B, grouped: true) { aboutPage }
                        if mind.simUnlocked {
                            groupLine
                            menuRow("Tryb symulacji", detail: "Tunel, granica i Umwelt z kanapy",
                                    icon: "play.rectangle.fill", color: 0x0F766E, grouped: true) { simPage }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 150)
            }
            .background(PageBackdrop())
            .navigationTitle("Ustawienia")
            .navigationBarTitleDisplayMode(inTab ? .large : .inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if !inTab {
                        Button("Gotowe") {
                            onChange()
                            dismiss()
                        }
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty || build == "1" ? short : "\(short) · \(build)"
    }

    private func menuRow<Page: View>(_ title: String, detail: String, value: String? = nil, icon: String, color: UInt32,
                                     grouped: Bool = false, switchOn: Binding<Bool>? = nil,
                                     @ViewBuilder page: @escaping () -> Page) -> some View {
        HStack(alignment: .center, spacing: 12) {
            NavigationLink { page() } label: {
                HStack(alignment: .center, spacing: 12) {
                    IconBadge(icon: icon, color: Color(hex: color), size: 36, radius: 12)
                        .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        Text(detail)
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let value, switchOn == nil {
                        Text(value)
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    if switchOn == nil {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                }
            }
            .buttonStyle(.plain)
            if let switchOn {
                Toggle("", isOn: switchOn).labelsHidden()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, grouped ? 10 : 14)
        .modifier(OptionalGlass(on: !grouped))
    }

    private var groupLine: some View {
        Divider().padding(.leading, 60)
    }

    private func settingsGroup<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .glassCard(22)
    }

    /// The car, from the dates and kilometres already saved. Nothing here is invented.
    private var carHero: some View {
        let status = CarStatus(settings: settings)
        let oil = status.parts.first { $0.part.name.localizedCaseInsensitiveContains("olej") } ?? status.parts.first
        return NavigationLink { CarPage(settings: settings) } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    IconBadge(icon: "car.fill", color: Color(hex: 0x16A34A), size: 44, radius: 14)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Moje auto").font(.system(size: 18, weight: .bold))
                        Text(status.headline).font(.subheadline).foregroundColor(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    if let pct = status.healthPercent {
                        ZStack {
                            Circle().stroke(Color.white.opacity(0.15), lineWidth: 5)
                            Circle().trim(from: 0, to: pct)
                                .stroke(Color(hex: 0x2DD4BF), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Text("\(Int((pct * 100).rounded()))%")
                                .font(.system(size: 12, weight: .bold)).monospacedDigit()
                        }
                        .frame(width: 52, height: 52)
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if let d = status.inspection.days {
                            carChip(icon: "wrench.and.screwdriver", text: d < 0 ? "Przegląd \(-d) dni po" : "Przegląd za \(d) dni")
                        }
                        if let d = status.insurance.days {
                            carChip(icon: "checkmark.shield", text: d < 0 ? "OC \(-d) dni po" : (d > 0 ? "OC aktywne" : "OC dziś"))
                        }
                        if let left = oil?.kmLeft {
                            carChip(icon: "drop", text: left < 0 ? "Olej \(Fmt.thousand(-left)) km po" : "Olej za \(Fmt.thousand(left)) km")
                        }
                        if status.inspection.days == nil && status.insurance.days == nil && oil?.kmLeft == nil {
                            carChip(icon: "plus", text: "Dodaj przegląd, OC i olej")
                        }
                    }
                }
            }
            .padding(14)
            .glassCard(22)
        }
        .buttonStyle(.plain)
    }

    private func carChip(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 12, weight: .bold))
            Text(text).font(.system(size: 13, weight: .semibold)).lineLimit(1)
        }
        .padding(.horizontal, 10).frame(height: 32)
        .background(Capsule().fill(Color.white.opacity(0.12)))
    }

    private var drivingPage: some View {
        Form {
            Section {
                Toggle(isOn: $settings.voice) { SettingLabel("Prowadzenie głosem", detail: "Lektor czyta manewry w wybranym języku.", icon: "speaker.wave.2.fill", color: 0x0F766E) }
                Picker(selection: $settings.language) {
                    Text("Polski").tag("pl")
                    Text("Deutsch").tag("de")
                    Text("English").tag("en")
                } label: { SettingLabel("Język jazdy", detail: "Głos i komunikaty na trasie.", icon: "character.bubble.fill", color: 0x0F766E) }
                Picker(selection: $settings.defaultMode) {
                    ForEach(TravelMode.allCases) { Text($0.label).tag($0) }
                } label: { SettingLabel("Domyślny tryb podróży", icon: "car.fill", color: 0x2563EB) }
            } footer: {
                Text(L.t("Lektor czyta manewry w wybranym języku. Niemiecki i angielski głos pobierasz w Ustawieniach iPhone’a: Ułatwienia dostępu → Zawartość mówiona → Głosy.",
                        "Die Ansagen folgen der gewählten Sprache. Eine deutsche Stimme lädst du unter Bedienungshilfen → Gesprochene Inhalte → Stimmen.",
                        "Spoken turns follow the language you pick. Download a voice in Settings → Accessibility → Spoken Content → Voices."))
            }
        }
        .kiteList()
        .navigationTitle("Głos i jazda")
    }

    private var routesPage: some View {
        Form {
            Section {
                Toggle(isOn: $settings.avoidTolls) { SettingLabel("Unikaj dróg płatnych", detail: "Omija odcinki z opłatą i bramki.", icon: "sterlingsign.circle.fill", color: 0xF59E0B) }
                Toggle(isOn: $settings.avoidHighways) {
                    SettingLabel("Unikaj autostrad", detail: "Prowadzi bez autostrad, bocznymi drogami.", icon: "road.lanes", color: 0x1D4ED8)
                }
                Toggle(isOn: $mind.avoidHardJunctions) { SettingLabel("Unikaj trudnych skrzyżowań", icon: "arrow.triangle.turn.up.right.circle.fill", color: 0x0F766E) }
                Toggle(isOn: $mind.trueTime) { SettingLabel("Prawdziwy czas objazdu", detail: "Nie zjeżdża w boczną, jeśli ta stoi tak samo jak główna. Nie mierzy każdej uliczki.", icon: "clock.fill", color: 0x2563EB) }
                Toggle(isOn: $mind.deadReckoning) { SettingLabel("Czujniki w tunelu", detail: "Gdy GPS zniknie, pozycja jedzie z czujników po osi drogi.", icon: "location.slash.fill", color: 0x0F766E) }
                Toggle(isOn: $mind.greenWave) { SettingLabel("Światła na trasie", detail: "Pokazuje najbliższe światła z mapy. Miasta nie podają, kiedy jest zielone.", icon: "lightbulb.fill", color: 0x16A34A) }
                Toggle(isOn: $mind.haptics) { SettingLabel("Wibracja przed skrętem", icon: "iphone.radiowaves.left.and.right", color: 0x7C3AED) }
                Toggle(isOn: $mind.borderAssist) { SettingLabel("Kolejka na granicy", detail: "Typowy czas przejść DE–PL, nie kolejka na żywo.", icon: "flag.fill", color: 0xDC2626) }
                Toggle(isOn: $mind.umwelt) { SettingLabel("Strefa Umwelt", detail: "Rysuje prawdziwy obrys zielonej strefy.", icon: "leaf.fill", color: 0x16A34A) }
            }
            Section {
                Stepper(value: $mind.gpsTrust, in: 25...150, step: 5) {
                    SettingLabel("GPS słaby od \(mind.gpsTrust) m", icon: "location.fill", color: 0x0891B2)
                }
                Stepper(value: $mind.headingTrim, in: -30...30, step: 1) {
                    SettingLabel("Korekta kierunku: \(mind.headingTrim)°", icon: "location.north.line.fill", color: 0x0F766E)
                }
                Button { calibrate?() } label: {
                    SettingLabel("Skalibruj kompas", detail: "Ósemka w powietrzu, gdy auto stoi.", icon: "compass.drawing", color: 0x0891B2)
                }
                .foregroundColor(.primary)
                Button { mind.resetAsked = true } label: {
                    SettingLabel("Wyzeruj czujniki", icon: "arrow.counterclockwise", color: 0xDC2626)
                }
                .foregroundColor(.primary)
            } header: {
                Text("Kalibracja")
            } footer: {
                Text("Czujniki wchodzą w tunelu albo gdy GPS myli się bardziej niż wybrany próg. Korekta kierunku obraca strzałkę. Kompas kalibrujesz tylko tutaj, na postoju: ósemka w powietrzu, potem wyzeruj czujniki. Przycisk lokalizacji na mapie tylko centruje.")
            }
        }
        .kiteList()
        .navigationTitle("Trasy")
    }

    private var camerasPage: some View {
        Form {
            Section("Ostrzeżenia") {
                Toggle(isOn: $settings.cameraWarnings) { SettingLabel("Powiadom, gdy zbliża się fotoradar", icon: "speaker.wave.3.fill", color: 0xDC2626) }
                Toggle(isOn: $settings.speedingAlert) { SettingLabel("Powiadom, gdy przekraczam prędkość", icon: "gauge.with.dots.needle.67percent", color: 0xEA580C) }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Alarm prędkości").font(.body)
                        Spacer()
                        Text("+\(settings.speedSlack) km/h").font(.body.weight(.bold)).monospacedDigit()
                    }
                    Slider(value: Binding(
                        get: { Double(settings.speedSlack) },
                        set: { settings.speedSlack = Int($0.rounded()) }
                    ), in: 0...20, step: 1)
                    Text("Mówi dopiero tyle ponad limit, i dopiero gdy trwa to kilka sekund. Nie piszczy od jednego skoku GPS.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            Section {
                Toggle(isOn: $settings.speedCameras) { SettingLabel("Fotoradary", icon: "camera.fill", color: 0xDC2626) }
                Toggle(isOn: $settings.plateCameras) {
                    SettingLabel("Kamery tablic rejestracyjnych", icon: "number", color: 0x6B7280)
                }
                Toggle(isOn: $settings.watchCameras) {
                    SettingLabel("Kamery monitoringu", detail: "Publiczne kamery na mapie. Bez głosu.", icon: "video.fill", color: 0x475569)
                }
            } header: {
                Text("Pokazuj na mapie i trasie")
            } footer: {
                Text("Fotoradary i kamery tablic z OpenStreetMap, na mapie i na trasie. Monitoring to zwykłe kamery miejskie, tylko ikona na mapie. W części krajów, jak Francja i Niemcy, ostrzeganie o fotoradarach może być zabronione. Sprawdź, zanim włączysz tam głos.")
            }
        }
        .kiteList()
        .navigationTitle("Kamery i prędkość")
    }

    private var mapPage: some View {
        Form {
            Section {
                Picker("Motyw mapy", selection: $settings.theme) {
                    Text("Jasny").tag(ThemeMode.light)
                    Text("Auto").tag(ThemeMode.system)
                    Text("Ciemny").tag(ThemeMode.dark)
                    Text("Czarny").tag(ThemeMode.black)
                }
                .pickerStyle(.segmented)
                Picker(selection: $settings.glassStyle) {
                    ForEach(GlassStyle.allCases) { Text($0.label).tag($0) }
                } label: { SettingLabel("Szkło", icon: "rectangle.on.rectangle", color: 0x6366F1) }
                Picker(selection: $settings.units) {
                    ForEach(UnitsMode.allCases) { Text($0.label).tag($0) }
                } label: { SettingLabel("Jednostki odległości", icon: "ruler.fill", color: 0x0891B2) }
                Toggle(isOn: $settings.parkingButton) { SettingLabel("Przycisk parkowania na mapie", icon: "parkingsign", color: 0x2563EB) }
                Toggle(isOn: $settings.weatherOn) { SettingLabel("Pogoda na mapie", icon: "cloud.sun.fill", color: 0x0EA5E9) }
            } footer: {
                Text("Czarny motyw używa czystej czerni i zawsze matowego szkła. Przejście do lub z motywu Czarny wraca do pierwszej strony ustawień. Odznaka pogody pyta Open-Meteo, z pozycją zaokrągloną do ok. 10 km.")
            }
        }
        .kiteList()
        .navigationTitle("Mapa i wyświetlanie")
    }

    private var musicPage: some View {
        Form {
            Section {
                ForEach(MusicCatalog.builtins) { app in
                    Toggle(isOn: Binding(
                        get: { settings.musicEnabled.contains(app.id) || (settings.musicEnabled.isEmpty && app.id == "apple") },
                        set: { settings.setMusic(app.id, on: $0) }
                    )) {
                        SettingLabel(app.name,
                                     detail: app.isApple ? "Pauza, poprzedni i następny w trakcie jazdy." : "Otwiera aplikację. iPhone nie oddaje jej pauzy.",
                                     icon: app.symbol, color: app.color)
                    }
                    if app.id != "apple" && settings.musicEnabled.contains(app.id) {
                        Button("Otwórz \(app.name)") { MusicCatalog.open(app) }
                            .foregroundColor(.primary)
                    }
                }
            } header: {
                Text("Usługi")
            } footer: {
                Text("Włączone usługi widać w odtwarzaczu pod ceną paliwa. Apple Music da się prowadzić stąd. Reszta otwiera swoją aplikację.")
            }
            Section {
                TextField("Nazwa, np. Mornye", text: $musicName)
                TextField("Link albo schemat, np. livecontainer://", text: $musicLink)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button("Dodaj z linku") {
                    if settings.addMusicLink(name: musicName, link: musicLink) {
                        musicName = ""
                        musicLink = ""
                        musicNote = ""
                    } else {
                        musicNote = "Wpisz nazwę i link. Adres ze strony, schemat aplikacji albo link z Live Container."
                    }
                }
                if !musicNote.isEmpty {
                    Text(musicNote).font(.footnote).foregroundColor(.secondary)
                }
                ForEach(settings.musicExtras) { extra in
                    Button { MusicCatalog.open(MusicTarget(id: extra.id, name: extra.name, symbol: "link", color: 0x0891B2, link: extra.link, store: nil)) } label: {
                        SettingLabel(extra.name, detail: extra.link, icon: "link", color: 0x0891B2)
                    }
                    .foregroundColor(.primary)
                }
                .onDelete { settings.removeMusicLinks(at: $0) }
            } header: {
                Text("Inne z linku")
            } footer: {
                Text("Tak jak dokładanie usługi w Mornye: wklejasz link i Navapp go otwiera. Przesuń wiersz w lewo, żeby usunąć. Navapp nie pobiera utworów.")
            }
        }
        .kiteList()
        .navigationTitle("Muzyka")
    }

    private var placesPage: some View {
        Form {
            Section {
                if let pick {
                    Button { pick(.home) } label: {
                        LabeledContent { Text(settings.home?.name ?? "Ustaw") } label: { SettingLabel("Dom", icon: "house.fill", color: 0x16A34A) }
                    }
                    .foregroundColor(.primary)
                    Button { pick(.work) } label: {
                        LabeledContent { Text(settings.work?.name ?? "Ustaw") } label: { SettingLabel("Praca", icon: "briefcase.fill", color: 0x9333EA) }
                    }
                    .foregroundColor(.primary)
                } else {
                    if let h = settings.home {
                        LabeledContent { Text(h.name) } label: { SettingLabel("Dom", icon: "house.fill", color: 0x16A34A) }
                        Button("Usuń dom", role: .destructive) { settings.home = nil }
                    }
                    if let w = settings.work {
                        LabeledContent { Text(w.name) } label: { SettingLabel("Praca", icon: "briefcase.fill", color: 0x9333EA) }
                        Button("Usuń pracę", role: .destructive) { settings.work = nil }
                    }
                    if settings.home == nil && settings.work == nil {
                        Text("Dom i pracę ustawisz na stronie Zapisane.").foregroundColor(.secondary)
                    }
                }
            }
        }
        .kiteList()
        .navigationTitle("Moje miejsca")
    }

    private var privacyPage: some View {
        Form {
            Section {
                Toggle(isOn: $settings.noGoogle) { SettingLabel("Używaj Navapp bez Google", icon: "lock.fill", color: 0x475569) }
            } footer: {
                Text("Wyłączone (zwykle): wyszukiwanie, szczegóły miejsc, trasy i ruch pochodzą z Google, pytane anonimowo, bez konta. Włączone: wszystko pochodzi z otwartych usług i nic nie trafia do Google, ale wyszukiwanie i trasy są mniej kompletne.")
            }
        }
        .kiteList()
        .navigationTitle("Prywatność")
    }

    private var aboutPage: some View {
        Form {
            Section {
                Button {
                    versionTaps += 1
                    if versionTaps >= 5 { mind.simUnlocked = true }
                } label: {
                    HStack {
                        Text("Wersja").foregroundColor(.primary)
                        Spacer()
                        Text(version).foregroundColor(.secondary)
                    }
                }
                if mind.simUnlocked {
                    Text("Tryb symulacji jest na dole Ustawień.").font(.caption).foregroundColor(.secondary)
                }
                Link("Navapp na GitHubie", destination: URL(string: "https://github.com/matteofx1/kite-maps")!)
                Link("Na bazie Vela Maps dla Androida", destination: URL(string: "https://github.com/PimpinPumpkin/Vela")!)
                Link("Raporty Waze na żywo jak w SABRE Plus (MIT)", destination: URL(string: "https://github.com/nicglazkov/highway-radar-sabre-plus")!)
                Text("Wolne oprogramowanie na licencji GPL-3.0. Mapy © Apple. Trasy © FOSSGIS OSRM, współtwórcy OpenStreetMap. Cieniowanie © Esri. Ceny paliw: Tankerkönig / MTS-K (CC BY 4.0). Roboty, zamknięcia i zdjęcia z autostrad: Autobahn GmbH. Pogoda: Open-Meteo.com (CC BY 4.0). Radar opadów: Deutscher Wetterdienst (DWD). Obrysy stref: Tyremap (CC BY 4.0) i OpenStreetMap (ODbL).")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .kiteList()
        .navigationTitle("O aplikacji")
    }

    /// Hidden until the version row is tapped five times. Shows the real drive cards, without moving.
    private var simPage: some View {
        Form {
            Section {
                simButton(.highways, "Symuluj unikanie autostrad", "Trasa bocznymi drogami, bez autostrady.", "road.lanes", 0x1D4ED8)
                simButton(.junctions, "Symuluj trudne skrzyżowanie", "Karta omijania skrzyżowania bez świateł.", "arrow.triangle.turn.up.right.circle.fill", 0x0F766E)
                simButton(.detour, "Symuluj prawdziwy czas objazdu", "Korek i boczna droga, która naprawdę jedzie.", "clock.fill", 0x2563EB)
                simButton(.tunnel, "Symuluj wjazd do tunelu", "Trasa przez Elbtunnel i karta czujników.", "location.slash.fill", 0x0F766E)
                simButton(.wave, "Symuluj zieloną falę", "Prędkość, żeby trafić światła na zielono.", "lightbulb.fill", 0x16A34A)
                simButton(.haptic, "Symuluj wibrację przed skrętem", "Telefon wibruje, karta mówi za ile skręt.", "iphone.radiowaves.left.and.right", 0x7C3AED)
                simButton(.border, "Symuluj dojazd do granicy DE–PL", "Trasa Helmstedt–Poznań, kolejka i paliwo.", "flag.fill", 0xDC2626)
                simButton(.umwelt, "Symuluj strefę Umwelt", "Trasa do centrum Magdeburga i plakietka.", "leaf.fill", 0x16A34A)
                simButton(.pump, "Symuluj stację benzynową", "Pytanie o tankowanie, cena i litry do baku.", "fuelpump.fill", 0x2563EB)
            } footer: {
                Text(simError ?? "Każdy przycisk otwiera mapę z linią trasy i kartą tej funkcji. Na górze jest czerwony Zamknij. GPS zostaje w spokoju.")
            }
        }
        .kiteList()
        .navigationTitle("Tryb symulacji")
        .onAppear { loadingSim = nil }
    }

    private func simButton(_ scene: CouchScene, _ title: String, _ detail: String, _ icon: String, _ color: UInt32) -> some View {
        Button {
            loadingSim = scene
            simError = nil
            simulate?(scene) { message in
                loadingSim = nil
                simError = message
            }
        } label: {
            HStack {
                SettingLabel(title, detail: loadingSim == scene ? "Ładuję trasę…" : detail, icon: icon, color: color)
                if loadingSim == scene { ProgressView() }
            }
        }
        .disabled(loadingSim != nil)
    }
}

/** A settings row's name with a small coloured icon in front, like the iPhone's own Settings. */
struct SettingLabel: View {
    let title: String
    var detail: String?
    let icon: String
    let color: UInt32

    init(_ title: String, detail: String? = nil, icon: String, color: UInt32) {
        self.title = title
        self.detail = detail
        self.icon = icon
        self.color = color
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            IconBadge(icon: icon, color: Color(hex: color), size: 30, radius: 8)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/** Settings › Road alerts: which live Waze reports to show and warn about, the police heat map and police aircraft. */
struct WazeSettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var remembered = 0
    @State private var confirmClear = false

    private let kinds: [(WazeAlert.Kind, String)] = [
        (.police, "Policja i mobilne pomiary"),
        (.accident, "Wypadki"),
        (.hazard, "Zagrożenia (zatrzymane auta, przeszkody, dziury)"),
        (.weather, "Pogoda (mgła, lód, zalania)"),
        (.roadworks, "Roboty drogowe"),
        (.closure, "Zamknięcia dróg"),
        (.jam, "Korki zgłoszone przez kierowców"),
    ]

    private let ages: [(Int, String)] = [(30, "30 minut"), (60, "1 godzina"), (120, "2 godziny"), (240, "4 godziny"), (0, "Zostaw wszystkie")]

    /** Whether Waze answered last time, so it's easy to tell when it has stopped working. */
    private var connection: (text: String, color: Color) {
        guard let s = Waze.lastStatus else { return ("Closures: checked once you open the map at city zoom", .gray) }
        let mins = Int(Date().timeIntervalSince(s.at) / 60)
        let when = mins < 1 ? "just now" : "\(mins) min ago"
        switch s.code {
        case 200: return ("Closures working: \(s.count) reports, \(when)", Color(hex: 0x188038))
        case 0: return ("Closures: no connection (\(when))", .orange)
        case 401, 403: return ("Closures: Waze turned Navapp away (\(when)). It may work again later.", .red)
        case -1: return ("Closures: Waze sent something Navapp can't read (\(when))", .red)
        default: return ("Closures: Waze error \(s.code) (\(when))", .orange)
        }
    }

    /** How Waze's app servers answered last time (police, crashes and the rest, while navigating). */
    private var live: (text: String, color: Color) {
        guard let s = WazeLive.lastStatus else { return ("Driver reports: checked once you start a drive", .gray) }
        let mins = Int(Date().timeIntervalSince(s.at) / 60)
        let when = mins < 1 ? "just now" : "\(mins) min ago"
        switch s.code {
        case 200: return ("Driver reports working: \(s.summary), \(when)", Color(hex: 0x188038))
        case 0: return ("Driver reports: no connection (\(when))", .orange)
        case 401: return ("Driver reports: Waze turned Navapp away (\(when)). It may work again later.", .red)
        case 440: return ("Driver reports: reconnecting to Waze (\(when))", .orange)
        case -1: return ("Driver reports: Waze sent something Navapp can't read (\(when))", .red)
        default: return ("Driver reports: Waze error \(s.code) (\(when))", .orange)
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Używaj raportów Waze", isOn: $settings.waze).disabled(settings.noGoogle)
            } footer: {
                Text(settings.noGoogle
                     ? "Off while \"Use Navapp without Google\" is on, since Waze belongs to Google."
                     : "While you navigate, Navapp asks Waze for drivers' reports the way the Waze app does, with an anonymous account Waze makes for it (no name, email or phone). Closures also come from the Waze live map. Waze sees roughly where you are, anonymously. It doesn't allow other apps to do this, so it may stop working one day.")
            }
            if settings.wazeOn {
                Section {
                    HStack(spacing: 8) {
                        Circle().fill(connection.color).frame(width: 10, height: 10)
                        Text(connection.text).font(.subheadline)
                    }
                    HStack(spacing: 8) {
                        Circle().fill(live.color).frame(width: 10, height: 10)
                        Text(live.text).font(.subheadline)
                    }
                    if let s = Waze.lastStatus, s.code == 200 {
                        // What Waze actually sent, so it's easy to see if a kind has gone missing.
                        LabeledContent("Closures, last answer", value: s.summary).font(.subheadline)
                    }
                } header: {
                    Text("Połączenie")
                } footer: {
                    if let s = Waze.lastStatus, s.code != 200 {
                        // What the hidden live map page saw, to send to whoever looks into it.
                        Text("Details: " + WazeWeb.shared.note).font(.caption2.monospaced())
                    }
                }
                Section("Pokazuj i ostrzegaj") {
                    // Only what Waze still shares (see Waze.shares): no switches that can't do anything.
                    ForEach(kinds.filter { Waze.shares.contains($0.0) }, id: \.0) { item in
                        let k = item.0
                        Toggle(isOn: Binding(
                            get: { settings.wazeKinds.contains(k) },
                            set: { on in if on { settings.wazeKinds.insert(k) } else { settings.wazeKinds.remove(k) } }
                        )) {
                            HStack(spacing: 10) {
                                WazeBadge(kind: k, size: 26)
                                Text(item.1)
                            }
                        }
                    }
                }
                Section {
                    Toggle("Pokazuj raporty na mapie", isOn: $settings.wazeOnMap)
                    Toggle("Dźwięk i głos w trakcie jazdy", isOn: $settings.wazeVoice)
                    Picker("Ignoruj starsze niż", selection: $settings.wazeMaxAge) {
                        ForEach(ages, id: \.0) { Text($0.1).tag($0.0) }
                    }
                } header: {
                    Text("Alerty")
                } footer: {
                    Text("W trakcie jazdy karta pokazuje zgłoszenia na trasie, tylko od kierowców jadących w tę samą stronę.")
                }
                if Waze.shares.contains(.police) {
                    Section {
                        Toggle("Mapa policji", isOn: $settings.wazeHeatmap)
                        Toggle("Ryzyko policyjne w trakcie jazdy", isOn: $settings.policeRisk)
                        LabeledContent("Zapamiętane zgłoszenia policji", value: "\(remembered)")
                        if remembered > 0 {
                            Button("Zapomnij wszystkie", role: .destructive) { confirmClear = true }
                        }
                    } footer: {
                        Text("A glow where police get reported most, and a low, medium or high risk for the road ahead (counting reports made at this time of day most). Waze only shares what's live now, so Navapp remembers the reports it sees on this phone, for 90 days and never anywhere else, and both fill in the more you use it.")
                    }
                }
            }
            Section {
                Toggle("Samoloty i śmigłowce policji", isOn: $settings.policeAircraft)
            } header: {
                Text("Lotnictwo")
            } footer: {
                Text("W trakcie jazdy ostrzega, gdy samolot lub śmigłowiec policji jest w promieniu około 10 km. Dane z otwartego śledzenia lotów (adsb.lol), nie z Waze. Część maszyn w ogóle nie nadaje, więc brak ostrzeżenia nie znaczy, że niebo jest puste.")
            }
        }
        .kiteList()
        .navigationTitle("Ostrzeżenia drogowe")
        .onAppear { remembered = WazeHistory.shared.sightings.count }
        .confirmationDialog("Forget the \(remembered) police reports Navapp remembered? The heat map and risk score start again from nothing.",
                            isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Zapomnij", role: .destructive) {
                WazeHistory.shared.clear()
                remembered = 0
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

/** A glass card around a lone row, and nothing when the row already sits in a group. */
private struct OptionalGlass: ViewModifier {
    var on: Bool
    func body(content: Content) -> some View {
        if on { content.glassCard(18) } else { content }
    }
}


enum CouchScene: String, Identifiable {
    case tunnel, border, umwelt, highways, junctions, detour, wave, haptic, pump
    var id: String { rawValue }
}
