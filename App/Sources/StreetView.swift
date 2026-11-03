import Foundation

/**
 * Google Street View, keyless: the same panorama lookup Google's own map pages use, a thumbnail
 * for the place page, and the image tiles the app's own viewer stitches into a 360° view.
 */
public enum StreetView {
    public struct Panorama: Equatable, Sendable {
        public var id: String
        public var location: LatLng
        /** Full size in pixels (width is twice height); older panoramas are smaller. */
        public var width = 16384
        public var height = 8192
        /** The compass direction at the middle of the image. */
        public var heading = 0.0

        public init(id: String, location: LatLng, width: Int = 16384, height: Int = 8192, heading: Double = 0) {
            self.id = id
            self.location = location
            self.width = width
            self.height = height
            self.heading = heading
        }

        /** Image size at [zoom] (0 to 5): each step down halves it. */
        public func size(zoom: Int) -> (width: Int, height: Int) {
            let f = 1 << max(0, 5 - zoom)
            return (width / f, height / f)
        }
    }

    /** Google retired the old GeoPhotoService.SingleImageSearch; its pages now ask this RPC. */
    static let searchEndpoint = URL(string: "https://maps.googleapis.com/$rpc/google.internal.maps.mapsjs.v1.MapsJsInternalService/SingleImageSearch")!

    public static func searchRequest(_ p: LatLng, radius: Int) -> URLRequest {
        var r = URLRequest(url: searchEndpoint)
        r.httpMethod = "POST"
        r.setValue("application/json+protobuf", forHTTPHeaderField: "Content-Type")
        let body = "[[\"apiv3\",null,null,null,\"US\",null,null,null,null,null,[[0]]],"
            + "[[null,null,\(p.lat),\(p.lng)],\(radius)],"
            + "[null,[\"en\",\"US\"],null,null,null,null,null,null,[2],null,[[[2,true,2]]]],"
            + "[[1,2,3,4,8,6]]]"
        r.httpBody = body.data(using: .utf8)
        return r
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 12
        c.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
            "Referer": "https://www.google.com/",
        ]
        return URLSession(configuration: c)
    }()

    /** The nearest Google panorama within [radius] meters, or nil. Official Street View only: not
     *  the photo spheres people upload (type 10), which are often indoors or years old. */
    public static func find(near p: LatLng, radius: Int = 60) async -> Panorama? {
        guard let (data, _) = try? await session.data(for: searchRequest(p, radius: radius)) else { return nil }
        return parse(String(decoding: data, as: UTF8.self))
    }

    /** Pulls the panorama id (Google's are 22 characters) and its position out of the reply. */
    static func parse(_ text: String) -> Panorama? {
        guard let idMatch = text.range(of: #"\[2,\s*"[A-Za-z0-9_-]{22}"\]"#, options: .regularExpression) else { return nil }
        let id = String(text[idMatch].filter { $0 != " " }.dropFirst(4).dropLast(2))
        guard let r = text.range(of: #"\[\[null,null,-?\d+\.\d+,\s*-?\d+\.\d+\]"#, options: .regularExpression) else { return nil }
        let nums = text[r].dropFirst(12).dropLast().split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard nums.count == 2 else { return nil }
        var pano = Panorama(id: id, location: LatLng(nums[0], nums[1]))
        // Its size follows the id: [2,2,[height,width],...
        let after = text[idMatch.upperBound...]
        if let m = after.range(of: #"^,\[\d+,\d+,\[\d+,\d+\]"#, options: .regularExpression) {
            let n = after[m].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            if n.count == 4, n[3] >= 1024 { pano.height = n[2]; pano.width = n[3] }
        }
        // Its heading follows the position: [[null,null,lat,lng],[altitude],[heading,tilt,roll]]
        let rest = text[r.upperBound...]
        if let m = rest.range(of: #"^,\[[^\]]*\],\[-?\d+(\.\d+)?"#, options: .regularExpression),
           let h = Double(rest[m].split(separator: "[").last ?? "") {
            pano.heading = h
        }
        return pano
    }

    /** One 512-pixel square of the panorama at [zoom]. */
    public static func tileURL(_ pano: Panorama, x: Int, y: Int, zoom: Int) -> URL {
        URL(string: "https://streetviewpixels-pa.googleapis.com/v1/tile?cb_client=maps_sv.tactile&panoid=\(pano.id)"
            + "&x=\(x)&y=\(y)&zoom=\(zoom)&nbt=1&fover=2")!
    }

    /** A still from the panorama, looking toward [heading]. */
    public static func thumbnailURL(_ pano: Panorama, heading: Double, width: Int = 640, height: Int = 360) -> URL {
        URL(string: "https://streetviewpixels-pa.googleapis.com/v1/thumbnail?panoid=\(pano.id)&cb_client=maps_sv.tactile.gps"
            + "&w=\(width)&h=\(height)&yaw=\(Int(heading.rounded()))&pitch=0&thumbfov=100")!
    }

}
