import MapKit
import UIKit

/** A box on the map, south-west and north-east corners. */
struct MapBounds {
    var sw: CLLocationCoordinate2D
    var ne: CLLocationCoordinate2D
}

/**
 * Small helpers so the rest of Kite can keep talking about zoom levels, headings and boxes
 * the way it did with MapLibre, while the map itself is Apple's MKMapView.
 */
extension MKMapView {
    /** The usual web-map zoom number (0 = whole world, 15 = streets). */
    var zoomLevel: Double {
        let w = max(Double(bounds.width), 1)
        let lon = max(region.span.longitudeDelta, 0.000001)
        return max(0, min(22, log2(360.0 * w / 256.0 / lon)))
    }

    /** Which way the top of the map points, degrees from north. */
    var direction: CLLocationDirection { camera.heading }

    var visibleCoordinateBounds: MapBounds {
        let r = visibleMapRect
        let sw = MKMapPoint(x: r.minX, y: r.maxY).coordinate
        let ne = MKMapPoint(x: r.maxX, y: r.minY).coordinate
        return MapBounds(sw: sw, ne: ne)
    }

    /** Camera distance that shows about `zoomLevel` on this screen. */
    private func distance(forZoom z: Double) -> CLLocationDistance {
        let metersPerPoint = 156_543.03 * cos(centerCoordinate.latitude * .pi / 180) / pow(2, z)
        return max(150, metersPerPoint * Double(max(bounds.height, 400)) * 1.9)
    }

    func setCenter(_ c: CLLocationCoordinate2D, zoomLevel z: Double, animated: Bool) {
        let cam = MKMapCamera(lookingAtCenter: c, fromDistance: distance(forZoom: z), pitch: 0, heading: camera.heading)
        setCamera(cam, animated: animated)
    }

    func setDirection(_ degrees: CLLocationDirection, animated: Bool) {
        let cam = camera.copy() as! MKMapCamera
        cam.heading = degrees
        setCamera(cam, animated: animated)
    }

    /** A map rectangle `meters` wide and tall around a point. */
    static func rect(around c: CLLocationCoordinate2D, meters: Double) -> MKMapRect {
        let p = MKMapPoint(c)
        let side = meters * MKMapPointsPerMeterAtLatitude(c.latitude)
        return MKMapRect(x: p.x - side / 2, y: p.y - side / 2, width: side, height: side)
    }

    /**
     * Shows `rect` with its edges kept clear of `padding` (the cards and buttons floating on top),
     * facing north and looking straight down, the way a route overview or a picked place looks.
     */
    func show(_ rect: MKMapRect, padding: UIEdgeInsets, animated: Bool) {
        if camera.heading != 0 || camera.pitch != 0 {
            let flat = camera.copy() as! MKMapCamera
            flat.heading = 0
            flat.pitch = 0
            setCamera(flat, animated: false)
        }
        setVisibleMapRect(rect, edgePadding: padding, animated: animated)
    }
}
