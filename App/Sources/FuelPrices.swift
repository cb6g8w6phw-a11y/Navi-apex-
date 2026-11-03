import CoreLocation
import Foundation
import SwiftUI

/** One petrol station with a price for the fuel picked in Settings. */
struct FuelStation: Identifiable, Equatable {
    let id: String
    let brand: String
    let name: String
    let street: String
    let place: String
    let location: LatLng
    let price: Double
    let open: Bool

    static func == (a: FuelStation, b: FuelStation) -> Bool { a.id == b.id && a.price == b.price }

    var title: String { (brand.isEmpty ? name : brand).capitalized }
    var address: String { [street, place].filter { !$0.isEmpty }.joined(separator: ", ") }
    var priceText: String { String(format: "%.3f", price) }
}

/**
 * Live fuel prices in Germany from the free Tankerkönig API (the official fuel price reporting
 * office's data, CC BY 4.0). It needs the person's own free key, entered in Settings; the key
 * stays on this phone. Two kinds of look: around the map (every five minutes or after moving
 * 4 km), and along the route while driving (a few looks over the next 90 km).
 */
@MainActor
final class FuelPrices {
    static let shared = FuelPrices()

    private(set) var stations: [FuelStation] = []
    private(set) var updatedAt = Date.distantPast
    private(set) var ahead: [FuelStation] = []
    private(set) var aheadAt = Date.distantPast
    /** Called on the main thread when a look brought new data. */
    var onChange: (() -> Void)?

    private var task: Task<Void, Never>?
    private var aheadTask: Task<Void, Never>?
    private var lastCenter: LatLng?
    private var lastType = ""
    private var aheadType = ""
    private var failedAt = Date.distantPast

    private nonisolated static let base = "https://creativecommons.tankerkoenig.de/json/list.php"

    private var ready: Bool {
        let s = AppSettings.shared
        return s.fuelOn && !s.fuelKey.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func refreshIfNeeded(center: CLLocationCoordinate2D) {
        guard ready, RoadEvents.covers(center), task == nil, Date().timeIntervalSince(failedAt) > 60 else { return }
        let s = AppSettings.shared
        let here = LatLng(center.latitude, center.longitude)
        let moved = lastCenter.map { $0.distance(to: here) > 4_000 } ?? true
        let stale = Date().timeIntervalSince(updatedAt) > 300
        guard moved || stale || lastType != s.fuelType else { return }
        let key = s.fuelKey.trimmingCharacters(in: .whitespaces), type = s.fuelType
        task = Task { [weak self] in
            let found = await Self.fetch(here, radius: 15, key: key, type: type)
            guard let self else { return }
            self.task = nil
            guard let found else { self.failedAt = Date(); return }
            self.stations = found
            self.updatedAt = Date()
            self.lastCenter = here
            self.lastType = type
            self.onChange?()
        }
    }

    /** While driving: stations near the route over the next ~90 km, asked again every eight minutes. */
    func refreshAhead(line: [LatLng], from along: Double) {
        guard ready, aheadTask == nil, Date().timeIntervalSince(failedAt) > 60 else { return }
        let s = AppSettings.shared
        guard Date().timeIntervalSince(aheadAt) > 480 || aheadType != s.fuelType else { return }
        let total = Geo.length(line)
        var points: [LatLng] = []
        var m = along + 3_000
        while m < min(total, along + 90_000) {
            let p = Geo.point(along: line, meters: m)
            if RoadEvents.covers(CLLocationCoordinate2D(latitude: p.lat, longitude: p.lng)) { points.append(p) }
            m += 30_000
        }
        guard !points.isEmpty else { aheadAt = Date(); ahead = []; return }
        let key = s.fuelKey.trimmingCharacters(in: .whitespaces), type = s.fuelType
        aheadTask = Task { [weak self] in
            var merged: [String: FuelStation] = [:]
            var failed = false
            for p in points {
                if let found = await Self.fetch(p, radius: 12, key: key, type: type) {
                    for st in found { merged[st.id] = st }
                } else {
                    failed = true
                }
            }
            guard let self else { return }
            self.aheadTask = nil
            if failed && merged.isEmpty { self.failedAt = Date(); return }
            self.ahead = Array(merged.values)
            self.aheadAt = Date()
            self.aheadType = type
            self.onChange?()
        }
    }

    /** The route changed: what was found for the old one doesn't apply. */
    func resetAhead() {
        ahead = []
        aheadAt = .distantPast
    }

    // MARK: Talking to the API

    private nonisolated static func fetch(_ p: LatLng, radius: Double, key: String, type: String) async -> [FuelStation]? {
        guard var comps = URLComponents(string: base) else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "lat", value: String(format: "%.4f", p.lat)),
            URLQueryItem(name: "lng", value: String(format: "%.4f", p.lng)),
            URLQueryItem(name: "rad", value: String(min(radius, 25))),
            URLQueryItem(name: "sort", value: "price"),
            URLQueryItem(name: "type", value: type),
            URLQueryItem(name: "apikey", value: key),
        ]
        guard let url = comps.url,
              let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (json["ok"] as? Bool) == true,
              let list = json["stations"] as? [[String: Any]] else { return nil }
        return list.compactMap { item -> FuelStation? in
            // A station that doesn't sell this fuel comes back with `false` instead of a price.
            guard let id = item["id"] as? String,
                  let price = item["price"] as? Double, price > 0.5,
                  let lat = item["lat"] as? Double, let lng = item["lng"] as? Double else { return nil }
            let house = (item["houseNumber"] as? String) ?? ""
            let street = ((item["street"] as? String) ?? "") + (house.isEmpty ? "" : " " + house)
            let post = (item["postCode"] as? String) ?? (item["postCode"] as? Int).map { String($0) } ?? ""
            let city = [post, (item["place"] as? String) ?? ""]
                .filter { !$0.isEmpty }.joined(separator: " ")
            return FuelStation(id: id,
                               brand: (item["brand"] as? String) ?? "",
                               name: (item["name"] as? String) ?? "",
                               street: street.trimmingCharacters(in: .whitespaces),
                               place: city,
                               location: LatLng(lat, lng),
                               price: price,
                               open: (item["isOpen"] as? Bool) ?? true)
        }
    }

    /** For the Settings button: does this key work? Asks about 5 km around the middle of Berlin. */
    nonisolated static func check(key: String) async -> String {
        let k = key.trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty else { return "Enter your key first." }
        guard var comps = URLComponents(string: base) else { return "Couldn't build the request." }
        comps.queryItems = [
            URLQueryItem(name: "lat", value: "52.5200"), URLQueryItem(name: "lng", value: "13.4050"),
            URLQueryItem(name: "rad", value: "5"), URLQueryItem(name: "sort", value: "price"),
            URLQueryItem(name: "type", value: "diesel"), URLQueryItem(name: "apikey", value: k),
        ]
        guard let url = comps.url, let (data, resp) = try? await URLSession.shared.data(from: url) else {
            return "No answer from Tankerkönig. Check your connection."
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return "Unexpected answer (code \((resp as? HTTPURLResponse)?.statusCode ?? 0))."
        }
        if (json["ok"] as? Bool) == true {
            let n = (json["stations"] as? [[String: Any]])?.count ?? 0
            return "The key works: \(n) stations found in the test area."
        }
        return (json["message"] as? String) ?? "The key was refused."
    }
}

/** Settings › Fuel prices. */
struct FuelSettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var result: String?
    @State private var checking = false

    private let types: [(String, String)] = [("diesel", "Diesel"), ("e5", "Super E5"), ("e10", "Super E10")]

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.fuelOn) { SettingLabel("Show fuel prices", icon: "fuelpump.fill", color: 0x2563EB) }
                Picker(selection: $settings.fuelType) {
                    ForEach(types, id: \.0) { Text($0.1).tag($0.0) }
                } label: { SettingLabel("Fuel", icon: "drop.fill", color: 0x0891B2) }
                Picker(selection: $settings.fuelCount) {
                    Text("Cheapest 3").tag(3)
                    Text("Cheapest 5").tag(5)
                    Text("Cheapest 10").tag(10)
                } label: { SettingLabel("Stations on the map", icon: "mappin.and.ellipse", color: 0x7C3AED) }
                Stepper(value: $settings.fuelTank, in: 20...120, step: 5) {
                    SettingLabel("Fill-up: \(settings.fuelTank) litres", icon: "gauge.with.needle.fill", color: 0x16A34A)
                }
            } footer: {
                Text("Shows the cheapest stations on the map and, while driving, the cheapest one on your route with what you'd save on a fill-up. Germany only.")
            }
            Section {
                SecureField("Tankerkönig API key", text: $settings.fuelKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    checking = true
                    result = nil
                    let key = settings.fuelKey
                    Task {
                        let text = await FuelPrices.check(key: key)
                        result = text
                        checking = false
                    }
                } label: {
                    HStack {
                        Text("Check the key")
                        if checking { Spacer(); ProgressView() }
                    }
                }
                .disabled(checking || settings.fuelKey.isEmpty)
                if let result { Text(result).font(.footnote).foregroundColor(.secondary) }
            } header: {
                Text("Your key")
            } footer: {
                Text("Free from creativecommons.tankerkoenig.de. The key stays on this phone. To find stations, your position (to about 10 m) goes to Tankerkönig. Prices: Tankerkönig / MTS-K, CC BY 4.0.")
            }
        }
        .kiteList()
        .navigationTitle("Fuel prices")
    }
}

/** The cheapest station nearby, on the map screen: a small pill just under the search bar. */
struct FuelChip: View {
    let station: FuelStation
    var meters: Double?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "fuelpump.fill").font(.system(size: 12)).foregroundColor(Color(hex: 0x16A34A))
                Text("\(station.priceText) €").font(.system(size: 14, weight: .bold)).monospacedDigit()
                Text([station.title, meters.map { Fmt.distance($0) }].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 12, weight: .medium)).foregroundColor(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 11).frame(height: 30)
            .glassButton(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/** While searching: the cheapest price as a small tall pill, to stand under the weather on the left. */
struct FuelMini: View {
    let station: FuelStation
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: "fuelpump.fill").font(.system(size: 14)).foregroundColor(Color(hex: 0x16A34A))
                Text(station.priceText).font(.system(size: 12, weight: .bold)).monospacedDigit()
            }
            .frame(width: 50, height: 52)
            .glassButton(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Cheapest fuel \(station.priceText) euro")
    }
}

/** A station tapped on the map. */
struct FuelCard: View {
    let station: FuelStation
    var meters: Double?
    let go: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "fuelpump.fill")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color(hex: 0x16A34A)))
            VStack(alignment: .leading, spacing: 3) {
                Text("\(station.priceText) €/l").font(.title2.weight(.heavy)).monospacedDigit()
                Text(station.title).font(.headline).lineLimit(1)
                Text([station.address, meters.map { Fmt.distance($0) }].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline).foregroundColor(.secondary).lineLimit(2)
                Button(action: go) {
                    Label("Directions", systemImage: "arrow.triangle.turn.up.right.circle.fill")
                        .font(.system(size: 15, weight: .bold))
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.secondary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .glass(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 16)
    }
}

/** While driving: the cheapest station just off the route. */
struct FuelAhead: Equatable {
    var station: FuelStation
    var meters: Double
    var offRoute: Double
    var saving: Double?
}

struct FuelAheadChip: View {
    let ahead: FuelAhead
    let hide: () -> Void

    var body: some View {
        Button(action: hide) {
            HStack(spacing: 6) {
                Image(systemName: "fuelpump.fill").font(.system(size: 12)).foregroundColor(Color(hex: 0x16A34A))
                Text("\(ahead.station.priceText) €").font(.system(size: 13, weight: .bold)).monospacedDigit()
                Text("\(ahead.station.title) · \(Fmt.distance(ahead.meters))")
                    .font(.system(size: 12, weight: .medium)).foregroundColor(.secondary).lineLimit(1)
                if let s = ahead.saving, s >= 1 {
                    Text("−\(String(format: "%.0f", s)) €").font(.system(size: 12, weight: .bold)).foregroundColor(Color(hex: 0x16A34A))
                }
            }
            .padding(.horizontal, 10).frame(height: 28)
            .glassButton(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Tap to hide")
    }
}
