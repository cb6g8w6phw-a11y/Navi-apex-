import Foundation

struct TripStop: Codable, Equatable {
    var name: String
    var lat: Double
    var lng: Double
}

struct TripRecord: Identifiable, Codable, Equatable {
    var id: UUID
    var when: Date
    var name: String
    var placeId: String
    var lat: Double
    var lng: Double
    var mode: Int
    var drivenMeters: Double
    var seconds: Double
    var arrived: Bool
    var stops: [TripStop]

    var averageKmh: Double {
        guard seconds > 30 else { return 0 }
        return drivenMeters / seconds * 3.6
    }
}

struct DriveForecast: Equatable {
    var seconds: Double
    var depart: Date
    var arrive: Date
}

/// Kilometres, time and routes worth driving again. Kept on this phone.
@MainActor
final class TripLog: ObservableObject {
    static let shared = TripLog()
    @Published private(set) var trips: [TripRecord] = []
    private let key = "trip-log-v1"

    private init() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode([TripRecord].self, from: data) else { return }
        trips = saved
    }

    var drivenMeters: Double { trips.reduce(0) { $0 + $1.drivenMeters } }
    var seconds: Double { trips.reduce(0) { $0 + $1.seconds } }
    var averageKmh: Double { seconds > 60 ? drivenMeters / seconds * 3.6 : 0 }

    func add(_ trip: TripRecord) {
        trips.insert(trip, at: 0)
        if trips.count > 180 { trips.removeLast(trips.count - 180) }
        save()
    }

    func remove(at offsets: IndexSet) {
        trips.remove(atOffsets: offsets)
        save()
    }

    func clear() {
        trips = []
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(trips) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// Typical traffic at a chosen hour, from the open router. Not a live jam.
    static func forecast(from: LatLng, to: LatLng, via: [LatLng], kind: Int, when: Date,
                         avoidHighways: Bool, avoidTolls: Bool) async -> DriveForecast? {
        guard kind == 1 || kind == 2 else { return nil }
        let stamp = Self.stamp.string(from: when)
        let body: [String: Any] = [
            "locations": ([from] + via + [to]).map { ["lon": $0.lng, "lat": $0.lat, "type": "break"] },
            "costing": "auto",
            "date_time": ["type": kind == 2 ? 2 : 1, "value": stamp],
            "costing_options": ["auto": [
                "use_highways": avoidHighways ? 0.0 : 1.0,
                "use_tolls": avoidTolls ? 0.0 : 1.0,
            ]],
        ]
        guard let url = URL(string: "https://valhalla1.openstreetmap.de/route"),
              let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 18)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = payload
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let trip = root["trip"] as? [String: Any],
              let summary = trip["summary"] as? [String: Any],
              let time = Self.number(summary["time"]), time > 30 else { return nil }
        var depart = kind == 1 ? when : when.addingTimeInterval(-time)
        var arrive = kind == 2 ? when : when.addingTimeInterval(time)
        if let locations = trip["locations"] as? [[String: Any]],
           let raw = locations.first?["date_time"] as? String,
           let parsed = Self.stamp.date(from: String(raw.prefix(16))) {
            depart = parsed
            arrive = parsed.addingTimeInterval(time)
        }
        return DriveForecast(seconds: time, depart: depart, arrive: arrive)
    }

    private static func number(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        return nil
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f
    }()
}

enum TripClock {
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()
    static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

struct TripHistoryPage: View {
    @ObservedObject private var log = TripLog.shared
    var ride: (TripRecord) -> Void

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(log.trips.isEmpty ? "Brak jazd" : "\(Fmt.distance(log.drivenMeters)) · \(Fmt.duration(log.seconds))")
                        .font(.title3.weight(.bold))
                    Text(log.trips.isEmpty
                         ? "Pojawią się, gdy przejedziesz kawałek trasy."
                         : "Średnio \(Int(log.averageKmh.rounded())) km/h · \(log.trips.count) \(Self.word(log.trips.count))")
                        .font(.subheadline).foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }
            if !log.trips.isEmpty {
                Section("Do ponownego użycia") {
                    ForEach(log.trips) { trip in
                        Button { ride(trip) } label: { TripHistoryRow(trip: trip) }
                            .buttonStyle(.plain)
                    }
                    .onDelete(perform: log.remove)
                }
            }
        }
        .kiteList()
        .navigationTitle("Historia jazd")
        .toolbar {
            if !log.trips.isEmpty {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Wyczyść") { log.clear() }
                }
            }
        }
    }

    private static func word(_ n: Int) -> String {
        let teen = (n % 100) / 10 == 1
        if n == 1 { return "trasa" }
        if !teen, (2...4).contains(n % 10) { return "trasy" }
        return "tras"
    }
}

private struct TripHistoryRow: View {
    let trip: TripRecord

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .bold))
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.secondary.opacity(0.15)))
            VStack(alignment: .leading, spacing: 2) {
                Text(trip.name).font(.body.weight(.semibold)).lineLimit(1)
                Text("\(TripClock.day.string(from: trip.when)) · \(trip.arrived ? "na miejscu" : "przerwana")")
                    .font(.caption).foregroundColor(.secondary).lineLimit(1)
                Text("\(Fmt.distance(trip.drivenMeters)) · \(Fmt.duration(trip.seconds)) · \(Int(trip.averageKmh.rounded())) km/h")
                    .font(.caption.weight(.medium))
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.clockwise").foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var icon: String {
        switch trip.mode {
        case 1: return "bicycle"
        case 2: return "figure.walk"
        default: return "car.fill"
        }
    }
}
