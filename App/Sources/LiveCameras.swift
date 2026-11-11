import SwiftUI

/** One still from a German motorway camera, when Autobahn GmbH is publishing it. */
struct HighwayCamera: Identifiable {
    let id: String
    let title: String
    let road: String
    let lat: Double
    let lng: Double
    let image: URL?
}

enum HighwayCameras {
    /// Roads that cover the middle of Germany, including the Magdeburg area. Asked together.
    private static let roads = ["A2", "A14", "A9", "A10", "A36", "A38", "A7", "A1", "A24"]

    static func load(near: LatLng?) async -> [HighwayCamera] {
        var found: [HighwayCamera] = []
        await withTaskGroup(of: [HighwayCamera].self) { group in
            for road in roads {
                group.addTask { await cameras(on: road) }
            }
            for await batch in group { found.append(contentsOf: batch) }
        }
        if let near {
            found.sort { $0.lat.distance(to: near, lng: $0.lng) < $1.lat.distance(to: near, lng: $1.lng) }
        }
        return found
    }

    private static func cameras(on road: String) async -> [HighwayCamera] {
        guard let url = URL(string: "https://verkehr.autobahn.de/o/autobahn/\(road)/services/webcam"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["webcam"] as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            let id = (item["identifier"] as? String) ?? UUID().uuidString
            let title = (item["title"] as? String) ?? road
            let coord = item["coordinate"] as? [String: Any]
            let lat = Double(coord?["lat"] as? String ?? "") ?? 0
            let lng = Double(coord?["long"] as? String ?? "") ?? 0
            let image = (item["imageurl"] as? String).flatMap(URL.init(string:))
                ?? (item["linkurl"] as? String).flatMap(URL.init(string:))
            return HighwayCamera(id: id, title: title, road: road, lat: lat, lng: lng, image: image)
        }
    }
}

private extension Double {
    func distance(to near: LatLng, lng: Double) -> Double {
        LatLng(self, lng).distance(to: near)
    }
}

/** The live-camera page. Photos only when the operator is actually sending them. */
struct LiveCamerasPage: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var cameras: [HighwayCamera] = []
    @State private var loading = true
    @State private var picked: HighwayCamera?

    var body: some View {
        List {
            Section {
                if loading {
                    HStack { ProgressView(); Text("Pytam Autobahn GmbH…") }
                } else if cameras.isEmpty {
                    Text("Autobahn GmbH nie publikuje teraz żadnego zdjęcia. Lista kamer na autostradach jest pusta po ich stronie, więc nie wstawiam tu cudzych obrazków.")
                        .font(.subheadline).foregroundColor(.secondary)
                } else {
                    ForEach(cameras) { cam in
                        Button { picked = cam } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(cam.title).font(.body.weight(.semibold)).foregroundColor(.primary)
                                Text(cam.road).font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("Autostrady w Niemczech")
            } footer: {
                Text("Zdjęcia pochodzą z otwartego serwisu Autobahn GmbH. To nie są fotoradary i nie ma ich na każdej drodze. Kamery z mapy (fotoradary, monitoring) zostają w „Kamery i prędkość”.")
            }
        }
        .kiteList()
        .navigationTitle("Kamery na żywo")
        .task { await reload() }
        .refreshable { await reload() }
        .sheet(item: $picked) { cam in
            LiveCameraShot(camera: cam)
        }
    }

    private func reload() async {
        loading = cameras.isEmpty
        let me = settings.home?.location
        cameras = await HighwayCameras.load(near: me)
        loading = false
    }
}

private struct LiveCameraShot: View {
    let camera: HighwayCamera
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                if let url = camera.image {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image): image.resizable().scaledToFit()
                        case .failure: Text("Operator nie dał zdjęcia.").foregroundColor(.secondary)
                        default: ProgressView()
                        }
                    }
                } else {
                    Text("Ta kamera jest na liście, ale Autobahn GmbH nie podaje do niej adresu zdjęcia.")
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                }
                Text(camera.title).font(.headline)
                Spacer()
            }
            .padding()
            .navigationTitle(camera.road)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Zamknij") { dismiss() } }
        }
    }
}
