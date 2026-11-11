import MapKit
import SwiftUI

/**
 * The weather where you are: the small badge on the map and the sheet behind it. From Open-Meteo
 * (free, no key); only your position rounded to about 10 km is sent. The rain radar is the German
 * weather service's (DWD) open radar.
 */
@MainActor
final class WeatherNow: ObservableObject {
    static let shared = WeatherNow()

    struct Reading: Equatable {
        var temperature: Double
        var code: Int
        var isDay: Bool
    }

    struct Hour: Identifiable, Equatable {
        let id: String
        let label: String
        let temperature: Double
        let rain: Int
        let code: Int
        let isDay: Bool
    }

    struct Detail: Equatable {
        var feelsLike: Double
        var humidity: Int
        var wind: Double
        var gust: Double
        var rainNow: Double
        var high: Double
        var low: Double
        var sunrise: String
        var sunset: String
        var hours: [Hour]
    }

    @Published private(set) var reading: Reading?
    @Published private(set) var detail: Detail?
    private var key = ""
    private var at = Date.distantPast
    private var loading = false

    /** Fahrenheit only where miles are used with feet (the US); the UK uses miles but degrees Celsius. */
    static var fahrenheit: Bool { !Fmt.metric && !Fmt.yards }

    func refresh(lat: Double, lng: Double) async {
        let rLat = (lat * 10).rounded() / 10, rLng = (lng * 10).rounded() / 10
        let k = "\(rLat),\(rLng),\(Self.fahrenheit),\(Fmt.metric)"
        guard !loading, k != key || Date().timeIntervalSince(at) > 600 else { return }
        loading = true
        defer { loading = false }
        guard var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast") else { return }
        comps.queryItems = [
            URLQueryItem(name: "latitude", value: String(rLat)),
            URLQueryItem(name: "longitude", value: String(rLng)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,precipitation,weather_code,is_day,wind_speed_10m,wind_gusts_10m"),
            URLQueryItem(name: "hourly", value: "temperature_2m,precipitation_probability,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min,sunrise,sunset"),
            URLQueryItem(name: "forecast_days", value: "2"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "temperature_unit", value: Self.fahrenheit ? "fahrenheit" : "celsius"),
            URLQueryItem(name: "wind_speed_unit", value: Fmt.metric ? "kmh" : "mph"),
        ]
        guard let url = comps.url,
              let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let cur = json["current"] as? [String: Any],
              let temp = cur["temperature_2m"] as? Double,
              let code = cur["weather_code"] as? Int else { return }
        let isDay = (cur["is_day"] as? Int ?? 1) == 1
        reading = Reading(temperature: temp, code: code, isDay: isDay)

        // The next twelve hours, found by comparing the local time strings ("2026-11-01T10:00").
        var hours: [Hour] = []
        if let h = json["hourly"] as? [String: Any], let times = h["time"] as? [String] {
            let temps = h["temperature_2m"] as? [Any] ?? []
            let rain = h["precipitation_probability"] as? [Any] ?? []
            let codes = h["weather_code"] as? [Any] ?? []
            let days = h["is_day"] as? [Any] ?? []
            let now = (cur["time"] as? String).map { String($0.prefix(13)) + ":00" } ?? ""
            for (i, t) in times.enumerated() where t >= now && hours.count < 12 {
                guard i < temps.count, let tv = temps[i] as? Double else { continue }
                hours.append(Hour(id: t, label: String(t.suffix(5)), temperature: tv,
                                  rain: i < rain.count ? (rain[i] as? Int ?? 0) : 0,
                                  code: i < codes.count ? (codes[i] as? Int ?? 3) : 3,
                                  isDay: i < days.count ? (days[i] as? Int ?? 1) == 1 : true))
            }
        }
        let daily = json["daily"] as? [String: Any]
        func first(_ name: String) -> Any? { (daily?[name] as? [Any])?.first }
        detail = Detail(feelsLike: cur["apparent_temperature"] as? Double ?? temp,
                        humidity: cur["relative_humidity_2m"] as? Int ?? 0,
                        wind: cur["wind_speed_10m"] as? Double ?? 0,
                        gust: cur["wind_gusts_10m"] as? Double ?? 0,
                        rainNow: cur["precipitation"] as? Double ?? 0,
                        high: first("temperature_2m_max") as? Double ?? temp,
                        low: first("temperature_2m_min") as? Double ?? temp,
                        sunrise: (first("sunrise") as? String).map { String($0.suffix(5)) } ?? "",
                        sunset: (first("sunset") as? String).map { String($0.suffix(5)) } ?? "",
                        hours: hours)
        key = k
        at = Date()
    }

    /** The picture for an Open-Meteo weather code (the WMO codes). */
    static func symbol(code: Int, isDay: Bool) -> String {
        switch code {
        case 0: return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...57: return "cloud.drizzle.fill"
        case 61...66: return "cloud.rain.fill"
        case 67: return "cloud.sleet.fill"
        case 71...77, 85, 86: return "cloud.snow.fill"
        case 80...82: return "cloud.heavyrain.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    static func symbol(_ r: Reading) -> String { symbol(code: r.code, isDay: r.isDay) }

    static func words(_ code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1: return "Mostly clear"
        case 2: return "Partly cloudy"
        case 3: return "Overcast"
        case 45, 48: return "Fog"
        case 51...57: return "Drizzle"
        case 61...65: return "Rain"
        case 66, 67: return "Freezing rain"
        case 71...77: return "Snow"
        case 80...82: return "Rain showers"
        case 85, 86: return "Snow showers"
        case 95...99: return "Thunderstorm"
        default: return "Cloudy"
        }
    }
}

/** A small round badge: the weather symbol over the temperature. Tap for the details and the radar. */
struct WeatherBall: View {
    @ObservedObject private var weather = WeatherNow.shared
    let action: () -> Void

    var body: some View {
        if let r = weather.reading {
            Button(action: action) {
                VStack(spacing: 0) {
                    Image(systemName: WeatherNow.symbol(r))
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 17, weight: .semibold))
                    Text("\(Int(r.temperature.rounded()))°")
                        .font(.system(size: 12, weight: .bold))
                        .monospacedDigit()
                }
                .frame(width: 46, height: 46)
                .glassButton(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Weather")
        }
    }
}

// MARK: Rain radar (Deutscher Wetterdienst)

/** The DWD's rain radar, asked for as map tiles from their open WMS server. Covers Germany and its surroundings. */
final class DWDRadarOverlay: MKTileOverlay {
    init() {
        super.init(urlTemplate: nil)
        canReplaceMapContent = false
        tileSize = CGSize(width: 256, height: 256)
        minimumZ = 3
        maximumZ = 12
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        let half = 20_037_508.342789244
        let size = half * 2 / pow(2, Double(path.z))
        let minX = -half + Double(path.x) * size
        let maxY = half - Double(path.y) * size
        // The last number changes every five minutes, so a newer picture is never hidden behind an old copy.
        let stamp = Int(Date().timeIntervalSince1970 / 300)
        let s = "https://maps.dwd.de/geoserver/dwd/wms?service=WMS&version=1.3.0&request=GetMap&layers=dwd:Niederschlagsradar"
            + "&styles=&format=image/png&transparent=true&crs=EPSG:3857&width=256&height=256"
            + "&bbox=\(minX),\(maxY - size),\(minX + size),\(maxY)&t=\(stamp)"
        return URL(string: s) ?? URL(fileURLWithPath: "/")
    }
}

/** The German road map (FOSSGIS), the same roads the router uses. Replaces Apple's picture. */
final class GermanRoadsOverlay: MKTileOverlay {
    init() {
        super.init(urlTemplate: "https://tile.openstreetmap.de/{z}/{x}/{y}.png")
        canReplaceMapContent = true
        tileSize = CGSize(width: 256, height: 256)
        minimumZ = 0
        maximumZ = 19
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        var req = URLRequest(url: url(forTilePath: path), timeoutInterval: 15)
        req.setValue("Apex-iOS", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, _, error in
            result(data, error)
        }.resume()
    }
}

/** A small map for the weather sheet: the rain radar over where you are. */
/** Weather at the hour you will be there, not the weather right now. Open-Meteo, one point at a time. */
enum RouteSky {
    static func lines(along line: [LatLng], arrive: Date) async -> [String] {
        guard line.count >= 2 else { return [] }
        let cum = Geo.cumulative(line)
        let total = max(cum.last ?? 1, 1)
        let ahead = max(0, arrive.timeIntervalSinceNow)
        let marks: [(String, Double)] = ahead > 20 * 60
            ? [(L.t("W drodze", "Unterwegs", "On the way"), 0.45), (L.t("Przy celu", "Am Ziel", "At the end"), 1)]
            : [(L.t("Przy celu", "Am Ziel", "At the end"), 1)]
        var out: [String] = []
        for (name, frac) in marks {
            let p = Geo.point(along: line, meters: total * min(frac, 0.98), cumulative: cum)
            let when = Date().addingTimeInterval(ahead * frac)
            if let text = await one(p, at: when) { out.append("\(name) · \(text)") }
        }
        return out
    }

    private static func one(_ p: LatLng, at when: Date) async -> String? {
        guard var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast") else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.3f", p.lat)),
            URLQueryItem(name: "longitude", value: String(format: "%.3f", p.lng)),
            URLQueryItem(name: "hourly", value: "temperature_2m,precipitation_probability,weather_code,visibility"),
            URLQueryItem(name: "forecast_days", value: "2"),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        guard let url = comps.url,
              let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let h = json["hourly"] as? [String: Any],
              let times = h["time"] as? [String],
              let temps = h["temperature_2m"] as? [Double],
              let codes = h["weather_code"] as? [Int] else { return nil }
        let rain = h["precipitation_probability"] as? [Int] ?? []
        let vis = h["visibility"] as? [Double] ?? []
        let stamp = Self.stamp.string(from: when)
        guard let i = times.firstIndex(where: { $0 >= stamp }) ?? times.indices.last else { return nil }
        let code = codes[i]
        let temp = temps[i]
        let wet = i < rain.count ? rain[i] : 0
        let see = i < vis.count ? vis[i] : 20_000
        return phrase(code: code, temp: temp, rain: wet, visibility: see, hour: TripClock.time.string(from: when))
    }

    private static func phrase(code: Int, temp: Double, rain: Int, visibility: Double, hour: String) -> String {
        let t = "\(Int(temp.rounded()))°"
        let what: String
        if code == 45 || code == 48 || visibility < 1_000 {
            what = L.t("mgła", "Nebel", "fog")
        } else if temp <= 0, [56, 57, 66, 67, 71, 73, 75, 77, 85, 86].contains(code) {
            what = L.t("lód", "Glätte", "ice")
        } else if (51...67).contains(code) || (80...82).contains(code) || rain >= 50 {
            what = L.t("deszcz", "Regen", "rain")
        } else if (71...77).contains(code) || code == 85 || code == 86 {
            what = L.t("śnieg", "Schnee", "snow")
        } else if (95...99).contains(code) {
            what = L.t("burza", "Gewitter", "storm")
        } else {
            what = L.t("sucho", "trocken", "dry")
        }
        return "\(hour) · \(what) · \(t)"
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f
    }()
}

struct RadarMiniMap: UIViewRepresentable {
    let center: CLLocationCoordinate2D
    let dark: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.tintColor = UIColor(hex: 0x14B8A6)
        map.showsCompass = false
        map.isPitchEnabled = false
        map.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        map.overrideUserInterfaceStyle = dark ? .dark : .light
        map.region = MKCoordinateRegion(center: center, latitudinalMeters: 220_000, longitudinalMeters: 220_000)
        map.addOverlay(DWDRadarOverlay(), level: .aboveRoads)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        map.overrideUserInterfaceStyle = dark ? .dark : .light
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ map: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tiles = overlay as? MKTileOverlay {
                let r = MKTileOverlayRenderer(tileOverlay: tiles)
                r.alpha = 0.8
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

// MARK: The sheet

struct WeatherSheet: View {
    let spot: LatLng?
    @ObservedObject var settings: AppSettings
    @ObservedObject private var weather = WeatherNow.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    private var unit: String { WeatherNow.fahrenheit ? "°F" : "°C" }
    private var windUnit: String { Fmt.metric ? "km/h" : "mph" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Pogoda").font(.system(size: 26, weight: .heavy))
                    Spacer()
                    CircleIconButton(icon: "xmark") { dismiss() }
                }
                if let r = weather.reading, let d = weather.detail {
                    header(r, d)
                    stats(d)
                    if !d.hours.isEmpty { hourly(d) }
                    radar
                } else {
                    HStack { ProgressView(); Text("Wczytuję pogodę…").foregroundColor(.secondary) }
                        .padding(.vertical, 30)
                }
                Text("Pogoda: Open-Meteo.com. Radar: Deutscher Wetterdienst (DWD).")
                    .font(.caption2).foregroundColor(.secondary)
            }
            .padding(20)
        }
        .background(Vela.sheet(scheme).ignoresSafeArea())
        .task {
            if let s = spot { await WeatherNow.shared.refresh(lat: s.lat, lng: s.lng) }
        }
    }

    private func header(_ r: WeatherNow.Reading, _ d: WeatherNow.Detail) -> some View {
        HStack(spacing: 16) {
            Image(systemName: WeatherNow.symbol(r))
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 54))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Int(r.temperature.rounded()))\(unit)").font(.system(size: 44, weight: .heavy)).monospacedDigit()
                Text(WeatherNow.words(r.code)).font(.system(size: 18, weight: .semibold))
                Text("Maks. \(Int(d.high.rounded()))° · min. \(Int(d.low.rounded()))°").font(.subheadline).foregroundColor(.secondary)
            }
            Spacer()
        }
    }

    private func stats(_ d: WeatherNow.Detail) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            stat("thermometer.medium", "Feels like", "\(Int(d.feelsLike.rounded()))°")
            stat("wind", "Wind", "\(Int(d.wind.rounded())) \(windUnit)" + (d.gust > d.wind + 8 ? " (gusts \(Int(d.gust.rounded())))" : ""))
            stat("humidity.fill", "Humidity", "\(d.humidity)%")
            stat("drop.fill", "Rain now", d.rainNow > 0 ? String(format: "%.1f mm", d.rainNow) : "None")
            if !d.sunrise.isEmpty { stat("sunrise.fill", "Sunrise", d.sunrise) }
            if !d.sunset.isEmpty { stat("sunset.fill", "Sunset", d.sunset) }
        }
    }

    private func stat(_ icon: String, _ title: String, _ value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundColor(Vela.accentText(scheme)).frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption).foregroundColor(.secondary)
                Text(value).font(.system(size: 15, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Vela.chip(scheme)))
    }

    private func hourly(_ d: WeatherNow.Detail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Najbliższe godziny").font(.subheadline.weight(.semibold)).foregroundColor(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(d.hours) { h in
                        VStack(spacing: 6) {
                            Text(h.label).font(.caption).foregroundColor(.secondary)
                            Image(systemName: WeatherNow.symbol(code: h.code, isDay: h.isDay))
                                .symbolRenderingMode(.multicolor).font(.system(size: 20))
                            Text("\(Int(h.temperature.rounded()))°").font(.system(size: 15, weight: .bold)).monospacedDigit()
                            Text(h.rain > 0 ? "\(h.rain)%" : " ").font(.caption2).foregroundColor(Color(hex: 0x2F7BFF))
                        }
                        .frame(width: 58)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Vela.chip(scheme)))
                    }
                }
            }
        }
    }

    private var radar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Radar opadów").font(.subheadline.weight(.semibold)).foregroundColor(.secondary)
            if let s = spot {
                RadarMiniMap(center: CLLocationCoordinate2D(latitude: s.lat, longitude: s.lng), dark: scheme == .dark)
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            Toggle(isOn: $settings.radarOn) {
                Text("Pokaż radar na mapie").font(.system(size: 16, weight: .semibold))
            }
            .tint(Vela.accentText(scheme))
            Text("Niebieski to słaby deszcz, żółty, czerwony i fiolet to ulewa. Radar obejmuje Niemcy i okolice.")
                .font(.caption).foregroundColor(.secondary)
        }
    }
}
