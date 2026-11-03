import CoreLocation
import MapKit
import QuartzCore
import UIKit

/**
 Moves the navigation arrow and the camera every screen frame instead of once per GPS fix.
 Between fixes it keeps the arrow rolling along the route at the current speed, then eases
 onto each new fix, so driving looks smooth like Google Maps or Waze rather than jumping every second.
 */
@MainActor
final class NavGlide: NSObject {
    weak var map: MKMapView?
    /**
     * Where the car sits on screen while following: low down, about 75% of the way, so most of the
     * screen shows the road ahead rather than what's already behind. That's as low as it goes with
     * the road name under it still clear of the trip bar.
     */
    nonisolated static let topFraction: CGFloat = 0.7
    nonisolated static let bottomInset: CGFloat = 170
    /** The car's height on a screen [height] tall, for things drawn next to it. */
    nonisolated static func carY(_ height: CGFloat) -> CGFloat { (topInset(height) + height - bottomInset) / 2 }
    /**
     * How much of the top the car stays below. On a short (landscape) screen 70% would push the car
     * onto the trip bar, so there it stays 100 pt above it instead.
     */
    nonisolated static func topInset(_ height: CGFloat) -> CGFloat {
        height < 500 ? max(0, min(height * topFraction, height - bottomInset - 100)) : height * topFraction
    }
    /** The side panel's width on a big screen, so the car drives in the middle of the map beside it. */
    var leftInset: CGFloat = 0
    private weak var nav: Navigator?
    private var link: CADisplayLink?
    private var lastFrame: CFTimeInterval = 0

    // The latest fix, as a target.
    private var fixAt: CFTimeInterval = 0
    private var fixAlong: Double = 0
    private var fixCoord = CLLocationCoordinate2D()
    private var fixBearing: Double = 0
    private var fixSpeed: Double = 0
    private var fixCourse: Double = -1
    private var onRoute = false
    private var line: [LatLng] = []
    private var cum: [Double] = []
    private var targetAcross: Double = 600

    // What is on screen now.
    private var shownAlong: Double?
    private var shownCoord: CLLocationCoordinate2D?
    private var shownBearing: Double = 0
    private var shownAcross: Double = 600

    /** The car on the map: one annotation that is moved and turned every frame. */
    private var puck: KiteAnnotation?
    /** How far the camera sits from the road, per metre of "across" (tune this if the view feels too close or too far). */
    nonisolated static let distanceFactor: Double = 1.6

    /** Called on every GPS fix while navigating. */
    func fix(_ n: Navigator, _ loc: CLLocation, across: Double, jump: Bool) {
        nav = n
        let p = n.progress
        let poly = n.route.polyline
        if poly.count != line.count || poly.first != line.first || poly.last != line.last {
            line = poly
            cum = Geo.cumulative(poly)
            shownAlong = nil
        }
        onRoute = p.map { !$0.offRoute && $0.offsetMeters < 40 } ?? false
        fixAt = CACurrentMediaTime()
        fixAlong = p?.alongMeters ?? 0
        fixCoord = loc.coordinate
        fixSpeed = loc.speed > 0.5 ? loc.speed : 0
        fixCourse = loc.course >= 0 && loc.speed > 2 ? loc.course : -1
        fixBearing = fixCourse >= 0 ? fixCourse : (p?.routeBearing ?? shownBearing)
        targetAcross = across
        if jump || shownCoord == nil {
            shownAlong = onRoute ? fixAlong : nil
            shownCoord = onRoute ? coord(at: fixAlong) : fixCoord
            shownBearing = fixBearing
            shownAcross = across
        }
        start()
        if jump { step(dt: 0) }
    }

    func stop() {
        link?.invalidate()
        link = nil
        nav = nil
        shownAlong = nil
        shownCoord = nil
        lastFrame = 0
        if let p = puck { map?.removeAnnotation(p) }
        puck = nil
    }

    private func start() {
        guard link == nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(frame(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        l.add(to: .main, forMode: .common)
        link = l
        lastFrame = 0
    }

    @objc private func frame(_ l: CADisplayLink) {
        let now = l.timestamp
        let dt = lastFrame == 0 ? 0 : min(0.1, now - lastFrame)
        lastFrame = now
        guard UIApplication.shared.applicationState == .active else { return }
        step(dt: dt)
    }

    private func step(dt: Double) {
        guard let n = nav, let map else { stop(); return }
        // Keep rolling forward for up to 2 s after a fix, so a late fix doesn't stall the arrow.
        let ahead = fixSpeed * min(2, max(0, CACurrentMediaTime() - fixAt))
        // How quickly the screen catches up with where the car should be: about a third of a second.
        let k = dt == 0 ? 1 : 1 - exp(-dt / 0.35)

        let coordNow: CLLocationCoordinate2D
        var bearingTarget = fixBearing
        if onRoute, !line.isEmpty {
            let want = min(fixAlong + ahead, cum.last ?? fixAlong)
            var along = shownAlong ?? want
            if abs(want - along) > 150 { along = want }
            // Never slide backwards along the road unless the car really went back a long way.
            let next = along + (want - along) * k
            along = next < along && along - want < 15 ? along : next
            shownAlong = along
            coordNow = coord(at: along)
            bearingTarget = roadBearing(at: along)
        } else {
            shownAlong = nil
            var want = fixCoord
            if fixCourse >= 0 { want = moved(fixCoord, by: ahead, bearing: fixCourse) }
            let from = shownCoord ?? want
            if distance(from, want) > 200 {
                coordNow = want
            } else {
                coordNow = CLLocationCoordinate2D(latitude: from.latitude + (want.latitude - from.latitude) * k,
                                                  longitude: from.longitude + (want.longitude - from.longitude) * k)
            }
        }
        shownCoord = coordNow
        var turn = (bearingTarget - shownBearing).truncatingRemainder(dividingBy: 360)
        if turn > 180 { turn -= 360 } else if turn < -180 { turn += 360 }
        shownBearing = (shownBearing + turn * (dt == 0 ? 1 : 1 - exp(-dt / 0.4)) + 360).truncatingRemainder(dividingBy: 360)
        shownAcross += (targetAcross - shownAcross) * (dt == 0 ? 1 : 1 - exp(-dt / 1.0))

        let car: KiteAnnotation
        if let p = puck { car = p } else {
            car = KiteAnnotation(layer: .puck, id: "puck", coordinate: coordNow)
            car.icon = "puck"
            puck = car
            map.addAnnotation(car)
        }
        car.coordinate = coordNow
        car.bearing = shownBearing
        if let v = map.view(for: car) as? KiteAnnotationView { v.applyRotation(in: map) }

        if n.following {
            let dist = max(150, shownAcross * Self.distanceFactor)
            // MapKit has no edge padding for the camera, so look a little ahead of the car instead:
            // that is what puts the car low on the screen with the road ahead filling the rest.
            let h = max(map.bounds.height, 1)
            let shiftPx = Self.carY(h) - h / 2
            let ahead = Double(shiftPx / h) * dist * 0.5
            let look = moved(coordNow, by: ahead, bearing: shownBearing)
            let cam = MKMapCamera(lookingAtCenter: look, fromDistance: dist, pitch: 50, heading: shownBearing)
            map.setCamera(cam, animated: false)
        }
    }

    // MARK: Helpers

    private func coord(at along: Double) -> CLLocationCoordinate2D {
        let p = Geo.point(along: line, meters: along, cumulative: cum)
        return CLLocationCoordinate2D(latitude: p.lat, longitude: p.lng)
    }

    /** Direction of the road a little ahead, so the arrow turns into bends instead of snapping at corners. */
    private func roadBearing(at along: Double) -> Double {
        let a = Geo.point(along: line, meters: max(0, along - 5), cumulative: cum)
        let b = Geo.point(along: line, meters: along + 15, cumulative: cum)
        return a == b ? shownBearing : Geo.bearing(a, b)
    }

    private func moved(_ c: CLLocationCoordinate2D, by meters: Double, bearing: Double) -> CLLocationCoordinate2D {
        let r = bearing * .pi / 180
        let dLat = meters * cos(r) / 111_320
        let dLng = meters * sin(r) / (111_320 * max(0.2, cos(c.latitude * .pi / 180)))
        return CLLocationCoordinate2D(latitude: c.latitude + dLat, longitude: c.longitude + dLng)
    }

    private func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude).distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
}
