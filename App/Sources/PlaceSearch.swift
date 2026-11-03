import Foundation

/** What the app calls: Google first (the full place cards), OpenStreetMap when Google fails. */
public enum PlaceSearch {
    public struct Result: Sendable {
        public var places: [Place]
        /** Set when Google failed and the open-data search answered instead. */
        public var googleError: String?
        public init(places: [Place], googleError: String? = nil) {
            self.places = places
            self.googleError = googleError
        }
    }

    public static func search(_ query: String, center: LatLng, spanMeters: Double?, useGoogle: Bool = true) async -> Result {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return Result(places: []) }
        var googleError: String?
        if useGoogle { do {
            let places = try await GoogleClient.shared.search(q, center: center, spanMeters: spanMeters)
            if !places.isEmpty { return Result(places: places) }
        } catch {
            googleError = error.localizedDescription
        } }
        if let pc = await Postcodes.lookup(q) { return Result(places: [pc], googleError: googleError) }
        let osm = (try? await Photon.search(q, near: center)) ?? []
        return Result(places: osm, googleError: googleError)
    }
}
