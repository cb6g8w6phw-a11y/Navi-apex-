import Foundation

/**
 * Every police report Kite has seen from Waze, kept on this phone for the heat map. Waze only
 * shares what's live right now, so the map of where police usually are builds up as you use Kite.
 */
@MainActor
final class WazeHistory {
    static let shared = WazeHistory()

    struct Sighting: Codable {
        var id: String
        var lat: Double
        var lng: Double
        var t: Date
    }

    private(set) var sightings: [Sighting] = []
    private var ids: Set<String> = []
    private let file: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("waze-police.json")
    /** Called after new reports are added, so the map can redraw the heat map. */
    var onChange: (() -> Void)?
    /** Kept for 90 days, at most this many. */
    private let limit = 6000

    private init() {
        if let file, let data = try? Data(contentsOf: file),
           let list = try? JSONDecoder().decode([Sighting].self, from: data) {
            let cutoff = Date().addingTimeInterval(-90 * 86_400)
            sightings = list.filter { $0.t > cutoff }
            ids = Set(sightings.map(\.id))
        }
    }

    /** For the risk score. */
    var reports: [PoliceRisk.Report] {
        sightings.map { PoliceRisk.Report(LatLng($0.lat, $0.lng), $0.t) }
    }

    /** Adds the police reports not seen before. True when anything was added. */
    @discardableResult
    func record(_ alerts: [WazeAlert]) -> Bool {
        let fresh = alerts.filter { $0.kind == .police && !ids.contains($0.id) }
        guard !fresh.isEmpty else { return false }
        for a in fresh {
            sightings.append(Sighting(id: a.id, lat: a.location.lat, lng: a.location.lng, t: a.reportedAt))
            ids.insert(a.id)
        }
        if sightings.count > limit {
            sightings.removeFirst(sightings.count - limit)
            ids = Set(sightings.map(\.id))
        }
        save()
        onChange?()
        return true
    }

    /** Forget every remembered report (Settings › Road alerts). */
    func clear() {
        sightings = []
        ids = []
        save()
    }

    private var sweptAt = Date.distantPast
    private var sweeping = false

    /**
     * While Kite is open, every 10 minutes, also asks Waze about the areas around [places] (where
     * you are, home, work), so the heat map and risk fill in faster than from what's on screen.
     */
    func sweepIfDue(_ places: [LatLng]) {
        guard !sweeping, Date().timeIntervalSince(sweptAt) > 600, !places.isEmpty else { return }
        sweeping = true
        sweptAt = Date()
        Task {
            for p in places.prefix(4) {
                let d = 0.12
                if let found = await Waze.alerts(south: p.lat - d, west: p.lng - d * 1.6, north: p.lat + d, east: p.lng + d * 1.6) {
                    record(found)
                }
            }
            sweeping = false
        }
    }

    private func save() {
        guard let file, let data = try? JSONEncoder().encode(sightings) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
