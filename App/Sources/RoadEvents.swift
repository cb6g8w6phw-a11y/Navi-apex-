import CoreLocation
import Foundation
import SwiftUI

/** One roadworks site, closure or traffic warning from the German motorway authority (Autobahn GmbH). */
struct RoadEvent: Identifiable, Equatable {
    enum Kind { case roadworks, closure, warning }

    let id: String
    let kind: Kind
    let road: String
    let title: String
    let subtitle: String
    let details: [String]
    let location: LatLng
    let blocked: Bool
    /** The box the event covers (west, south, east, north), when the API gives one. */
    let extent: (w: Double, s: Double, e: Double, n: Double)?

    static func == (a: RoadEvent, b: RoadEvent) -> Bool { a.id == b.id }

    var iconName: String {
        switch kind {
        case .roadworks: return "road-works"
        case .closure: return "road-closure"
        case .warning: return "road-warning"
        }
    }

    var symbol: String {
        switch kind {
        case .roadworks: return "wrench.and.screwdriver.fill"
        case .closure: return "nosign"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch kind {
        case .roadworks: return Color(hex: 0xF59E0B)
        case .closure: return Color(hex: 0xDC2626)
        case .warning: return Color(hex: 0xEF6C00)
        }
    }

    /** The card's colour while driving: deep enough for white text. */
    var cardColor: Color {
        switch kind {
        case .roadworks: return Color(hex: 0xC26A00)
        case .closure: return Color(hex: 0xB3261E)
        case .warning: return Color(hex: 0xC2410C)
        }
    }

    var kindName: String {
        switch kind {
        case .roadworks: return blocked ? "Roadworks, road blocked" : "Roadworks"
        case .closure: return "Closure"
        case .warning: return "Traffic warning"
        }
    }
}

/**
 * Live roadworks, closures and warnings on German motorways, from the open Autobahn API
 * (verkehr.autobahn.de, no key needed). The API has no "near me" question, only one list per
 * motorway, so Kite asks for every motorway once, remembers which ones have anything within
 * about 80 km of you, and afterwards refreshes only those every five minutes.
 */
@MainActor
final class RoadEvents {
    static let shared = RoadEvents()

    private(set) var events: [RoadEvent] = []
    private(set) var updatedAt = Date.distantPast
    /** Called on the main thread when a refresh brought new data. */
    var onChange: (() -> Void)?

    private var roads: [String] = []
    private var activeRoads: [String] = []
    private var byRoad: [String: [RoadEvent]] = [:]
    private var fullCenter: CLLocationCoordinate2D?
    private var fullAt = Date.distantPast
    private var failedAt = Date.distantPast
    private var task: Task<Void, Never>?

    private nonisolated static let base = "https://verkehr.autobahn.de/o/autobahn"

    /** The API only covers Germany. */
    static func covers(_ c: CLLocationCoordinate2D) -> Bool {
        c.latitude > 47.2 && c.latitude < 55.1 && c.longitude > 5.8 && c.longitude < 15.1
    }

    func refreshIfNeeded(center: CLLocationCoordinate2D) {
        guard Self.covers(center), task == nil, Date().timeIntervalSince(failedAt) > 60 else { return }
        let farFromFull = fullCenter.map { LatLng(center.latitude, center.longitude).distance(to: LatLng($0.latitude, $0.longitude)) > 60_000 } ?? true
        let fullStale = Date().timeIntervalSince(fullAt) > 3600
        let fresh = Date().timeIntervalSince(updatedAt) < 300
        if fresh && !farFromFull && !fullStale { return }
        let full = farFromFull || fullStale || activeRoads.isEmpty
        task = Task { [weak self] in await self?.run(center: center, full: full) }
    }

    private func run(center: CLLocationCoordinate2D, full: Bool) async {
        defer { task = nil }
        var ids = activeRoads
        if full {
            if let list = await Self.fetchRoads(), !list.isEmpty { roads = list }
            ids = roads
        }
        guard !ids.isEmpty else { failedAt = Date(); return }

        var fetched: [String: [RoadEvent]] = [:]
        var failures = 0
        var index = 0
        while index < ids.count {
            let chunk = Array(ids[index..<min(index + 6, ids.count)])
            index += 6
            await withTaskGroup(of: (String, [RoadEvent]?).self) { group in
                for road in chunk {
                    group.addTask {
                        var all: [RoadEvent] = []
                        for kind in [RoadEvent.Kind.warning, .closure, .roadworks] {
                            guard let part = await Self.fetch(road: road, kind: kind) else { return (road, nil) }
                            all += part
                        }
                        return (road, all)
                    }
                }
                for await (road, list) in group {
                    if let list { fetched[road] = list } else { failures += 1 }
                }
            }
            if Task.isCancelled { return }
        }
        guard !fetched.isEmpty else { failedAt = Date(); return }

        for (road, list) in fetched { byRoad[road] = list }
        events = byRoad.values.flatMap { $0 }
        updatedAt = Date()
        if full {
            fullCenter = center
            fullAt = Date()
            let here = LatLng(center.latitude, center.longitude)
            activeRoads = fetched.filter { _, list in list.contains { $0.location.distance(to: here) < 80_000 } }.map(\.key)
        }
        onChange?()
    }

    // MARK: Talking to the API

    private nonisolated static func get(_ path: String) async -> [String: Any]? {
        guard let url = URL(string: base + path) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private nonisolated static func fetchRoads() async -> [String]? {
        await get("/")?["roads"] as? [String]
    }

    private nonisolated static func number(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let s = v as? String { return Double(s) }
        if let i = v as? Int { return Double(i) }
        return nil
    }

    private nonisolated static func flag(_ v: Any?) -> Bool {
        if let b = v as? Bool { return b }
        if let s = v as? String { return s.lowercased() == "true" }
        return false
    }

    /** The API writes the box as "west,south,east,north" in one string. */
    private nonisolated static func extent(_ v: Any?) -> (w: Double, s: Double, e: Double, n: Double)? {
        guard let text = v as? String else { return nil }
        let p = text.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard p.count == 4 else { return nil }
        return (min(p[0], p[2]), min(p[1], p[3]), max(p[0], p[2]), max(p[1], p[3]))
    }

    /** nil when the request failed; an empty list when the motorway just has nothing listed. */
    private nonisolated static func fetch(road: String, kind: RoadEvent.Kind) async -> [RoadEvent]? {
        let (path, key): (String, String)
        switch kind {
        case .roadworks: (path, key) = ("roadworks", "roadworks")
        case .closure: (path, key) = ("closure", "closure")
        case .warning: (path, key) = ("warning", "warning")
        }
        guard let json = await get("/\(road)/services/\(path)") else { return nil }
        let list = json[key] as? [[String: Any]] ?? []
        return list.compactMap { item -> RoadEvent? in
            // Roadworks that start later are not on the road yet.
            if flag(item["future"]) { return nil }
            guard let id = item["identifier"] as? String,
                  let c = item["coordinate"] as? [String: Any],
                  let lat = number(c["lat"]), let lng = number(c["long"]) else { return nil }
            let details = (item["description"] as? [String] ?? []).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            return RoadEvent(id: id, kind: kind, road: road,
                             title: item["title"] as? String ?? road,
                             subtitle: item["subtitle"] as? String ?? "",
                             details: details,
                             location: LatLng(lat, lng),
                             blocked: flag(item["isBlocked"]) || kind == .closure,
                             extent: extent(item["extent"]))
        }
    }
}

/** The small card when you tap a roadworks sign on the map. */
struct RoadEventCard: View {
    let event: RoadEvent
    let close: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoadSign(kind: event.kind, size: 40)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.kindName)
                    .font(.subheadline.weight(.bold))
                    .foregroundColor(event.color)
                Text(event.title).font(.headline).lineLimit(2)
                if !event.subtitle.isEmpty {
                    Text(event.subtitle).font(.subheadline).foregroundColor(.secondary).lineLimit(2)
                }
                ForEach(Array(event.details.prefix(3).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.footnote).foregroundColor(.secondary).lineLimit(2)
                }
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

/** The sign itself, as on the road: a closed road is the red disc with the bar, the rest are triangles. */
struct RoadSign: View {
    let kind: RoadEvent.Kind
    var size: CGFloat = 34

    private struct Triangle: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: r.midX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            p.closeSubpath()
            return p
        }
    }

    var body: some View {
        Group {
            if kind == .closure {
                ZStack {
                    Circle().fill(Color.white)
                    Circle().fill(Color(hex: 0xD32F2F)).padding(size * 0.1)
                    RoundedRectangle(cornerRadius: size * 0.04)
                        .fill(Color.white)
                        .frame(width: size * 0.5, height: size * 0.17)
                }
            } else {
                ZStack {
                    Triangle()
                        .fill(kind == .roadworks ? Color(hex: 0xFFC400) : Color.white)
                        .padding(size * 0.12)
                    Triangle()
                        .stroke(Color(hex: 0xD32F2F), style: StrokeStyle(lineWidth: size * 0.12, lineJoin: .round))
                        .padding(size * 0.12)
                    Image(systemName: kind == .roadworks ? "wrench.and.screwdriver.fill" : "exclamationmark")
                        .font(.system(size: size * 0.34, weight: .heavy))
                        .foregroundColor(Color(hex: 0x1F1F1F))
                        .offset(y: size * 0.14)
                }
            }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
    }
}

/** While driving: roadworks, a closure or a warning ahead. The sign pops in with a bounce, then a thin bar counts the distance down. */
struct RoadAheadCard: View {
    let ahead: RoadAhead
    var offer: DetourOffer?
    let take: () -> Void
    let hide: () -> Void
    @State private var shown = false

    private var headline: String {
        if let left = ahead.left { return "\(Fmt.distance(left)) left" }
        return Fmt.distance(ahead.meters)
    }

    private var name: String {
        var text: String
        switch ahead.event.kind {
        case .roadworks: text = ahead.event.blocked ? "Roadworks, blocked" : "Roadworks"
        case .closure: text = "Road closed"
        case .warning: text = "Warning"
        }
        if ahead.left == nil, ahead.length >= 150 { text += " · \(Fmt.distance(ahead.length)) long" }
        return text
    }

    /** How much of the way to the start is behind you. */
    private var progress: Double {
        if ahead.left != nil { return 1 }
        return min(max(1 - ahead.meters / max(ahead.startMeters, 1), 0), 1)
    }

    var body: some View {
        let e = ahead.event
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                RoadSign(kind: e.kind, size: 36)
                    .scaleEffect(shown ? 1 : 0.2)
                    .rotationEffect(.degrees(shown ? 0 : -25))
                    .animation(.interpolatingSpring(stiffness: 160, damping: 7).delay(0.08), value: shown)
                VStack(alignment: .leading, spacing: 0) {
                    Text(headline)
                        .font(.system(size: 20, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                    Text(name)
                        .font(.system(size: 12, weight: .semibold))
                        .opacity(0.92)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Button(action: hide) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).frame(width: 26, height: 26)
                        .background(Circle().fill(Color.white.opacity(0.18)))
                }
                .buttonStyle(.plain)
            }
            Capsule()
                .fill(Color.white.opacity(0.25))
                .frame(height: 3)
                .overlay(alignment: .leading) {
                    GeometryReader { g in
                        Capsule().fill(Color.white).frame(width: g.size.width * progress)
                    }
                }
                .animation(.linear(duration: 0.4), value: progress)
            if let offer {
                let minutes = Int((abs(offer.extraSeconds) / 60).rounded())
                let cost = offer.extraSeconds >= 60 ? "+\(minutes) min" : offer.extraSeconds <= -60 ? "−\(minutes) min" : "same time"
                Button(action: take) {
                    Label("Detour · \(cost)", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                        .font(.system(size: 14, weight: .bold))
                        .frame(maxWidth: .infinity).frame(height: 30)
                        .background(Capsule().fill(Color.white))
                        .foregroundColor(e.cardColor)
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundColor(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(e.cardColor.opacity(0.96))
                .shadow(color: e.cardColor.opacity(0.45), radius: 10, y: 4)
        )
        .padding(.horizontal, 40)
        .onAppear { shown = true }
        .accessibilityElement(children: .contain)
    }
}
