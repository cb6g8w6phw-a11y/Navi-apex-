import MapKit
import UIKit

/** Display link target that is not isolated, so the wave can tick without rebuilding the route. */
final class WavePump: NSObject {
    var tick: (() -> Void)?
    @objc func fire() { tick?() }
}

/**
 * The whole navigation line, from the first point to the pin.
 * One overlay for the life of the route. Progress, the grey tail and the traffic wave
 * are painted again in place. The overlay is not removed and not rebuilt, so the stroke
 * cannot vanish for a frame and start over.
 */
final class RouteRibbon: NSObject, MKOverlay {
    let routeId: UUID
    let line: [LatLng]
    let cum: [Double]
    let mapPoints: [MKMapPoint]
    var traveled: Double = 0
    var live = false
    var spans: [(a: Double, b: Double, level: Int)] = []
    var phase: CGFloat = 0
    /// The picked route is one of the quicker ones. A slower pick is drawn light red.
    var good = true
    let boundingMapRect: MKMapRect
    let coordinate: CLLocationCoordinate2D

    init(route: Route) {
        routeId = route.id
        line = route.polyline
        cum = Geo.cumulative(route.polyline)
        mapPoints = route.polyline.map { MKMapPoint(CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng)) }
        spans = route.trafficSpans.map { s in
            (max(0, s.startMeters), s.startMeters + max(0, s.lengthMeters), min(max(s.level, 1), 3))
        }
        var rect = MKMapRect.null
        for p in mapPoints {
            let bit = MKMapRect(origin: p, size: MKMapSize(width: 1, height: 1))
            rect = rect.isNull ? bit : rect.union(bit)
        }
        boundingMapRect = rect.isNull ? .world : rect.insetBy(dx: -4_000, dy: -4_000)
        let mid = line.isEmpty ? LatLng(0, 0) : Geo.point(along: line, meters: (cum.last ?? 0) * 0.5, cumulative: cum)
        coordinate = CLLocationCoordinate2D(latitude: mid.lat, longitude: mid.lng)
        super.init()
    }

    var total: Double { cum.last ?? 0 }

    func mapPoint(at meters: Double) -> MKMapPoint {
        guard mapPoints.count >= 2, cum.count == mapPoints.count else { return mapPoints.first ?? MKMapPoint() }
        let m = min(max(0, meters), total)
        var i = 1
        while i < cum.count - 1 && cum[i] < m { i += 1 }
        let a = cum[i - 1], b = cum[i]
        let f = b > a + 0.01 ? (m - a) / (b - a) : 0
        let p = mapPoints[i - 1], q = mapPoints[i]
        return MKMapPoint(x: p.x + (q.x - p.x) * f, y: p.y + (q.y - p.y) * f)
    }

    /// Vertex range covering meters a...b, including both ends.
    func indices(from a: Double, to b: Double) -> (Int, Int)? {
        guard cum.count >= 2, b > a + 0.5 else { return nil }
        var i0 = 0
        while i0 < cum.count - 1 && cum[i0 + 1] < a { i0 += 1 }
        var i1 = i0 + 1
        while i1 < cum.count - 1 && cum[i1] < b { i1 += 1 }
        return (i0, i1)
    }
}

final class RouteRibbonRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let ribbon = overlay as? RouteRibbon, ribbon.mapPoints.count >= 2 else { return }
        let total = ribbon.total
        guard total > 1 else { return }

        // Casing, then the full colour, then grey only behind the car. The colour runs to the pin.
        let casing = ribbon.good ? UIColor(hex: 0x14532D) : UIColor(hex: 0x7F1D1D)
        let fill = ribbon.good ? UIColor(hex: 0x22C55E) : UIColor(hex: 0xF87171)
        stroke(ribbon, 0, total, casing, 16, 1, zoomScale, context)
        stroke(ribbon, 0, total, fill, 9, 1, zoomScale, context)
        if ribbon.traveled > 40 {
            stroke(ribbon, 0, max(0, ribbon.traveled - 70), UIColor(hex: 0x64748B), 9, 0.9, zoomScale, context)
        }

        let colors: [Int: UIColor] = [1: UIColor(hex: 0xF59E0B), 2: UIColor(hex: 0xEF4444), 3: UIColor(hex: 0xB91C1C)]
        for s in ribbon.spans {
            let a = max(s.a, ribbon.traveled)
            let b = min(s.b, total)
            guard b > a + 8 else { continue }
            stroke(ribbon, a, b, colors[s.level] ?? .orange, 12, 0.95, zoomScale, context)
            guard ribbon.live else { continue }
            // A bright band walks the jam: the start, the end and how slow it is, not a flat red bar.
            let len = b - a
            let band = min(max(80, len * 0.28), len)
            let travel = (len - band) * ribbon.phase
            let speed = s.level >= 3 ? 0.55 : (s.level == 2 ? 0.8 : 1)
            let start = a + travel * speed
            stroke(ribbon, start, min(b, start + band), UIColor.white, 5, 0.9, zoomScale, context)
        }

        drawChevrons(ribbon, zoomScale: zoomScale, in: mapRect, context: context)
    }

    private func stroke(_ ribbon: RouteRibbon, _ a: Double, _ b: Double, _ color: UIColor, _ width: CGFloat, _ alpha: CGFloat, _ zoom: MKZoomScale, _ context: CGContext) {
        guard let (i0, i1) = ribbon.indices(from: a, to: b), i1 > i0 else { return }
        let path = CGMutablePath()
        path.move(to: point(for: ribbon.mapPoint(at: a)))
        var i = i0 + 1
        while i < i1 {
            path.addLine(to: point(for: ribbon.mapPoints[i]))
            i += 1
        }
        path.addLine(to: point(for: ribbon.mapPoint(at: b)))
        context.saveGState()
        context.setStrokeColor(color.withAlphaComponent(alpha).cgColor)
        context.setLineWidth(width / zoom)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }

    /// White direction marks. Drawn with the line, so they are not annotations that get deleted and reborn.
    private func drawChevrons(_ ribbon: RouteRibbon, zoomScale: MKZoomScale, in mapRect: MKMapRect, context: CGContext) {
        let total = ribbon.total
        let start = ribbon.traveled + 28
        let end = min(total, ribbon.traveled + 7_000)
        guard end > start else { return }
        let len = 8 / zoomScale
        let wing = 5.2 / zoomScale
        let pad = mapRect.insetBy(dx: -2_000, dy: -2_000)
        var m = ceil(start / 150) * 150
        context.saveGState()
        context.setLineCap(.round)
        context.setLineJoin(.round)
        while m < end {
            let mp = ribbon.mapPoint(at: m)
            if pad.contains(mp) {
                let br = Geo.bearing(
                    Geo.point(along: ribbon.line, meters: max(0, m - 16), cumulative: ribbon.cum),
                    Geo.point(along: ribbon.line, meters: min(total, m + 16), cumulative: ribbon.cum)
                ) * .pi / 180
                let dx = CGFloat(sin(br)), dy = CGFloat(-cos(br))
                let px = CGFloat(cos(br)), py = CGFloat(sin(br))
                let c = point(for: mp)
                let tip = CGPoint(x: c.x + dx * len, y: c.y + dy * len)
                let left = CGPoint(x: c.x - dx * len * 0.15 + px * wing, y: c.y - dy * len * 0.15 + py * wing)
                let right = CGPoint(x: c.x - dx * len * 0.15 - px * wing, y: c.y - dy * len * 0.15 - py * wing)
                let v = CGMutablePath()
                v.move(to: left)
                v.addLine(to: tip)
                v.addLine(to: right)
                context.setStrokeColor(UIColor(hex: 0x042F2C).cgColor)
                context.setLineWidth(5.2 / zoomScale)
                context.addPath(v)
                context.strokePath()
                context.setStrokeColor(UIColor.white.cgColor)
                context.setLineWidth(2.6 / zoomScale)
                context.addPath(v)
                context.strokePath()
            }
            m += 150
        }
        context.restoreGState()
    }
}
