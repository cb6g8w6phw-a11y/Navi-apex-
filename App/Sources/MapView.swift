import MapKit
import SwiftUI
import UIKit

// MARK: - Things drawn on the map

/** One pin, badge or the car: everything Kite puts on the map besides lines. */
final class KiteAnnotation: NSObject, MKAnnotation {
    enum Layer { case result, selected, mine, camera, signal, waze, roadEvent, fuel, bubble, puck, turnHead }

    @objc dynamic var coordinate: CLLocationCoordinate2D
    let layer: Layer
    let id: String
    var icon = ""
    var label = ""
    /** The icon's bottom tip sits on the spot (pins), instead of its middle. */
    var anchorBottom = false
    /** Cameras on your route are drawn bigger. */
    var big = false
    var opacity: Double = 1
    /** Degrees from north, for the car and the turn arrow's head. */
    var bearing: Double = 0
    var rank = 0
    var routeIndex = 0
    var routeSelected = false

    init(layer: Layer, id: String, coordinate: CLLocationCoordinate2D) {
        self.layer = layer
        self.id = id
        self.coordinate = coordinate
    }

    /** Which ones can be tapped. */
    var tappable: Bool {
        switch layer {
        case .result, .mine, .waze, .roadEvent, .fuel, .bubble: return true
        default: return false
        }
    }
}

final class KiteAnnotationView: MKAnnotationView {
    private let label = UILabel()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        canShowCallout = false
        collisionMode = .none
        label.numberOfLines = 2
        label.textAlignment = .center
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ a: KiteAnnotation, dark: Bool) {
        layer.transform = CATransform3DIdentity
        transform = .identity
        isEnabled = a.tappable
        label.isHidden = true
        alpha = CGFloat(a.opacity)

        if a.layer == .bubble {
            image = Self.pill(a.label, selected: a.routeSelected)
            centerOffset = .zero
            zPriority = MKAnnotationViewZPriority(rawValue: 900)
            displayPriority = .required
            return
        }

        let img = MapIcons.image(a.icon, dark: dark)
        image = img
        let size = img?.size ?? .zero
        centerOffset = a.anchorBottom ? CGPoint(x: 0, y: -size.height / 2) : .zero
        displayPriority = .required

        switch a.layer {
        case .puck: zPriority = .max
        case .turnHead: zPriority = MKAnnotationViewZPriority(rawValue: 800)
        case .result, .selected: zPriority = MKAnnotationViewZPriority(rawValue: 600)
        case .mine: zPriority = MKAnnotationViewZPriority(rawValue: 500)
        case .waze: zPriority = MKAnnotationViewZPriority(rawValue: 400)
        case .camera: zPriority = MKAnnotationViewZPriority(rawValue: 300)
        case .roadEvent: zPriority = MKAnnotationViewZPriority(rawValue: 350)
        case .fuel: zPriority = MKAnnotationViewZPriority(rawValue: 420)
        default: zPriority = MKAnnotationViewZPriority(rawValue: 200)
        }
        if a.layer == .result { displayPriority = MKFeatureDisplayPriority(rawValue: Float(max(1, 999 - a.rank))) }
        if (a.layer == .camera || a.layer == .roadEvent || a.layer == .fuel) && a.big { transform = CGAffineTransform(scaleX: 1.25, y: 1.25) }

        setPulse(nil)
        if a.layer == .roadEvent, a.big {
            let ring: UIColor = a.icon == "road-closure" ? UIColor(hex: 0xD32F2F) : UIColor(hex: 0xFFB300)
            setPulse(ring)
        }

        if !a.label.isEmpty, a.layer == .result || a.layer == .selected || a.layer == .mine || a.layer == .fuel {
            let text = dark ? UIColor(hex: 0xE8EAED) : UIColor(hex: 0x202124)
            let halo = dark ? UIColor(hex: 0x0B1526) : UIColor.white
            let size13 = a.layer == .selected ? 13.0 : (a.layer == .result ? 12.0 : 11.0)
            label.attributedText = NSAttributedString(string: a.label, attributes: [
                .font: UIFont.systemFont(ofSize: CGFloat(size13), weight: .bold),
                .foregroundColor: text,
                .strokeColor: halo,
                .strokeWidth: -4,
            ])
            label.textAlignment = a.layer == .result ? .left : .center
            let box = label.sizeThatFits(CGSize(width: 130, height: 60))
            if a.layer == .result {
                label.frame = CGRect(x: size.width + 3, y: (size.height - box.height) / 2, width: box.width, height: box.height)
            } else {
                label.frame = CGRect(x: (size.width - box.width) / 2, y: size.height + 1, width: box.width, height: box.height)
            }
            label.isHidden = false
        }
    }

    /** A sign that appears: it pops up with a bounce, and the ones on your route send out a ring. */
    func popIn(strong: Bool) {
        let final = transform
        let target = alpha
        if strong {
            transform = final.scaledBy(x: 0.15, y: 0.15)
            alpha = 0
            UIView.animate(withDuration: 0.65, delay: 0, usingSpringWithDamping: 0.42, initialSpringVelocity: 0.9,
                           options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.transform = final
                self.alpha = target
            }
        } else {
            transform = final.scaledBy(x: 0.6, y: 0.6)
            alpha = 0
            UIView.animate(withDuration: 0.25, delay: 0, options: [.allowUserInteraction, .curveEaseOut]) {
                self.transform = final
                self.alpha = target
            }
        }
    }

    private var pulseLayer: CAShapeLayer?

    /** A ring that grows and fades, over and over: this one is on your route. */
    func setPulse(_ color: UIColor?) {
        pulseLayer?.removeFromSuperlayer()
        pulseLayer = nil
        guard let color else { return }
        let side = max(bounds.width, bounds.height, 24)
        let ring = CAShapeLayer()
        ring.frame = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        ring.path = UIBezierPath(ovalIn: ring.bounds.insetBy(dx: 2, dy: 2)).cgPath
        ring.fillColor = UIColor.clear.cgColor
        ring.strokeColor = color.cgColor
        ring.lineWidth = 2.5
        ring.opacity = 0
        layer.insertSublayer(ring, at: 0)
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.8
        grow.toValue = 2.1
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.85
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 1.6
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(group, forKey: "pulse")
        pulseLayer = ring
    }

    /** Turns the car and the arrow head to face their bearing on the map, and tips the car flat onto the road. */
    func applyRotation(in map: MKMapView) {
        guard let a = annotation as? KiteAnnotation else { return }
        let rel = CGFloat((a.bearing - map.camera.heading) * .pi / 180)
        switch a.layer {
        case .puck:
            var t = CATransform3DIdentity
            t.m34 = -1.0 / 700
            t = CATransform3DRotate(t, CGFloat(map.camera.pitch * .pi / 180) * 0.9, 1, 0, 0)
            t = CATransform3DRotate(t, rel, 0, 0, 1)
            layer.transform = t
        case .turnHead:
            transform = CGAffineTransform(rotationAngle: rel)
        default:
            break
        }
    }

    /** A route's trip time in a pill: teal when it's the picked route, white when it's another. */
    private static func pill(_ text: String, selected: Bool) -> UIImage {
        let color = selected ? UIColor.white : UIColor(hex: 0x202124)
        let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 15, weight: .bold), .foregroundColor: color]
        let ts = (text as NSString).size(withAttributes: attrs)
        let size = CGSize(width: ceil(ts.width) + 26, height: ceil(ts.height) + 12)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: rect.height / 2)
            (selected ? UIColor(hex: 0x0F766E) : UIColor.white).setFill()
            (selected ? UIColor.white : UIColor(hex: 0xBDC1C6)).setStroke()
            path.lineWidth = 1.5
            path.fill()
            path.stroke()
            (text as NSString).draw(at: CGPoint(x: (size.width - ts.width) / 2, y: (size.height - ts.height) / 2), withAttributes: attrs)
        }
    }
}

// MARK: - Lines and the police glow

struct LineStyle {
    var color: UIColor
    var width: CGFloat
    var alpha: CGFloat = 1
    var dash: [NSNumber]?
    var gradient: [UIColor]?
    /** When set, the line is this many times as wide as a road drawn at the current zoom (1 = exactly road width). */
    var relative: CGFloat?
}

/** How wide a road looks on screen at this zoom, in points: its real width (about 8 m), but never thinner than a visible line. */
func roadWidthOnScreen(zoomScale: MKZoomScale, latitude: Double) -> CGFloat {
    let physical = 7.0 * MKMapPointsPerMeterAtLatitude(latitude) * Double(zoomScale)
    let z = log2(Double(zoomScale) * 1_048_576)
    let floorPoints = 2.4 + 2.0 * min(max((z - 9) / 6, 0), 1)
    return CGFloat(min(max(physical, floorPoints), 30))
}

/** A route line that follows the width of the road under it, instead of a fixed width. */
final class RoadLineRenderer: MKPolylineRenderer {
    var relative: CGFloat = 1
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let w = max(roadWidthOnScreen(zoomScale: zoomScale, latitude: polyline.coordinate.latitude) * relative, 2)
        if abs(lineWidth - w) > 0.01 { lineWidth = w }
        super.draw(mapRect, zoomScale: zoomScale, in: context)
    }
}

final class RoadGradientRenderer: MKGradientPolylineRenderer {
    var relative: CGFloat = 1
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let w = max(roadWidthOnScreen(zoomScale: zoomScale, latitude: polyline.coordinate.latitude) * relative, 2)
        if abs(lineWidth - w) > 0.01 { lineWidth = w }
        super.draw(mapRect, zoomScale: zoomScale, in: context)
    }
}

typealias StyledLine = (line: MKPolyline, style: LineStyle)

/** The glow where police get reported: soft coloured blobs, drawn under the routes. */
final class HeatOverlay: NSObject, MKOverlay {
    let points: [MKMapPoint]
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: 0, longitude: 0) }
    var boundingMapRect: MKMapRect { MKMapRect.world }

    init(_ coords: [CLLocationCoordinate2D]) {
        points = coords.map { MKMapPoint($0) }
    }
}

final class HeatRenderer: MKOverlayRenderer {
    private static func radius(atZoom z: Double) -> Double {
        let stops: [(Double, Double)] = [(6, 14), (10, 26), (14, 48), (17, 70)]
        if z <= stops[0].0 { return stops[0].1 }
        for i in 1..<stops.count where z <= stops[i].0 {
            let (z0, r0) = stops[i - 1], (z1, r1) = stops[i]
            return r0 + (r1 - r0) * (z - z0) / (z1 - z0)
        }
        return stops[stops.count - 1].1
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let heat = overlay as? HeatOverlay else { return }
        let zoom = log2(Double(zoomScale) * 1_048_576)
        let r = Self.radius(atZoom: zoom) / Double(zoomScale)
        let area = mapRect.insetBy(dx: -r, dy: -r)
        let colors = [
            UIColor(red: 213 / 255, green: 0, blue: 0, alpha: 0.55).cgColor,
            UIColor(red: 233 / 255, green: 30 / 255, blue: 99 / 255, alpha: 0.4).cgColor,
            UIColor(red: 124 / 255, green: 77 / 255, blue: 1, alpha: 0.25).cgColor,
            UIColor(red: 66 / 255, green: 133 / 255, blue: 244 / 255, alpha: 0).cgColor,
        ] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.35, 0.65, 1]) else { return }
        for p in heat.points where area.contains(p) {
            let c = point(for: p)
            context.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(r), options: [])
        }
    }
}

// MARK: - The map

/** The full-screen map: Apple Maps, with Kite's own layers on top (result pins, routes with traffic,
 *  the navigation car, cameras, Waze reports, the police glow). */
struct VelaMapView: UIViewRepresentable {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    let dark: Bool

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        let c = context.coordinator
        map.delegate = c
        map.showsUserLocation = true
        // Your blue dot in Kite's teal, to match the route and the driving arrow.
        map.tintColor = UIColor(hex: 0x14B8A6)
        map.showsCompass = false
        map.showsScale = false
        map.isPitchEnabled = true
        map.isRotateEnabled = true
        map.selectableMapFeatures = [.pointsOfInterest]
        map.overrideUserInterfaceStyle = dark ? .dark : .light
        map.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 40.7484, longitude: -73.9857),
                                        latitudinalMeters: 25_000, longitudinalMeters: 25_000)

        let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tapped(_:)))
        tap.delegate = c
        let press = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.pressed(_:)))
        press.delegate = c
        // A long press must never also count as a tap, or the tap closes the pin it just dropped.
        tap.require(toFail: press)
        for r in (map.gestureRecognizers ?? []) + (map.subviews.first?.gestureRecognizers ?? []) {
            if let t = r as? UITapGestureRecognizer, t.numberOfTapsRequired == 2 { tap.require(toFail: t) }
        }
        map.addGestureRecognizer(press)
        map.addGestureRecognizer(tap)
        // While driving, the first touch that moves the map stops it following the car at once,
        // instead of the camera snapping back on the next frame.
        let pan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.userMoved(_:)))
        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.userMoved(_:)))
        let twist = UIRotationGestureRecognizer(target: c, action: #selector(Coordinator.userMoved(_:)))
        for g in [pan, pinch, twist] as [UIGestureRecognizer] {
            g.delegate = c
            g.cancelsTouchesInView = false
            map.addGestureRecognizer(g)
        }

        c.dark = dark
        model.map = map
        // Reports found by the background sweep show on the heat map straight away.
        WazeHistory.shared.onChange = { [weak c, weak map] in if let c, let map { c.render(map) } }
        RoadEvents.shared.onChange = { [weak c, weak map] in if let c, let map { c.render(map) } }
        FuelPrices.shared.onChange = { [weak c, weak map] in if let c, let map { c.render(map) } }
        // On a first launch, location is asked for after the welcome, not on top of it.
        if (settings.welcomed && !settings.needsWazeChoice) || DemoScript.active { model.location.start() }
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let c = context.coordinator
        if c.dark != dark {
            c.dark = dark
            c.repaint(map)
        }
        
        // Włączanie i wyłączanie natywnego śledzenia kamery (naprawia brak auta i "jebnięcie" kamery)
        if let nav = model.nav, nav.following {
            if map.userTrackingMode != .followWithHeading {
                map.userTrackingMode = .followWithHeading
                map.camera.pitch = 45 // Lekkie pochylenie 3D
            }
        } else {
            if map.userTrackingMode != .none {
                map.userTrackingMode = .none
            }
        }
        
        c.render(map)
        c.loadCameras(map)
        c.loadWaze(map)
        c.loadRoadEvents(map)
        c.loadFuel(map)
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        let model: AppModel
        var dark = false
        private var movedToUser = false
        private var pinDroppedAt = Date.distantPast
        private var policeSweptAt = Date.distantPast
        /** When the map itself last picked something (a place, a pin, a report), so the empty-map tap stays out of it. */
        private var lastPickAt = Date.distantPast

        private var lastResultsKey = ""
        private var lastRouteKey = ""
        private var lastMineKey = ""
        private var lastCameraKey = ""
        private var lastSignalsKey = ""
        private var lastWazeKey = ""
        private var lastRoadKey = ""
        private var lastFuelKey = ""
        private var lastConfigKey = ""

        /** Which zoom-gated layers were showing, so zooming across a limit redraws them. */
        private var gates = [false, false, false, false]

        private var resultAnns: [KiteAnnotation] = []
        private var selectedAnns: [KiteAnnotation] = []
        private var mineAnns: [KiteAnnotation] = []
        private var cameraAnns: [KiteAnnotation] = []
        private var signalAnns: [KiteAnnotation] = []
        private var wazeAnns: [KiteAnnotation] = []
        private var roadAnns: [KiteAnnotation] = []
        private var fuelAnns: [KiteAnnotation] = []
        private var bubbleAnns: [KiteAnnotation] = []
        private var headAnns: [KiteAnnotation] = []

        private var heatOverlay: HeatOverlay?
        private var terrainOverlay: MKTileOverlay?
        private var radarOverlay: DWDRadarOverlay?
        private var railLines: [StyledLine] = []
        private var routeLines: [StyledLine] = []
        private var arrowLines: [StyledLine] = []
        private var lineStyles: [ObjectIdentifier: LineStyle] = [:]
        private var overlaysDirty = false
        private var wantedOverlays: Set<ObjectIdentifier> = []
        private var poppedSigns: Set<String> = []
        private var railShapes: [(points: [LatLng], color: UInt32)] = []

        /** Cameras fetched so far, and the 0.1° cells already asked for (cameras don't move). */
        private var cameras: [Int64: RoadCamera] = [:]
        private var cameraCells: Set<String> = []
        private var cameraFetch: Task<Void, Never>?
        private var railFetch: Task<Void, Never>?
        /** Live Waze reports for the box last asked about, and when. */
        private var wazeAlerts: [WazeAlert] = []
        private var wazeBox: (s: Double, w: Double, n: Double, e: Double)?
        private var wazeAt = Date.distantPast
        private var wazeFetch: Task<Void, Never>?
        /** When Waze last didn't answer: wait a minute before asking again, rather than on every pan. */
        private var wazeFailedAt = Date.distantPast
        /** The box the drawn rail lines cover, so panning inside it asks nothing. */
        private var railBox: (s: Double, w: Double, n: Double, e: Double, z: Int)?

        init(model: AppModel) { self.model = model }

        // MARK: Look

        func repaint(_ map: MKMapView) {
            map.overrideUserInterfaceStyle = dark ? .dark : .light
            lastResultsKey = ""; lastRouteKey = ""; lastMineKey = ""; lastCameraKey = ""; lastSignalsKey = ""; lastWazeKey = ""; lastRoadKey = ""; lastFuelKey = ""
            for a in map.annotations {
                if let ka = a as? KiteAnnotation, let v = map.view(for: ka) as? KiteAnnotationView { v.configure(ka, dark: dark) }
            }
            rebuildRail()
        }

        /** Satellite, traffic and the driving look are all just settings of Apple's map. */
        private func configure(_ map: MKMapView, navigating: Bool) {
            let s = model.settings
            let key = "\(s.satellite)\(navigating)\(s.traffic)"
            guard key != lastConfigKey else { return }
            lastConfigKey = key
            // While driving, shop and bin icons go and the map is toned down so the route stands out.
            let poi: MKPointOfInterestFilter = navigating ? .excludingAll : .includingAll
            if s.satellite {
                let c = MKHybridMapConfiguration(elevationStyle: .flat)
                c.showsTraffic = s.traffic && !navigating
                c.pointOfInterestFilter = poi
                map.preferredConfiguration = c
            } else {
                let c = MKStandardMapConfiguration(elevationStyle: navigating ? .flat : .realistic,
                                                   emphasisStyle: navigating ? .muted : .default)
                c.showsTraffic = s.traffic && !navigating
                c.pointOfInterestFilter = poi
                map.preferredConfiguration = c
            }
        }

        // MARK: Render

        func render(_ map: MKMapView) {
            let s = model.settings
            let navigating = model.nav != nil
            configure(map, navigating: navigating)

            let wantTerrain = s.terrain && !s.satellite
            if wantTerrain != (terrainOverlay != nil) {
                if wantTerrain {
                    let t = MKTileOverlay(urlTemplate: "https://services.arcgisonline.com/ArcGIS/rest/services/Elevation/World_Hillshade/MapServer/tile/{z}/{y}/{x}")
                    t.canReplaceMapContent = false
                    t.maximumZ = 16
                    terrainOverlay = t
                } else {
                    terrainOverlay = nil
                }
                overlaysDirty = true
            }

            if s.radarOn != (radarOverlay != nil) {
                radarOverlay = s.radarOn ? DWDRadarOverlay() : nil
                overlaysDirty = true
            }

            let z = map.zoomLevel
            gates = [z >= 11, z >= 14, z >= 11, z >= 9]
            renderResults(map)
            renderRoutes(map)
            renderCameras(map)
            renderSignals(map)
            renderWaze(map)
            renderRoadEvents(map)
            renderFuel(map)
            renderMine(map)
            let railWanted = s.transitLines && !navigating
            if railWanted == railLines.isEmpty && !railShapes.isEmpty { rebuildRail() }
            if s.transitLines { loadRail(map) }
            if overlaysDirty { syncOverlays(map) }
        }

        private func replaceAnnotations(_ old: inout [KiteAnnotation], _ new: [KiteAnnotation], _ map: MKMapView) {
            if !old.isEmpty { map.removeAnnotations(old) }
            if !new.isEmpty { map.addAnnotations(new) }
            old = new
        }

        /** All lines and the glow, put on the map in the order they must be stacked. */
        private func syncOverlays(_ map: MKMapView) {
            overlaysDirty = false
            var ordered: [MKOverlay] = []
            var styles: [ObjectIdentifier: LineStyle] = [:]
            if let t = terrainOverlay { ordered.append(t) }
            if let r = radarOverlay { ordered.append(r) }
            if let h = heatOverlay { ordered.append(h) }
            for group in [railLines, routeLines, arrowLines] {
                for item in group {
                    styles[ObjectIdentifier(item.line)] = item.style
                    ordered.append(item.line)
                }
            }
            // Styles of lines that are still on the map for another moment must stay readable.
            for (k, v) in lineStyles where styles[k] == nil { styles[k] = v }
            lineStyles = styles

            let wanted = Set(ordered.map { ObjectIdentifier($0 as AnyObject) })
            let present = Set(map.overlays.map { ObjectIdentifier($0 as AnyObject) })
            // Bottom-up, so each new overlay lands just under the one that goes above it.
            var above: MKOverlay?
            for o in ordered.reversed() {
                if !present.contains(ObjectIdentifier(o as AnyObject)) {
                    if let a = above { map.insertOverlay(o, below: a) } else { map.addOverlay(o, level: .aboveRoads) }
                }
                above = o
            }
            wantedOverlays = wanted

            let stale = map.overlays.filter { !wanted.contains(ObjectIdentifier($0 as AnyObject)) }
            guard !stale.isEmpty else { return }
            map.removeOverlays(stale)
            for o in stale { self.lineStyles[ObjectIdentifier(o as AnyObject)] = nil }
        }

        private func makeLine(_ pts: [LatLng], _ style: LineStyle) -> StyledLine? {
            guard pts.count >= 2 else { return nil }
            // Wygładzanie: generujemy gęste punkty (co 10m), żeby trasa na zakrętach nie ucinała rogów
            let cum = Geo.cumulative(pts)
            let total = cum.last ?? 0
            var densePts: [LatLng] = []
            var m = 0.0
            while m < total {
                densePts.append(Geo.point(along: pts, meters: m, cumulative: cum))
                m += 10.0
            }
            densePts.append(pts.last!)
            
            var coords = densePts.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng) }
            let line = MKPolyline(coordinates: &coords, count: coords.count)
            return (line, style)
        }

        private func coord(_ p: LatLng) -> CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: p.lat, longitude: p.lng) }

        private func renderMine(_ map: MKMapView) {
            let s = model.settings
            let hidden = model.nav != nil || model.directions != nil
            var items: [(Place, String, String)] = []
            if !hidden && gates[3] {
                if let h = s.home { items.append((h, "mine-home", "Home")) }
                if let w = s.work { items.append((w, "mine-work", "Work")) }
                if let p = s.parking { items.append((p, "mine-parking", "Parked car")) }
                for p in s.saved.prefix(200) where !items.contains(where: { $0.0.id == p.id }) { items.append((p, "mine-saved", p.name)) }
            }
            let sel = model.selected?.id
            let key = items.map { $0.0.id + $0.1 }.joined(separator: ",") + "|" + (sel ?? "")
            guard key != lastMineKey else { return }
            lastMineKey = key
            let anns: [KiteAnnotation] = items.compactMap { p, icon, label in
                guard p.id != sel else { return nil }
                let a = KiteAnnotation(layer: .mine, id: p.id, coordinate: coord(p.location))
                a.icon = icon
                a.label = label
                return a
            }
            replaceAnnotations(&mineAnns, anns, map)
        }

        private func renderCameras(_ map: MKMapView) {
            let s = model.settings
            let line = model.nav?.route.polyline ?? model.directions?.route?.polyline ?? []
            let key = "\(s.speedCameras)\(s.plateCameras)\(cameras.count)\(line.count)\(line.first?.lat ?? 0)\(gates[0])"
            guard key != lastCameraKey else { return }
            lastCameraKey = key
            guard gates[0] else { replaceAnnotations(&cameraAnns, [], map); return }
            let shown = cameras.values.filter { $0.kind == .speed ? s.speedCameras : s.plateCameras }
            let cum = line.count >= 2 ? Geo.cumulative(line) : []
            let anns: [KiteAnnotation] = shown.map { c in
                let a = KiteAnnotation(layer: .camera, id: "cam\(c.id)", coordinate: coord(c.location))
                a.icon = c.kind == .speed ? "cam-speed" : "cam-plate"
                a.big = !cum.isEmpty && Geo.project(c.location, on: line, cumulative: cum).offset < 40
                return a
            }
            replaceAnnotations(&cameraAnns, anns, map)
        }

        private func renderSignals(_ map: MKMapView) {
            let lights = gates[1] ? (model.nav?.routeSignals ?? []) : []
            let key = "\(lights.count)\(lights.first?.lat ?? 0)"
            guard key != lastSignalsKey else { return }
            lastSignalsKey = key
            let anns: [KiteAnnotation] = lights.enumerated().map { i, p in
                let a = KiteAnnotation(layer: .signal, id: "light\(i)", coordinate: coord(p))
                a.icon = "traffic-light"
                a.anchorBottom = true
                return a
            }
            replaceAnnotations(&signalAnns, anns, map)
        }

        private func renderWaze(_ map: MKMapView) {
            let s = model.settings
            let history = WazeHistory.shared.sightings
            let kinds = s.wazeKinds.map(\.rawValue).sorted().joined()
            // While navigating, drivers' reports from Waze's app servers too (the live map has only closures).
            let live = model.nav?.liveAlerts ?? []
            let key = "\(s.wazeOn)\(s.wazeOnMap)\(s.wazeHeatmap)\(s.wazeMaxAge)\(kinds)\(wazeAt.timeIntervalSince1970)\(history.count)\(live.map(\.id).joined())\(gates[2])"
            guard key != lastWazeKey else { return }
            lastWazeKey = key
            let ids = Set(wazeAlerts.map(\.id))
            let all = wazeAlerts + live.filter { !ids.contains($0.id) }
            let shown = s.wazeOn && s.wazeOnMap && gates[2] ? all.filter { s.shows($0) } : []
            let anns: [KiteAnnotation] = shown.map { a in
                let m = KiteAnnotation(layer: .waze, id: a.id, coordinate: coord(a.location))
                m.icon = "waze-\(a.kind.rawValue)"
                // Fresh reports solid, fading to half over two hours.
                m.opacity = max(0.5, 1 - Date().timeIntervalSince(a.reportedAt) / 14_400)
                return m
            }
            replaceAnnotations(&wazeAnns, anns, map)

            let heatOn = s.wazeOn && s.wazeHeatmap && s.wazePolice
            var newHeat: HeatOverlay?
            if heatOn {
                var seen = Set(history.map(\.id))
                var pts = history.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng) }
                for a in all where a.kind == .police && seen.insert(a.id).inserted { pts.append(coord(a.location)) }
                if !pts.isEmpty { newHeat = HeatOverlay(pts) }
            }
            if newHeat != nil || heatOverlay != nil {
                heatOverlay = newHeat
                overlaysDirty = true
            }
        }

        /** Roadworks, closures and warnings from the Autobahn API, for what's on screen. */
        private func renderRoadEvents(_ map: MKMapView) {
            let on = model.settings.traffic && gates[2] && RoadEvents.covers(map.centerCoordinate)
            let b = map.visibleCoordinateBounds
            let q = { (v: Double) in Int((v * 10).rounded()) }
            let line = model.nav?.route.polyline ?? model.directions?.route?.polyline ?? []
            let key = "\(on)\(RoadEvents.shared.updatedAt.timeIntervalSince1970)\(q(b.sw.latitude)),\(q(b.sw.longitude)),\(q(b.ne.latitude)),\(q(b.ne.longitude))\(line.count)\(line.first?.lat ?? 0)"
            guard key != lastRoadKey else { return }
            lastRoadKey = key
            guard on else { replaceAnnotations(&roadAnns, [], map); return }
            let dLat = (b.ne.latitude - b.sw.latitude) * 0.25, dLng = (b.ne.longitude - b.sw.longitude) * 0.25
            let centre = LatLng(map.centerCoordinate.latitude, map.centerCoordinate.longitude)
            let inView = RoadEvents.shared.events.filter {
                $0.location.lat > b.sw.latitude - dLat && $0.location.lat < b.ne.latitude + dLat
                    && $0.location.lng > b.sw.longitude - dLng && $0.location.lng < b.ne.longitude + dLng
            }
            let nearest = inView.sorted { $0.location.distance(to: centre) < $1.location.distance(to: centre) }.prefix(250)
            let cum = line.count >= 2 ? Geo.cumulative(line) : []
            let anns: [KiteAnnotation] = nearest.map { e in
                let a = KiteAnnotation(layer: .roadEvent, id: e.id, coordinate: coord(e.location))
                a.icon = e.iconName
                a.big = !cum.isEmpty && Geo.project(e.location, on: line, cumulative: cum).offset < 60
                return a
            }
            replaceAnnotations(&roadAnns, anns, map)
        }

        /** Petrol stations with their price under the pin, the cheapest in green, for what's on screen. */
        private func renderFuel(_ map: MKMapView) {
            let s = model.settings
            let on = s.fuelOn && !s.fuelKey.isEmpty && map.zoomLevel >= 10 && RoadEvents.covers(map.centerCoordinate)
            let b = map.visibleCoordinateBounds
            let q = { (v: Double) in Int((v * 20).rounded()) }
            let fuel = FuelPrices.shared
            let key = "\(on)\(s.fuelType)\(s.fuelCount)\(fuel.updatedAt.timeIntervalSince1970)\(fuel.aheadAt.timeIntervalSince1970)\(q(b.sw.latitude)),\(q(b.sw.longitude)),\(q(b.ne.latitude)),\(q(b.ne.longitude))"
            guard key != lastFuelKey else { return }
            lastFuelKey = key
            guard on else {
                replaceAnnotations(&fuelAnns, [], map)
                setFuelBest(nil)
                return
            }
            var seen = Set<String>()
            let all = (fuel.stations + fuel.ahead).filter { $0.open && seen.insert($0.id).inserted }
            let dLat = (b.ne.latitude - b.sw.latitude) * 0.1, dLng = (b.ne.longitude - b.sw.longitude) * 0.1
            let shown = all.filter {
                $0.location.lat > b.sw.latitude - dLat && $0.location.lat < b.ne.latitude + dLat
                    && $0.location.lng > b.sw.longitude - dLng && $0.location.lng < b.ne.longitude + dLng
            }.sorted { $0.price < $1.price }.prefix(max(1, s.fuelCount))
            let best = shown.first
            let anns: [KiteAnnotation] = shown.map { st in
                let a = KiteAnnotation(layer: .fuel, id: st.id, coordinate: coord(st.location))
                a.icon = st.id == best?.id ? "fuel-best" : "fuel"
                a.label = st.priceText
                a.big = st.id == best?.id
                return a
            }
            replaceAnnotations(&fuelAnns, anns, map)
            // The chip on the map screen: the cheapest open station within 12 km of you.
            let me = model.userLatLng ?? LatLng(map.centerCoordinate.latitude, map.centerCoordinate.longitude)
            setFuelBest(all.filter { $0.location.distance(to: me) < 12_000 }.min { $0.price < $1.price })
        }

        private func setFuelBest(_ station: FuelStation?) {
            // Not while SwiftUI is still drawing: the chip is part of that drawing.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.model.fuelBest != station else { return }
                self.model.fuelBest = station
            }
        }

        func loadFuel(_ map: MKMapView) {
            guard model.settings.fuelOn, map.zoomLevel >= 9 else { return }
            FuelPrices.shared.refreshIfNeeded(center: map.centerCoordinate)
        }

        /** Asks for fresh motorway data when the layer is on and the map is over Germany. */
        func loadRoadEvents(_ map: MKMapView) {
            guard model.settings.traffic, map.zoomLevel >= 8 else { return }
            RoadEvents.shared.refreshIfNeeded(center: map.centerCoordinate)
        }

        private func renderResults(_ map: MKMapView) {
            let showList = model.directions == nil && model.nav == nil
            let list = showList ? model.visibleResults : []
            let target = model.nav?.destination ?? model.directions?.destination ?? model.selected
            let stops: [Place] = model.nav?.stops ?? model.directions?.stops ?? []
            let ids: String = list.map(\.id).joined(separator: ",")
            let stopIds: String = stops.map(\.id).joined(separator: ",")
            let key = "\(ids)|\(target?.id ?? "")|\(model.directions?.reversed ?? false)|\(model.nav == nil)|\(stopIds)|\(dark)"
            guard key != lastResultsKey else { return }
            lastResultsKey = key

            let pins: [KiteAnnotation] = list.enumerated().compactMap { i, p in
                guard p.id != target?.id else { return nil }
                let a = KiteAnnotation(layer: .result, id: p.id, coordinate: coord(p.location))
                a.icon = MapIcons.iconName(for: p)
                let rating = p.rating.map { String(format: "%.1f", $0) }
                a.label = [p.name, rating].compactMap { $0 }.joined(separator: "\n")
                a.rank = i
                return a
            }
            replaceAnnotations(&resultAnns, pins, map)

            var sel: [KiteAnnotation] = []
            if let t = target {
                let a = KiteAnnotation(layer: .selected, id: t.id, coordinate: coord(t.location))
                a.icon = "pin-selected"
                a.anchorBottom = true
                a.label = t.name
                sel.append(a)
                for (i, stop) in stops.enumerated() {
                    let s = KiteAnnotation(layer: .selected, id: "stop\(i)", coordinate: coord(stop.location))
                    s.icon = "pin-stop"
                    s.label = stop.name
                    sel.append(s)
                }
                if let d = model.directions, d.reversed == false, model.nav == nil, let me = model.userLatLng {
                    let o = KiteAnnotation(layer: .selected, id: "origin", coordinate: coord(me))
                    o.icon = "pin-origin"
                    sel.append(o)
                }
            }
            replaceAnnotations(&selectedAnns, sel, map)
        }

        private func renderRoutes(_ map: MKMapView) {
            var alts: [Route] = []
            var main: Route?
            if let n = model.nav {
                main = n.route
            } else if let d = model.directions {
                main = d.route
                alts = d.current.filter { $0.id != main?.id }
            }
            let navigating = model.nav != nil
            let trip = navigating ? nil : model.directions?.pickedTrip
            let from = model.nav?.progress?.alongMeters ?? 0

            // Klucz zmienia się co ~50m jazdy, żeby trasa rysowała się na bieżąco
            let key = (navigating ? "nav" : "") + (trip?.id.uuidString ?? "") + (main?.id.uuidString ?? "")
                + alts.map(\.id.uuidString).joined() + "\(Int(from / 50))" + "\(model.nav?.nextManeuver?.alongMeters ?? 0)" + "\(dark)"
            guard key != lastRouteKey else { return }
            lastRouteKey = key
            overlaysDirty = true

            var altsG: [StyledLine] = []
            var transitG: [StyledLine] = []
            var fullRoute: [StyledLine] = []
            var traveled: [StyledLine] = []
            var dots: [StyledLine] = []
            var spansOut: [StyledLine] = []

            func add(_ group: inout [StyledLine], _ pts: [LatLng], _ style: LineStyle) {
                if let l = makeLine(pts, style) { group.append(l) }
            }

            // Trasy alternatywne
            for r in alts { add(&altsG, r.polyline, LineStyle(color: UIColor(hex: 0x115E59), width: 11, alpha: 0.6, relative: 0.85)) }
            for r in alts { add(&altsG, r.polyline, LineStyle(color: UIColor(hex: 0x5EEAD4), width: 7, alpha: 0.6, relative: 0.55)) }

            // Komunikacja miejska (jeśli wybrana)
            if let t = trip {
                let legs = t.legs.filter { $0.path.count >= 2 }
                for leg in legs where leg.isWalk {
                    add(&transitG, leg.path, LineStyle(color: UIColor(hex: 0x5F6368), width: 5, dash: [0.1, 9]))
                }
                for leg in legs where !leg.isWalk {
                    add(&transitG, leg.path, LineStyle(color: UIColor(white: 0.1, alpha: 1), width: 10, alpha: 0.55))
                }
                for leg in legs where !leg.isWalk {
                    add(&transitG, leg.path, LineStyle(color: UIColor(hex: UInt32(leg.color ?? 0x1F6FEB)), width: 7))
                }
            }

            routeLines = altsG + transitG

            guard let r = main else {
                arrowLines = []
                replaceAnnotations(&bubbleAnns, [], map)
                replaceAnnotations(&headAnns, [], map)
                return
            }

            let cum = Geo.cumulative(r.polyline)
            let total = cum.last ?? 0

            // 1. ZAWSZE rysuj PEŁNĄ trasę (stała szerokość, brak wielkich trójkątów)
            add(&fullRoute, r.polyline, LineStyle(color: UIColor(hex: 0x0F766E), width: 16, relative: nil))
            add(&fullRoute, r.polyline, LineStyle(color: UIColor(hex: 0x2DD4BF), width: 10,
                                                  gradient: [UIColor(hex: 0x2DD4BF), UIColor(hex: 0x22D3EE)], relative: nil))

            // 2. Kropki tylko na pozostałej części (przed tobą)
            if navigating && from > 1 && from < total - 5 {
                let remaining = Geo.slice(r.polyline, from: from, to: total, cumulative: cum)
                add(&dots, remaining, LineStyle(color: .white, width: 3, alpha: 0.5, dash: [1, 18], relative: 0.18))
            } else if !navigating {
                add(&dots, r.polyline, LineStyle(color: .white, width: 3, alpha: 0.5, dash: [1, 18], relative: 0.18))
            }

            // 3. Przejechany odcinek przygaszony (szary, na wierzchu)
            if navigating && from > 1 {
                let traveledPts = Geo.slice(r.polyline, from: 0, to: from, cumulative: cum)
                add(&traveled, traveledPts, LineStyle(color: UIColor(hex: 0x94A3B8), width: 10, alpha: 0.8, relative: 0.7))
            }

            // 4. Korki (kolorowe odcinki)
            let levelColors: [Int: UInt32] = [1: 0xF59E0B, 2: 0xEF4444, 3: 0xB91C1C]
            for level in 1...3 {
                for s in r.trafficSpans where min(s.level, 3) == level {
                    let a = max(s.startMeters, 0), b = min(s.startMeters + s.lengthMeters, total)
                    guard b > a else { continue }
                    add(&spansOut, Geo.slice(r.polyline, from: a, to: b, cumulative: cum),
                        LineStyle(color: UIColor(hex: levelColors[level] ?? 0xF59E0B), width: 10, relative: 0.70))
                }
            }

            routeLines = altsG + transitG + fullRoute + traveled + dots + spansOut

            // 5. Strzałka skrętu i groty
            var arrow: [StyledLine] = []
            var heads: [KiteAnnotation] = []
            if let n = model.nav, let m = n.nextManeuver, m.type != .arrive, m.type != .depart, m.type != .straight,
               let p = n.progress, m.alongMeters - p.alongMeters < 600 {
                var end = m.alongMeters + 22
                if m.type == .roundabout,
                   let out = n.route.maneuvers.first(where: { $0.leavesRoundabout && $0.alongMeters > m.alongMeters }),
                   out.alongMeters - m.alongMeters < 250 {
                    end = out.alongMeters + 22
                }
                let a = max(m.alongMeters - 35, from), b = min(end, total)
                let shaft = Geo.slice(r.polyline, from: a, to: b, cumulative: cum)
                if shaft.count >= 2 {
                    let tip = shaft[shaft.count - 1]
                    let prev = Geo.point(along: r.polyline, meters: max(a, b - 4), cumulative: cum)
                    add(&arrow, shaft, LineStyle(color: .black, width: 17, alpha: 0.35, relative: 0.85))
                    add(&arrow, shaft, LineStyle(color: UIColor(hex: 0x0F766E), width: 15, relative: 0.72))
                    add(&arrow, shaft, LineStyle(color: .white, width: 9, relative: 0.42))
                    let head = KiteAnnotation(layer: .turnHead, id: "turn-head", coordinate: coord(tip))
                    head.icon = "turn-head"
                    head.bearing = Geo.bearing(prev, tip)
                    heads.append(head)
                }
            }
            arrowLines = arrow
            replaceAnnotations(&headAnns, heads, map)

            // 6. Dymki z czasem (przy planowaniu trasy)
            guard model.nav == nil, let d = model.directions else { replaceAnnotations(&bubbleAnns, [], map); return }
            var bubbles: [KiteAnnotation] = []
            for (i, route) in d.current.enumerated() {
                let others = d.current.enumerated().filter { $0.offset != i }.map(\.element.polyline)
                let c = Geo.cumulative(route.polyline)
                let len = c.last ?? 0
                var spot = Geo.point(along: route.polyline, meters: len * 0.5, cumulative: c)
                for f in stride(from: 0.5, through: 0.9, by: 0.1) {
                    let p = Geo.point(along: route.polyline, meters: len * f, cumulative: c)
                    let shared = others.contains { o in o.contains { $0.distance(to: p) < 120 } }
                    if !shared { spot = p; break }
                }
                let b = KiteAnnotation(layer: .bubble, id: "bubble\(i)", coordinate: coord(spot))
                b.label = Fmt.duration(route.durationSeconds)
                b.routeSelected = route.id == r.id
                b.routeIndex = i
                bubbles.append(b)
            }
            replaceAnnotations(&bubbleAnns, bubbles, map)
        }

        // MARK: Loading things for the view

        /** Live Waze reports for the view and a margin, asked again after two minutes or when the map leaves the box. */
        func loadWaze(_ map: MKMapView) {
            let s = model.settings
            if s.wazeOn, s.wazeHeatmap || s.policeRisk, !DemoScript.active {
                var places: [LatLng] = []
                if let c = map.userLocation.location?.coordinate, CLLocationCoordinate2DIsValid(c) { places.append(LatLng(c.latitude, c.longitude)) }
                if let h = s.home { places.append(h.location) }
                if let w = s.work { places.append(w.location) }
                WazeHistory.shared.sweepIfDue(places)
                // Waze's live map od października 2026 nie dzieli się policją — bierzemy ją z app servers WazeLive.
                if settings.wazeOn, settings.wazePolice, Date().timeIntervalSince(policeSweptAt) > 600 {
                    policeSweptAt = Date()
                    Task { @MainActor in model.sweepPoliceNearby() }
                }
            }
            guard s.wazeOn, s.wazeOnMap || s.wazeHeatmap, map.zoomLevel >= 10, wazeFetch == nil, !DemoScript.fakeWaze,
                  Date().timeIntervalSince(wazeFailedAt) > 60 else { return }
            let b = map.visibleCoordinateBounds
            if let r = wazeBox, b.sw.latitude >= r.s, b.sw.longitude >= r.w, b.ne.latitude <= r.n, b.ne.longitude <= r.e,
               Date().timeIntervalSince(wazeAt) < 120 { return }
            let dLat = (b.ne.latitude - b.sw.latitude) * 0.3, dLng = (b.ne.longitude - b.sw.longitude) * 0.3
            let box = (s: b.sw.latitude - dLat, w: b.sw.longitude - dLng, n: b.ne.latitude + dLat, e: b.ne.longitude + dLng)
            guard box.n - box.s < 1.5, box.e - box.w < 2.5 else { return }
            wazeFetch = Task { [weak self, weak map] in
                let found = await Waze.alerts(south: box.s, west: box.w, north: box.n, east: box.e)
                guard let self else { return }
                self.wazeFetch = nil
                guard let found else { self.wazeFailedAt = Date(); return }
                self.wazeAlerts = found
                self.wazeBox = box
                self.wazeAt = Date()
                WazeHistory.shared.record(found)
                self.model.wazeLiveCount = found.filter { self.model.settings.shows($0) }.count
                self.model.updateAreaRisk(live: found)
                if let map { self.render(map) }
            }
        }

        /** For the build's screenshots: made-up reports, so the badges and glow show without Waze. */
        func showDemoWaze(_ list: [WazeAlert], map: MKMapView) {
            wazeAlerts = list
            wazeAt = Date()
            model.wazeLiveCount = list.count
            model.updateAreaRisk(live: list)
            render(map)
        }

        /** Metro, tram and rail lines in their own colours, from the cached shapes. */
        private func rebuildRail() {
            var cases: [StyledLine] = [], colored: [StyledLine] = []
            if model.settings.transitLines && model.nav == nil {
                for shape in railShapes {
                    if let l = makeLine(shape.points, LineStyle(color: dark ? .black : .white, width: 5.5, alpha: 0.9)) { cases.append(l) }
                    if let l = makeLine(shape.points, LineStyle(color: UIColor(hex: shape.color), width: 3.2)) { colored.append(l) }
                }
            }
            railLines = cases + colored
            overlaysDirty = true
        }

        /** Transit lines for the view and a margin around it, when the layer is on. */
        func loadRail(_ map: MKMapView) {
            guard model.settings.transitLines, map.zoomLevel >= 10, railFetch == nil, model.nav == nil else { return }
            let b = map.visibleCoordinateBounds
            let z = Int(map.zoomLevel)
            if let r = railBox, b.sw.latitude >= r.s, b.sw.longitude >= r.w, b.ne.latitude <= r.n, b.ne.longitude <= r.e,
               abs(z - r.z) <= 2 { return }
            let dLat = (b.ne.latitude - b.sw.latitude) * 0.5, dLng = (b.ne.longitude - b.sw.longitude) * 0.5
            let box = (s: b.sw.latitude - dLat, w: b.sw.longitude - dLng, n: b.ne.latitude + dLat, e: b.ne.longitude + dLng, z: z)
            railFetch = Task { [weak self, weak map] in
                let lines = await Transitous.lines(south: box.s, west: box.w, north: box.n, east: box.e, zoom: min(z, 14))
                guard let self else { return }
                self.railFetch = nil
                if let lines {
                    self.railBox = box
                    self.railShapes = lines.map { (points: $0.points, color: UInt32($0.color)) }
                    self.rebuildRail()
                    if let map { self.syncOverlays(map) }
                }
                // The map may have moved on while this was loading.
                if lines != nil, let map { self.loadRail(map) }
            }
        }

        /** Ask Overpass for the cameras in view, a few 0.1° cells at a time, each cell once. */
        func loadCameras(_ map: MKMapView) {
            let s = model.settings
            guard s.speedCameras || s.plateCameras, map.zoomLevel >= 12, cameraFetch == nil else { return }
            let b = map.visibleCoordinateBounds
            let cell = 0.1
            let y0 = Int(floor(b.sw.latitude / cell)), y1 = Int(floor(b.ne.latitude / cell))
            let x0 = Int(floor(b.sw.longitude / cell)), x1 = Int(floor(b.ne.longitude / cell))
            guard (y1 - y0 + 1) * (x1 - x0 + 1) <= 12 else { return }
            var missing: [(Int, Int)] = []
            for y in y0...y1 { for x in x0...x1 where !cameraCells.contains("\(y),\(x)") { missing.append((y, x)) } }
            guard !missing.isEmpty else { return }
            let ys = missing.map(\.0), xs = missing.map(\.1)
            let south = Double(ys.min()!) * cell, north = Double(ys.max()! + 1) * cell
            let west = Double(xs.min()!) * cell, east = Double(xs.max()! + 1) * cell
            cameraFetch = Task { [weak self, weak map] in
                // Both kinds every time, so turning one on later needs no new fetch.
                let found = await Overpass.cameras(south: south, west: west, north: north, east: east, speed: true, plate: true)
                guard let self else { return }
                self.cameraFetch = nil
                guard let found else { return }
                for (y, x) in missing { self.cameraCells.insert("\(y),\(x)") }
                for c in found { self.cameras[c.id] = c }
                guard let map else { return }
                self.render(map)
                // The map may have moved on while this one was loading.
                self.loadCameras(map)
            }
        }

        // MARK: Gestures

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        /** A tap on a pin or badge belongs to that pin, not to the empty map. */
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var v: UIView? = touch.view
            while let cur = v {
                if let av = cur as? KiteAnnotationView, av.isEnabled { return false }
                v = cur.superview
            }
            return true
        }

        @objc func tapped(_ g: UITapGestureRecognizer) {
            guard let map = g.view as? MKMapView, model.nav == nil, Date().timeIntervalSince(pinDroppedAt) > 1 else { return }
            let pt = g.location(in: map)
            // Give the map a moment to pick a place under the finger first; if it did, that wins.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak map] in
                guard let self, let map, Date().timeIntervalSince(self.lastPickAt) > 0.6 else { return }
                self.emptyTap(at: pt, map)
            }
        }

        private func emptyTap(at pt: CGPoint, _ map: MKMapView) {
            if let d = model.directions {
                // Tapping another route's line picks that route.
                let c = map.convert(pt, toCoordinateFrom: map)
                let tapped = LatLng(c.latitude, c.longitude)
                let metersPerPoint = map.visibleMapRect.width / Double(max(map.bounds.width, 1)) / MKMapPointsPerMeterAtLatitude(c.latitude)
                let tolerance = max(60, metersPerPoint * 36)
                if let i = d.current.firstIndex(where: { r in r.id != d.route?.id && r.polyline.contains { $0.distance(to: tapped) < tolerance } }) {
                    model.selectRoute(i)
                }
                return
            }
            if model.selected != nil {
                model.closePlace()
            } else if !model.results.isEmpty {
                model.detent = .peek
            }
        }

        @objc func userMoved(_ g: UIGestureRecognizer) {
            // Only disable following if the user is actually panning/pinching/twisting the map
            guard g.state == .began || g.state == .changed else { return }
            if let n = model.nav, n.following {
                // We add a small delay to distinguish between a real user gesture and a minor map update
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    if g.state == .began || g.state == .changed {
                        n.following = false
                    }
                }
            }
        }

        @objc func pressed(_ g: UILongPressGestureRecognizer) {
            guard g.state == .began, let map = g.view as? MKMapView else { return }
            pinDroppedAt = Date()
            let c = map.convert(g.location(in: map), toCoordinateFrom: map)
            guard model.nav == nil, model.directions == nil else { return }
            Haptics.success()
            model.dropPin(at: LatLng(c.latitude, c.longitude))
        }

        // MARK: Map delegate

        func mapView(_ map: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let a = annotation as? KiteAnnotation else { return nil }
            let id = "kite-\(a.layer)"
            let v = (map.dequeueReusableAnnotationView(withIdentifier: id) as? KiteAnnotationView)
                ?? KiteAnnotationView(annotation: a, reuseIdentifier: id)
            v.annotation = a
            v.configure(a, dark: dark)
            v.applyRotation(in: map)
            // Signs pop up the first time they show: with a bounce while you drive, softly otherwise.
            if a.layer == .roadEvent || a.layer == .waze || a.layer == .camera {
                if poppedSigns.insert("\(a.layer)\(a.id)").inserted {
                    if poppedSigns.count > 800 { poppedSigns = ["\(a.layer)\(a.id)"] }
                    v.popIn(strong: model.nav != nil)
                }
            }
            return v
        }

        func mapView(_ map: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let line = overlay as? MKPolyline, let st = lineStyles[ObjectIdentifier(line)] {
                if let colors = st.gradient {
                    let r = RoadGradientRenderer(polyline: line)
                    r.setColors(colors, locations: [0, 1])
                    r.relative = st.relative ?? 1
                    r.lineWidth = st.width
                    r.lineCap = .round
                    r.lineJoin = .round
                    return r
                }
                if let rel = st.relative {
                    let r = RoadLineRenderer(polyline: line)
                    r.relative = rel
                    r.strokeColor = st.color.withAlphaComponent(st.alpha)
                    r.lineWidth = st.width
                    r.lineCap = .round
                    r.lineJoin = .round
                    r.lineDashPattern = st.dash
                    return r
                }
                let r = MKPolylineRenderer(polyline: line)
                r.strokeColor = st.color.withAlphaComponent(st.alpha)
                r.lineWidth = st.width
                r.lineCap = .round
                r.lineJoin = .round
                r.lineDashPattern = st.dash
                return r
            }
            if let heat = overlay as? HeatOverlay {
                let r = HeatRenderer(overlay: heat)
                r.alpha = 0.85
                return r
            }
            if let tiles = overlay as? MKTileOverlay {
                let r = MKTileOverlayRenderer(tileOverlay: tiles)
                r.alpha = tiles is DWDRadarOverlay ? 0.75 : (dark ? 0.22 : 0.32)
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ map: MKMapView, didSelect view: MKAnnotationView) {
            // A place on Apple's own map (a cafe, a station…).
            if let f = view.annotation as? MKMapFeatureAnnotation {
                map.deselectAnnotation(f, animated: false)
                guard model.nav == nil, model.directions == nil, Date().timeIntervalSince(pinDroppedAt) > 1,
                      let name = f.title, !name.isEmpty else { return }
                lastPickAt = Date()
                model.resolveTapped(name: name, at: LatLng(f.coordinate.latitude, f.coordinate.longitude))
                return
            }
            guard let a = view.annotation as? KiteAnnotation else { return }
            map.deselectAnnotation(a, animated: false)
            guard model.nav == nil else { return }
            lastPickAt = Date()
            switch a.layer {
            case .bubble:
                if model.directions != nil, !a.routeSelected { model.selectRoute(a.routeIndex) }
            case .waze:
                guard model.directions == nil, let alert = wazeAlerts.first(where: { $0.id == a.id }) else { return }
                Haptics.select()
                model.wazeInfo = alert
            case .fuel:
                let fuel = FuelPrices.shared
                guard let station = (fuel.stations + fuel.ahead).first(where: { $0.id == a.id }) else { return }
                Haptics.select()
                model.fuelInfo = station
            case .roadEvent:
                guard let event = RoadEvents.shared.events.first(where: { $0.id == a.id }) else { return }
                Haptics.select()
                model.roadInfo = event
            case .mine:
                guard model.directions == nil, let place = model.myPlace(a.id) else { return }
                model.select(place)
            case .result:
                guard model.directions == nil, let place = model.results.first(where: { $0.id == a.id }) else { return }
                model.select(place)
            default:
                break
            }
        }

        func mapView(_ map: MKMapView, regionWillChangeAnimated animated: Bool) {
            // Obsługę gestów użytkownika robi metoda `userMoved`.
        }

        func mapViewDidChangeVisibleRegion(_ map: MKMapView) {
            for a in headAnns {
                if let v = map.view(for: a) as? KiteAnnotationView { v.applyRotation(in: map) }
            }
        }

        func mapView(_ map: MKMapView, regionDidChangeAnimated animated: Bool) {
            // Zooming across a layer's limit shows or hides it.
            let z = map.zoomLevel
            let now = [z >= 11, z >= 14, z >= 11, z >= 9]
            if now != gates { render(map) }
            loadCameras(map)
            loadWaze(map)
            loadRail(map)
            loadRoadEvents(map)
            loadFuel(map)
            renderRoadEvents(map)
            renderFuel(map)
            noteHeading(map)
        }

        /** The compass button shows while the map isn't facing north. */
        private func noteHeading(_ map: MKMapView) {
            let h = map.camera.heading
            let shown = (h < 0.5 || h > 359.5) ? 0 : h
            if abs(shown - model.mapHeading) > 2 || (shown == 0) != (model.mapHeading == 0) { model.mapHeading = shown }
        }

        func mapView(_ map: MKMapView, didUpdate userLocation: MKUserLocation) {
            guard let loc = userLocation.location, !movedToUser else { return }
            movedToUser = true
            guard model.results.isEmpty, model.selected == nil else { return }
            map.setCenter(loc.coordinate, zoomLevel: 15, animated: false)
        }
    }
}