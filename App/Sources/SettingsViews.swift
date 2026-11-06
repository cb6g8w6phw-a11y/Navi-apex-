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
                VStack(spacing: 12) {
                    menuRow("Głos i jazda", detail: "Polski lektor i domyślny tryb podróży",
                            icon: "speaker.wave.2.fill", color: 0x0F766E) { drivingPage }
                    menuRow("Trasy", detail: "Objazd, tunel, granica i kalibracja",
                            icon: "signpost.right.fill", color: 0x0891B2) { routesPage }
                    menuRow("Kamery i prędkość", detail: "Ostrzeżenia o fotoradarach, alarm prędkości",
                            icon: "camera.fill", color: 0xDC2626) { camerasPage }
                    menuRow("Ostrzeżenia drogowe", detail: Waze.shares.contains(.police) ? "Policja, wypadki, zamknięcia" : "Zamknięcia, samoloty policji",
                            value: settings.wazeOn ? "Włączone" : "Wyłączone", icon: "exclamationmark.triangle.fill", color: 0x7C3AED) {
                        WazeSettingsView(settings: settings)
                    }
                    menuRow("Ceny paliw", detail: "Najtańsze paliwo w pobliżu i na trasie",
                            value: settings.fuelOn && !settings.fuelKey.isEmpty ? "Włączone" : nil, icon: "fuelpump.fill", color: 0x2563EB) {
                        FuelSettingsView(settings: settings)
                    }
                    menuRow("Moje auto", detail: "Ubezpieczenie, przegląd, olej i filtry",
                            value: CarStatus(settings: settings).mostUrgent?.text, icon: "car.fill", color: 0x16A34A) {
                        CarPage(settings: settings)
                    }
                    menuRow("Mapa i wyświetlanie", detail: "Motyw, jednostki, przycisk parkowania", icon: "circle.lefthalf.filled", color: 0x334155) { mapPage }
                    menuRow("Muzyka", detail: "Apple Music, Spotify i własne linki",
                            value: MusicCatalog.active(settings).name, icon: "music.note", color: 0xFA2D48) { musicPage }
                    menuRow("Moje miejsca", detail: "Dom i praca", icon: "house.fill", color: 0x16A34A) { placesPage }
                    menuRow("Prywatność", detail: "Apex bez Google", value: settings.noGoogle ? "Włączone" : nil,
                            icon: "lock.fill", color: 0x475569) { privacyPage }
                    menuRow("O aplikacji", detail: "Wersja " + version, icon: "info.circle.fill", color: 0x64748B) { aboutPage }
                    if mind.simUnlocked {
                        menuRow("Tryb symulacji", detail: "Test Mode · tunel, granica i Umwelt z kanapy",
                                icon: "play.rectangle.fill", color: 0x0F766E) { simPage }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
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

    private var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }

    /** One big row of the menu: an icon, the name, what's inside in small, and the page it opens. */
    private func menuRow<Page: View>(_ title: String, detail: String, value: String? = nil, icon: String, color: UInt32,
                                     @ViewBuilder page: @escaping () -> Page) -> some View {
        NavigationLink {
            page()
        } label: {
            HStack(alignment: .center, spacing: 14) {
                IconBadge(icon: icon, color: Color(hex: color), size: 38, radius: 11)
                    .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let value {
                    Text(value)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.7))
                    .frame(width: 14, alignment: .center)
            }
            .padding(14)
            .glassCard(18)
        }
    }

    private var drivingPage: some View {
        Form {
            Section {
                Toggle(isOn: $settings.voice) { SettingLabel("Prowadzenie głosem", detail: "Polski lektor: Zosia albo inny głos pl-PL z telefonu.", icon: "speaker.wave.2.fill", color: 0x0F766E) }
                Picker(selection: $settings.defaultMode) {
                    ForEach(TravelMode.allCases) { Text($0.label).tag($0) }
                } label: { SettingLabel("Domyślny tryb podróży", icon: "car.fill", color: 0x2563EB) }
            } footer: {
                Text("Lektor czyta manewry po polsku. Jeśli głos brzmi mechanicznie, w Ustawieniach iPhone’a pobierz rozszerzony głos polski (Ułatwienia dostępu → Zawartość mówiona → Głosy).")
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
                Toggle(isOn: $mind.trueTime) { SettingLabel("Prawdziwy czas objazdu", detail: "Objazd tylko wtedy, gdy boczna droga naprawdę jedzie.", icon: "clock.fill", color: 0x2563EB) }
                Toggle(isOn: $mind.deadReckoning) { SettingLabel("Czujniki w tunelu", detail: "Gdy GPS zniknie, pozycja jedzie z czujników po osi drogi.", icon: "location.slash.fill", color: 0x0F766E) }
                Toggle(isOn: $mind.greenWave) { SettingLabel("Zielona fala", detail: "Podpowiada prędkość, żeby trafić na światła na zielonym.", icon: "lightbulb.fill", color: 0x16A34A) }
                Toggle(isOn: $mind.haptics) { SettingLabel("Wibracja przed skrętem", icon: "iphone.radiowaves.left.and.right", color: 0x7C3AED) }
                Toggle(isOn: $mind.borderAssist) { SettingLabel("Kolejka na granicy", detail: "Przy granicy DE–PL pokazuje przejście z krótszą kolejką.", icon: "flag.fill", color: 0xDC2626) }
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
                Picker(selection: $settings.theme) {
                    ForEach(ThemeMode.allCases) { Text($0.label).tag($0) }
                } label: { SettingLabel("Motyw", icon: "circle.lefthalf.filled", color: 0x334155) }
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
                Text("Tak jak dokładanie usługi w Mornye: wklejasz link i Apex go otwiera. Przesuń wiersz w lewo, żeby usunąć. Apex nie pobiera utworów.")
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
                Toggle(isOn: $settings.noGoogle) { SettingLabel("Używaj Apexa bez Google", icon: "lock.fill", color: 0x475569) }
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
                Link("Apex na GitHubie", destination: URL(string: "https://github.com/matteofx1/kite-maps")!)
                Link("Na bazie Vela Maps dla Androida", destination: URL(string: "https://github.com/PimpinPumpkin/Vela")!)
                Link("Raporty Waze na żywo jak w SABRE Plus (MIT)", destination: URL(string: "https://github.com/nicglazkov/highway-radar-sabre-plus")!)
                Text("Wolne oprogramowanie na licencji GPL-3.0. Mapy © Apple. Trasy © FOSSGIS OSRM, współtwórcy OpenStreetMap. Cieniowanie © Esri. Ceny paliw: Tankerkönig / MTS-K (CC BY 4.0). Roboty i zamknięcia: Autobahn GmbH. Pogoda: Open-Meteo.com (CC BY 4.0). Radar opadów: Deutscher Wetterdienst (DWD). Obrysy stref: Tyremap (CC BY 4.0) i OpenStreetMap (ODbL).")
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
        case 401, 403: return ("Closures: Waze turned Apex away (\(when)). It may work again later.", .red)
        case -1: return ("Closures: Waze sent something Apex can't read (\(when))", .red)
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
        case 401: return ("Driver reports: Waze turned Apex away (\(when)). It may work again later.", .red)
        case 440: return ("Driver reports: reconnecting to Waze (\(when))", .orange)
        case -1: return ("Driver reports: Waze sent something Apex can't read (\(when))", .red)
        default: return ("Driver reports: Waze error \(s.code) (\(when))", .orange)
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Używaj raportów Waze", isOn: $settings.waze).disabled(settings.noGoogle)
            } footer: {
                Text(settings.noGoogle
                     ? "Off while \"Use Apex without Google\" is on, since Waze belongs to Google."
                     : "While you navigate, Apex asks Waze for drivers' reports the way the Waze app does, with an anonymous account Waze makes for it (no name, email or phone). Closures also come from the Waze live map. Waze sees roughly where you are, anonymously. It doesn't allow other apps to do this, so it may stop working one day.")
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
                        Text("A glow where police get reported most, and a low, medium or high risk for the road ahead (counting reports made at this time of day most). Waze only shares what's live now, so Apex remembers the reports it sees on this phone, for 90 days and never anywhere else, and both fill in the more you use it.")
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
        .confirmationDialog("Forget the \(remembered) police reports Apex remembered? The heat map and risk score start again from nothing.",
                            isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Zapomnij", role: .destructive) {
                WazeHistory.shared.clear()
                remembered = 0
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}


enum CouchScene: String, Identifiable {
    case tunnel, border, umwelt, highways, junctions, detour, wave, haptic, pump
    var id: String { rawValue }
}
