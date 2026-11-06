import CoreLocation
import Foundation
import SwiftUI
import UIKit

/** A closure the driver reported. It lives in Apex and steers that kind of route around the spot. */
struct UserClosure: Codable, Equatable, Identifiable {
    var id: String
    var lat: Double
    var lng: Double
    /// "drive" or "bike".
    var mode: String
    var at: Date

    var location: LatLng { LatLng(lat, lng) }
}

/**
 * Reports made in Apex. Google, Apple and Waze do not take closures from another app,
 * so these stay here and only change Apex's own map and routes.
 */
@MainActor
final class ClosureBoard: ObservableObject {
    static let shared = ClosureBoard()
    @Published private(set) var items: [UserClosure] = []
    private(set) var revision = 0
    var onChange: (() -> Void)?
    /// Read by route planning off the main actor's task. Written only from here.
    nonisolated(unsafe) private static var snapshot: [UserClosure] = []

    private let key = "userClosures"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([UserClosure].self, from: data) {
            items = list
        }
        Self.snapshot = items
    }

    func add(at p: LatLng, mode: TravelMode) {
        let kind = mode == .bike ? "bike" : "drive"
        if let i = items.firstIndex(where: { $0.mode == kind && $0.location.distance(to: p) < 40 }) {
            items[i].lat = p.lat
            items[i].lng = p.lng
            items[i].at = Date()
        } else {
            items.insert(UserClosure(id: "user-\(UUID().uuidString)", lat: p.lat, lng: p.lng, mode: kind, at: Date()), at: 0)
            if items.count > 40 { items = Array(items.prefix(40)) }
        }
        store()
    }

    func remove(_ id: String) {
        items.removeAll { $0.id == id }
        store()
    }

    func asEvents(for mode: TravelMode) -> [RoadEvent] {
        let kind = mode == .bike ? "bike" : mode == .drive ? "drive" : ""
        guard !kind.isEmpty else { return [] }
        return items.filter { $0.mode == kind }.map { c in
            let bike = c.mode == "bike"
            return RoadEvent(id: c.id, kind: .closure, road: bike ? "Rower" : "Auto",
                             title: bike ? "Ścieżka zamknięta" : "Droga zamknięta",
                             subtitle: "Twoje zgłoszenie",
                             details: ["Apex omija to przy trasie dla \(bike ? "roweru" : "auta")."],
                             location: c.location, blocked: true, extent: nil)
        }
    }

    func event(id: String) -> RoadEvent? {
        guard let c = items.first(where: { $0.id == id }) else { return nil }
        let bike = c.mode == "bike"
        return RoadEvent(id: c.id, kind: .closure, road: bike ? "Rower" : "Auto",
                         title: bike ? "Ścieżka zamknięta" : "Droga zamknięta",
                         subtitle: "Twoje zgłoszenie",
                         details: ["Apex omija to przy trasie dla \(bike ? "roweru" : "auta")."],
                         location: c.location, blocked: true, extent: nil)
    }

    /// Drops routes that pass a reported closure, when some other route stays clear.
    nonisolated static func prefer(_ routes: [Route], mode: TravelMode) -> [Route] {
        let kind = mode == .bike ? "bike" : mode == .drive ? "drive" : ""
        let pts = snapshot.filter { $0.mode == kind }.map { LatLng($0.lat, $0.lng) }
        guard !pts.isEmpty else { return routes }
        let clear = routes.filter { route in
            route.polyline.count >= 2 && !pts.contains { b in Geo.project(b, on: route.polyline).offset < 70 }
        }
        return clear.isEmpty ? routes : clear
    }

    private func store() {
        revision += 1
        Self.snapshot = items
        if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: key) }
        onChange?()
    }
}

/** Report a closed road or path from where you are, and open the same spot in the other maps. */
struct ClosureReportSheet: View {
    var at: LatLng?
    var dismiss: () -> Void
    @ObservedObject private var board = ClosureBoard.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Zgłoś zamknięcie").font(.system(size: 22, weight: .heavy))
                Spacer()
                Button("Gotowe", action: dismiss).font(.system(size: 17, weight: .semibold))
            }
            if let at {
                Text(String(format: "Tu gdzie jesteś · %.5f, %.5f", at.lat, at.lng))
                    .font(.subheadline).foregroundColor(.secondary)
                HStack(spacing: 10) {
                    choice("Dla aut", icon: "car.fill", mode: .drive, at: at)
                    choice("Dla rowerów", icon: "bicycle", mode: .bike, at: at)
                }
                Text("Zapisuje się na mapie Apexa i trasa tego typu omija ten punkt. Google, Apple i Waze nie przyjmują zgłoszeń z innej aplikacji. Możesz otworzyć to miejsce i zgłosić je tam.")
                    .font(.footnote).foregroundColor(.secondary)
                HStack(spacing: 8) {
                    link("Google", url: "https://www.google.com/maps/search/?api=1&query=\(at.lat),\(at.lng)")
                    link("Apple", url: "http://maps.apple.com/?ll=\(at.lat),\(at.lng)&q=Zamkniecie")
                    link("Waze", url: "https://waze.com/ul?ll=\(at.lat),\(at.lng)&navigate=no")
                }
            } else {
                Text("Jeszcze nie ma pozycji GPS. Wyjdź spod dachu i spróbuj jeszcze raz.")
                    .foregroundColor(.secondary)
            }
            if !board.items.isEmpty {
                Text("Twoje zgłoszenia").font(.subheadline.weight(.semibold))
                ForEach(board.items) { c in
                    HStack {
                        Image(systemName: c.mode == "bike" ? "bicycle" : "car.fill")
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.mode == "bike" ? "Ścieżka zamknięta" : "Droga zamknięta")
                                .font(.subheadline.weight(.semibold))
                            Text(c.at.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Usuń") { ClosureBoard.shared.remove(c.id) }
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }
            Spacer(minLength: 8)
        }
        .padding(20)
        }
        .background(Vela.sheet(scheme).ignoresSafeArea())
        .presentationDetents([.medium, .large])
    }

    private func choice(_ title: String, icon: String, mode: TravelMode, at: LatLng) -> some View {
        Button {
            ClosureBoard.shared.add(at: at, mode: mode)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } label: {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 26, weight: .bold))
                Text(title).font(.system(size: 16, weight: .bold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 88)
            .foregroundColor(.primary)
            .glass(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func link(_ title: String, url: String) -> some View {
        Button {
            if let u = URL(string: url) { UIApplication.shared.open(u) }
        } label: {
            Text(title)
                .font(.system(size: 14, weight: .bold))
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .foregroundColor(.primary)
                .glassButton(Capsule())
        }
        .buttonStyle(.plain)
    }
}
