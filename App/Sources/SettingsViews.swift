import SwiftUI

struct LayersSheet: View {
    @ObservedObject var settings: AppSettings
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
                tile("Paliwo", icon: "fuelpump.fill", on: settings.fuelOn) { settings.fuelOn.toggle() }
                tile("Radar", icon: "cloud.rain.fill", on: settings.radarOn) { settings.radarOn.toggle() }
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
        .presentationDetents([.height(560)])
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
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Vela.chip(scheme))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(LinearGradient(colors: [Color.white.opacity(scheme == .dark ? 0.06 : 0.45), .clear],
                                                         startPoint: .top, endPoint: .bottom))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(Color.white.opacity(scheme == .dark ? 0.10 : 0.55), lineWidth: 1)
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(on ? Vela.accent(scheme) : .clear, lineWidth: 2.5)
                    )
                Text(title).font(.caption.weight(on ? .semibold : .regular))
                    .foregroundColor(on ? Vela.accent(scheme) : .primary)
            }
        }
        .buttonStyle(.plain)
    }
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var mind = MindSettings.shared
    /** A page of the dock rather than a sheet: no Done button. */
    var inTab = false
    /** Opens the search for choosing home or work (the dock's page has it). */
    var pick: ((PickKind) -> Void)? = nil
    let onChange: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
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
            // A short menu like Waze's: a few big Liquid Glass cards, each opening a page with its switches.
            ScrollView {
                VStack(spacing: 12) {
                    menuRow("Głos i jazda", detail: "Głos i domyślny tryb podróży",
                            icon: "speaker.wave.2.fill", color: 0x0F766E) { drivingPage }
                    menuRow("Trasy", detail: "Objazd, tunel, granica i kalibracja strzałki",
                            icon: "point.topleft.down.curvedto.point.bottomright.filled", color: 0x0891B2) { routesPage }
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
                    menuRow("Moje miejsca", detail: "Dom i praca", icon: "house.fill", color: 0x16A34A) { placesPage }
                    menuRow("Prywatność", detail: "Apex bez Google", value: settings.noGoogle ? "Włączone" : nil,
                            icon: "lock.fill", color: 0x475569) { privacyPage }
                    menuRow("O aplikacji", detail: "Wersja " + version, icon: "info.circle.fill", color: 0x64748B) { aboutPage }
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

    /** One big card of the menu: an icon, the name, what's inside in small, and the page it opens. */
    private func menuRow<Page: View>(_ title: String, detail: String, value: String? = nil, icon: String, color: UInt32,
                                     @ViewBuilder page: @escaping () -> Page) -> some View {
        NavigationLink {
            page()
        } label: {
            HStack(spacing: 14) {
                IconBadge(icon: icon, color: Color(hex: color), size: 38, radius: 11)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 17, weight: .semibold)).foregroundColor(.primary)
                    Text(detail).font(.subheadline).foregroundColor(.secondary)
                }
                Spacer(minLength: 4)
                if let value { Text(value).font(.subheadline.weight(.medium)).foregroundColor(.secondary) }
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.7))
            }
            .padding(14)
            .glassCard(18)
        }
        .buttonStyle(.plain)
    }

    private var drivingPage: some View {
        Form {
            Section {
                Toggle(isOn: $settings.voice) { SettingLabel("Prowadzenie głosem", icon: "speaker.wave.2.fill", color: 0x0F766E) }
                Picker(selection: $settings.defaultMode) {
                    ForEach(TravelMode.allCases) { Text($0.label).tag($0) }
                } label: { SettingLabel("Domyślny tryb podróży", icon: "car.fill", color: 0x2563EB) }
            }
        }
        .kiteList()
        .navigationTitle("Głos i jazda")
    }

    private var routesPage: some View {
        Form {
            Section {
                Toggle(isOn: $mind.deadReckoning) { SettingLabel("Czujniki w tunelu", detail: "Gdy GPS zniknie, pozycja jedzie z czujników telefonu po osi drogi.", icon: "location.slash.fill", color: 0x0F766E) }
                Toggle(isOn: $mind.trueTime) { SettingLabel("Prawdziwy czas objazdu", detail: "Objazd tylko wtedy, gdy boczna droga naprawdę jedzie, a nie stoi tak samo.", icon: "clock.fill", color: 0x2563EB) }
                Toggle(isOn: $mind.greenWave) { SettingLabel("Zielona fala", detail: "Podpowiada prędkość, żeby trafić na następne światła na zielonym.", icon: "lightbulb.fill", color: 0x16A34A) }
                Toggle(isOn: $mind.haptics) { SettingLabel("Wibracja przed skrętem", detail: "Krótka wibracja tuż przed manewrem.", icon: "iphone.radiowaves.left.and.right", color: 0x7C3AED) }
                Toggle(isOn: $mind.borderAssist) { SettingLabel("Kolejka na granicy", detail: "Przy granicy DE–PL pokazuje przejście z krótszą kolejką.", icon: "flag.fill", color: 0xDC2626) }
                Toggle(isOn: $mind.umwelt) { SettingLabel("Strefa Umwelt", detail: "Rysuje urzędowy obrys zielonej strefy, gdy pinezka albo trasa wymaga wjazdu.", icon: "leaf.fill", color: 0x16A34A) }
                Toggle(isOn: $settings.avoidTolls) { SettingLabel("Unikaj dróg płatnych", detail: "Omija odcinki z opłatą i bramki.", icon: "sterlingsign.circle.fill", color: 0xF59E0B) }
                Toggle(isOn: $settings.avoidHighways) {
                    SettingLabel("Unikaj autostrad", detail: "Prowadzi bez autostrad, bocznymi drogami.", icon: "road.lanes", color: 0x1D4ED8)
                }
            } footer: {
                Text("Obrys pochodzi z Umweltbundesamt i leży na mapie w miejscu podanym przez urząd. Znaki przy drodze są ważniejsze. Strefa znika, gdy już jesteś w środku.")
            }
            Section {
                Stepper(value: $mind.gpsTrust, in: 25...150, step: 5) {
                    SettingLabel("GPS słaby od \(mind.gpsTrust) m", icon: "location.fill", color: 0x0891B2)
                }
                Stepper(value: $mind.headingTrim, in: -30...30, step: 1) {
                    SettingLabel("Korekta kierunku: \(mind.headingTrim)°", icon: "location.north.line.fill", color: 0x0F766E)
                }
                Button {
                    mind.resetAsked = true
                } label: {
                    SettingLabel("Wyzeruj czujniki", icon: "arrow.counterclockwise", color: 0xDC2626)
                }
            } header: {
                Text("Kalibracja")
            } footer: {
                Text("Czujniki wchodzą dopiero w tunelu albo gdy GPS myli się bardziej niż wybrany próg, nie przy każdym postoju. Strzałkę kalibrujesz korektą kierunku. Kompas iPhone’a: połóż telefon płasko i zrób ósemkę w powietrzu, potem wyzeruj czujniki.")
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
            } header: {
                Text("Pokazuj na mapie i trasie")
            } footer: {
                Text("Fotoradary i kamery tablic rejestracyjnych z otwartej mapy OpenStreetMap, pokazywane na mapie i na Twojej trasie. W niektórych krajach, jak Francja i Niemcy, ostrzegania o fotoradarach nie pozwalają przepisy, więc sprawdź, zanim włączysz tam głos.")
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
                Text("Czarny motyw używa czystej czerni i zawsze matowego szkła. Przejście do lub z motywu Czarny wraca do pierwszej strony ustawień. Odznaka pogody pyta Open-Meteo, z Twoją pozycją zaokrągloną do ok. 10 km.")
            }
        }
        .kiteList()
        .navigationTitle("Mapa i wyświetlanie")
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
                Text("Wyłączone (domyślnie): wyszukiwanie, szczegóły miejsc, trasy i ruch na żywo pochodzą z Google, pytane anonimowo, bez konta. Włączone: wszystko pochodzi z darmowych, otwartych usług i nic nie trafia do Google, ale wyszukiwanie i trasy są mniej kompletne.")
            }
        }
        .kiteList()
        .navigationTitle("Prywatność")
    }

    private var aboutPage: some View {
        Form {
            Section {
                LabeledContent("Wersja", value: version)
                Link("Apex na GitHubie", destination: URL(string: "https://github.com/matteofx1/kite-maps")!)
                Link("Na bazie Vela Maps dla Androida", destination: URL(string: "https://github.com/PimpinPumpkin/Vela")!)
                Link("Raporty Waze na żywo jak w SABRE Plus (MIT)", destination: URL(string: "https://github.com/nicglazkov/highway-radar-sabre-plus")!)
                Text("Wolne oprogramowanie na licencji GPL-3.0. Mapy © Apple. Trasy © FOSSGIS OSRM, współtwórcy OpenStreetMap. Cieniowanie © Esri. Ceny paliw: Tankerkönig / MTS-K (CC BY 4.0). Roboty i zamknięcia: Autobahn GmbH. Pogoda: Open-Meteo.com (CC BY 4.0). Radar opadów: Deutscher Wetterdienst (DWD).")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .kiteList()
        .navigationTitle("O aplikacji")
    }
}

/** A settings row's name with a small coloured icon in front, like the iPhone's own Settings. */
struct SettingLabel: View {
    let title: String
    var detail: String? = nil
    let icon: String
    let color: UInt32

    init(_ title: String, detail: String? = nil, icon: String, color: UInt32) {
        self.title = title
        self.detail = detail
        self.icon = icon
        self.color = color
    }

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(icon: icon, color: Color(hex: color), size: 30, radius: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
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
        (.weather, "Pogoda (mgła, lód, powodzie)"),
        (.roadworks, "Roboty drogowe"),
        (.closure, "Zamknięcia dróg"),
        (.jam, "Korki zgłaszane przez kierowców"),
    ]

    private let ages: [(Int, String)] = [(30, "30 minut"), (60, "1 godzina"), (120, "2 godziny"), (240, "4 godziny"), (0, "Zachowaj wszystkie")]

    /** Whether Waze answered last time, so it's easy to tell when it has stopped working. */
    private var connection: (text: String, color: Color) {
        guard let s = Waze.lastStatus else { return ("Zamknięcia: sprawdzane po otwarciu mapy w skali miasta", .gray) }
        let mins = Int(Date().timeIntervalSince(s.at) / 60)
        let when = mins < 1 ? "właśnie teraz" : "\(mins) min temu"
        switch s.code {
        case 200: return ("Zamknięcia działają: \(s.count) raportów, \(when)", Color(hex: 0x188038))
        case 0: return ("Zamknięcia: brak połączenia (\(when))", .orange)
        case 401, 403: return ("Zamknięcia: Waze odrzuciło Apexa (\(when)). Może znowu zadziałać później.", .red)
        case -1: return ("Zamknięcia: Waze wysłało coś, czego Apex nie potrafi odczytać (\(when))", .red)
        default: return ("Zamknięcia: błąd Waze \(s.code) (\(when))", .orange)
        }
    }

    /** How Waze's app servers answered last time (police, crashes and the rest, while navigating). */
    private var live: (text: String, color: Color) {
        guard let s = WazeLive.lastStatus else { return ("Raporty kierowców: sprawdzane po rozpoczęciu jazdy", .gray) }
        let mins = Int(Date().timeIntervalSince(s.at) / 60)
        let when = mins < 1 ? "właśnie teraz" : "\(mins) min temu"
        switch s.code {
        case 200: return ("Raporty kierowców działają: \(s.summary), \(when)", Color(hex: 0x188038))
        case 0: return ("Raporty kierowców: brak połączenia (\(when))", .orange)
        case 401: return ("Raporty kierowców: Waze odrzuciło Apexa (\(when)). Może znowu zadziałać później.", .red)
        case 440: return ("Raporty kierowców: łączę się ponownie z Waze (\(when))", .orange)
        case -1: return ("Raporty kierowców: Waze wysłało coś, czego Apex nie potrafi odczytać (\(when))", .red)
        default: return ("Raporty kierowców: błąd Waze \(s.code) (\(when))", .orange)
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Korzystaj z raportów Waze", isOn: $settings.waze).disabled(settings.noGoogle)
            } footer: {
                Text(settings.noGoogle
                     ? "Wyłączone, gdy włączone jest \"Używaj Apexa bez Google\", bo Waze należy do Google."
                     : "Podczas nawigacji Apex pyta Waze o raporty kierowców tak jak aplikacja Waze, przez anonimowe konto, które Waze dla niej tworzy (bez imienia, e-maila ani telefonu). Zamknięcia dróg też pochodzą z mapy na żywo Waze. Waze widzi z grubsza, gdzie jesteś, anonimowo. Nie pozwala innym aplikacjom tego robić, więc któregoś dnia może przestać działać.")
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
                        LabeledContent("Zamknięcia, ostatnia odpowiedź", value: s.summary).font(.subheadline)
                    }
                } header: {
                    Text("Połączenie")
                } footer: {
                    if let s = Waze.lastStatus, s.code != 200 {
                        // What the hidden live map page saw, to send to whoever looks into it.
                        Text("Szczegóły: " + WazeWeb.shared.note).font(.caption2.monospaced())
                    }
                }
                Section("Pokazuj i ostrzegaj o") {
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
                    Toggle("Dźwięk i komunikat podczas jazdy", isOn: $settings.wazeVoice)
                    Picker("Ignoruj raporty starsze niż", selection: $settings.wazeMaxAge) {
                        ForEach(ages, id: \.0) { Text($0.1).tag($0.0) }
                    }
                } header: {
                    Text("Ostrzeżenia")
                } footer: {
                    Text("Podczas jazdy karta wyskakuje dla raportów na Twojej trasie, ale tylko tych zgłoszonych przez kierowców jadących w Twoją stronę.")
                }
                if Waze.shares.contains(.police) {
                    Section {
                        Toggle("Mapa zagrożeń policji", isOn: $settings.wazeHeatmap)
                        Toggle("Wynik ryzyka policji podczas jazdy", isOn: $settings.policeRisk)
                        LabeledContent("Zapamiętane raporty policji", value: "\(remembered)")
                        if remembered > 0 {
                            Button("Zapomnij wszystkie", role: .destructive) { confirmClear = true }
                        }
                    } footer: {
                        Text("Poświata tam, gdzie policję zgłasza się najczęściej, oraz niskie, średnie lub wysokie ryzyko dla drogi przed tobą (licząc głównie raporty z tej pory dnia). Waze udostępnia tylko to, co aktualne, więc Apex pamięta raporty, które widzi, tylko na tym telefonie, przez 90 dni i nigdzie więcej — a oba wypełniają się im więcej z niego korzystasz.")
                    }
                }
            }
            Section {
                Toggle("Samoloty i helikoptery policji", isOn: $settings.policeAircraft)
            } header: {
                Text("Samoloty")
            } footer: {
                Text("Podczas jazdy ostrzega, gdy samolot policji jest w odległości ok. 10 km, na podstawie otwartego śledzenia lotów (adsb.lol), nie Waze. Rozpoznaje je po policyjnym znaku wywoławczym (jak NPAS w UK), a niektóre w ogóle nie nadają, więc brak ostrzeżenia nie znaczy, że niebo jest czyste.")
            }
        }
        .kiteList()
        .navigationTitle("Ostrzeżenia drogowe")
        .onAppear { remembered = WazeHistory.shared.sightings.count }
        .confirmationDialog("Zapomnieć \(remembered) zapamiętanych raportów policji? Mapa zagrożeń i wynik ryzyka zaczną od zera.",
                            isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Zapomnij", role: .destructive) {
                WazeHistory.shared.clear()
                remembered = 0
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}
