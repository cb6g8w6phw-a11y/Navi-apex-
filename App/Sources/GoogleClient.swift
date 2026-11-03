import Foundation

/**
 * Keyless Google Maps web search, the way Vela's Android extractor does it: warm a session
 * once (cookies), then call `/search?tbm=map` with Vela's `pb` and a desktop Chrome header set.
 * No key and no account. EU consent cookies are pre-seeded so no consent wall appears.
 */
public actor GoogleClient {
    public static let shared = GoogleClient()

    static let userAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/156.0.0.0 Safari/537.36"
    static let secChUa = #""Not:A-Brand";v="8", "Chromium";v="156", "Google Chrome";v="156""#
    static let searchEndpoint = "https://www.google.com/search?tbm=map&authuser=0&hl=en-GB&gl=gb"
    static let directionsEndpoint = "https://www.google.com/maps/preview/directions?authuser=0&hl=en-GB&gl=gb"
    static let suggestEndpoint = "https://www.google.com/s?tbm=map&gs_ri=maps&suggest=p&authuser=0&hl=en-GB&gl=gb"
    static let suggestPb = "!2i5!4m12!1m3!1d{SPAN}!2d{LNG}!3d{LAT}!2m3!1f0!2f0!3f0!3m2!1i1024!2i768!4f13.1"
        + "!7i20!10b1!12m6!1m2!18b1!30b1!2m2!1i203!2i100!19m4!1m3!1i1!2i1!3i1!20m1!1e1"
    static let sessionWarmUrl = "https://www.google.com/maps?hl=en-GB&gl=gb"

    private let session: URLSession
    private var warmed = false

    public init() {
        let cfg = URLSessionConfiguration.ephemeral
        let cookies = cfg.httpCookieStorage ?? HTTPCookieStorage.shared
        for name in [("SOCS", "CAESHAgBEhIaAB"), ("CONSENT", "YES+")] {
            if let c = HTTPCookie(properties: [
                .domain: ".google.com", .path: "/", .name: name.0, .value: name.1, .secure: "TRUE",
                .expires: Date().addingTimeInterval(365 * 86_400),
            ]) { cookies.setCookie(c) }
        }
        cfg.httpCookieAcceptPolicy = .always
        cfg.timeoutIntervalForRequest = 15
        session = URLSession(configuration: cfg)
    }

    /** Search Google around [center]. [spanMeters] is how wide the visible map is. A full first
     *  page (a category like "restaurants") fetches pages two and three too, as Vela does. */
    public func search(_ query: String, center: LatLng, spanMeters: Double?, pages: Int = 3) async throws -> [Place] {
        try await warm()
        let first = try await page(query, center: center, spanMeters: spanMeters, offset: 0)
        guard pages > 1, first.count >= 18 else { return first }
        var more: [Int: [Place]] = [:]
        await withTaskGroup(of: (Int, [Place]).self) { group in
            for i in 1..<pages {
                group.addTask { (i, (try? await self.page(query, center: center, spanMeters: spanMeters, offset: 20 * i)) ?? []) }
            }
            for await (i, p) in group { more[i] = p }
        }
        // Pages in Google's order, as they'd come scrolling down Google Maps' list.
        var seen = Set(first.map(\.id))
        let extra = (1..<pages).flatMap { more[$0] ?? [] }.filter { seen.insert($0.id).inserted }
        return first + extra
    }

    private func page(_ query: String, center: LatLng, spanMeters: Double?, offset: Int) async throws -> [Place] {
        let pb = SearchPb.build(query: query, center: center, spanMeters: spanMeters, offset: offset)
        let url = URL(string: Self.searchEndpoint + "&q=" + enc(query) + "&pb=" + enc(pb))!
        let body = try await get(url, referer: "https://www.google.com/", xhr: true)
        guard let root = GoogleJSON.parse(body) else { throw VelaError.unexpectedResponse(String(body.prefix(200))) }
        return SearchParser.parse(root: root, near: center)
    }

    private var ech = 0

    /** Google's autocomplete while typing: places with a position, and suggested searches. */
    public func suggest(_ query: String, near: LatLng, spanMeters: Double = 20_000) async throws -> SuggestParser.Result {
        try await warm()
        ech += 1
        let span = min(max(spanMeters, 2_000), 500_000)
        let pb = Self.suggestPb.replacingOccurrences(of: "{SPAN}", with: String(span))
            .replacingOccurrences(of: "{LNG}", with: String(near.lng))
            .replacingOccurrences(of: "{LAT}", with: String(near.lat))
        let url = URL(string: Self.suggestEndpoint + "&pb=" + enc(pb) + "&q=" + enc(query) + "&tch=1&ech=\(ech)")!
        let body = try await get(url, referer: "https://www.google.com/", xhr: true)
        return SuggestParser.parse(body, near: near)
    }

    /** Driving, cycling or walking routes with live traffic times, alternates first-to-last. */
    public func directions(from origin: LatLng, to destination: LatLng, mode: TravelMode,
                           avoidHighways: Bool = false, avoidTolls: Bool = false, via: [LatLng] = []) async throws -> [Route] {
        let body = try await directionsBody(from: origin, to: destination, mode: mode,
                                            avoidHighways: avoidHighways, avoidTolls: avoidTolls, via: via)
        guard let root = GoogleJSON.parse(body) else { throw VelaError.unexpectedResponse(String(body.prefix(200))) }
        return DirectionsParser.parse(root: root, mode: mode)
    }

    /** Google's raw answer for a route, before parsing: for the probe looking into what else it holds. */
    public func directionsBody(from origin: LatLng, to destination: LatLng, mode: TravelMode,
                               avoidHighways: Bool = false, avoidTolls: Bool = false, via: [LatLng] = []) async throws -> String {
        try await warm()
        let pb = DirectionsPb.build(origin: origin, destination: destination, mode: mode,
                                    avoidHighways: avoidHighways, avoidTolls: avoidTolls, waypoints: via)
        let url = URL(string: Self.directionsEndpoint + "&pb=" + enc(pb))!
        return try await get(url, referer: "https://www.google.com/", xhr: true)
    }

    private func warm() async throws {
        if warmed { return }
        // Only counts once Google answered: opened with no signal, try again on the next search.
        if (try? await get(URL(string: Self.sessionWarmUrl)!, referer: nil, xhr: false)) != nil { warmed = true }
    }

    private func get(_ url: URL, referer: String?, xhr: Bool) async throws -> String {
        var r = URLRequest(url: url)
        r.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue(xhr ? "*/*" : "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
                   forHTTPHeaderField: "Accept")
        r.setValue(Self.acceptLanguage, forHTTPHeaderField: "Accept-Language")
        r.setValue(Self.secChUa, forHTTPHeaderField: "Sec-CH-UA")
        r.setValue("?0", forHTTPHeaderField: "Sec-CH-UA-Mobile")
        r.setValue("\"Windows\"", forHTTPHeaderField: "Sec-CH-UA-Platform")
        r.setValue(xhr ? "empty" : "document", forHTTPHeaderField: "Sec-Fetch-Dest")
        r.setValue(xhr ? "cors" : "navigate", forHTTPHeaderField: "Sec-Fetch-Mode")
        r.setValue(xhr ? "same-origin" : "none", forHTTPHeaderField: "Sec-Fetch-Site")
        if let referer { r.setValue(referer, forHTTPHeaderField: "Referer") }
        let (data, resp) = try await session.data(for: r)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw VelaError.http(http.statusCode)
        }
        return String(decoding: data, as: UTF8.self)
    }

    // Matches the hl=en-GB in the URL: English words, British ones ("Car park", not "Parking lot").
    private static let acceptLanguage = "en-GB,en;q=0.9"

    private func enc(_ s: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

public enum VelaError: Error, LocalizedError {
    case http(Int)
    case unexpectedResponse(String)

    public var errorDescription: String? {
        switch self {
        case .http(let code): return "The server answered with error \(code)."
        case .unexpectedResponse: return "The search answer came back in a shape Vela doesn't understand."
        }
    }
}
