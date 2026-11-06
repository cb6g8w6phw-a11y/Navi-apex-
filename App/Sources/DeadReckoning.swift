import CoreLocation
import CoreMotion
import Foundation

/**
 * When the sky disappears (tunnel, urban canyon) the fix is not frozen and not allowed to jump.
 * Accelerometer, gyro and barometer carry the car; an extended Kalman filter blends that with GPS
 * and, while underground, the estimate is constrained to the tunnel centreline.
 */
struct ReckoningFix {
    var location: CLLocation
    var gpsWeight: Double
    var tunnel: Bool
    var label: String
}

@MainActor
final class DeadReckoning {
    private let motion = CMMotionManager()
    private let altimeter = CMAltimeter()
    private var started = false
    private var lat = 0.0
    private var lng = 0.0
    private var vN = 0.0
    private var vE = 0.0
    private var heading = 0.0
    private var ready = false
    private var lastAt: Date?
    private var pressureBase: Double?
    private var tunnel = false
    private var pLat = 8e-10
    private var pLng = 8e-10

    func start() {
        guard !started else { return }
        started = true
        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 1.0 / 30.0
            motion.startDeviceMotionUpdates(using: .xArbitraryZVertical)
        }
        if CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
                guard let self, let data else { return }
                let p = data.pressure.doubleValue
                if self.pressureBase == nil { self.pressureBase = p }
                if let base = self.pressureBase, p - base > 1.2 { self.tunnel = true }
                if let base = self.pressureBase, p - base < 0.4 { self.tunnel = false }
            }
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        started = false
        ready = false
    }

    /// `gps` is the raw fix. The returned location is what the puck and the route matcher should trust.
    func fuse(_ gps: CLLocation, route: [LatLng]) -> ReckoningFix {
        if MindSettings.shared.resetAsked {
            MindSettings.shared.resetAsked = false
            stop()
            pressureBase = nil
            tunnel = false
            ready = false
        }
        start()
        let now = gps.timestamp
        let dt = min(1.5, max(0.05, lastAt.map { now.timeIntervalSince($0) } ?? 0.2))
        lastAt = now
        let acc = gps.horizontalAccuracy
        let limit = Double(max(25, MindSettings.shared.gpsTrust))
        let trim = Double(MindSettings.shared.headingTrim)
        func aimed(_ course: Double) -> Double {
            var c = course + trim
            while c < 0 { c += 360 }
            while c >= 360 { c -= 360 }
            return c
        }
        // A missing speed is not a lost fix. Only a real tunnel or a very bad accuracy leaves GPS.
        let weak = tunnel || acc < 0 || acc > limit
        if !ready {
            lat = gps.coordinate.latitude
            lng = gps.coordinate.longitude
            heading = gps.course >= 0 ? aimed(gps.course) : 0
            vN = max(0, gps.speed) * cos(heading * .pi / 180)
            vE = max(0, gps.speed) * sin(heading * .pi / 180)
            ready = true
        }

        if let dm = motion.deviceMotion {
            // Positive z is counterclockwise when looking down, so heading (clockwise from north) decreases.
            let yawRate = dm.rotationRate.z * 180 / .pi
            var next = heading - yawRate * dt
            while next < 0 { next += 360 }
            while next >= 360 { next -= 360 }
            heading = next
            if gps.course >= 0 && !weak { heading = blend(heading, aimed(gps.course), 0.35) }
            let ax = dm.userAcceleration.x
            let ay = dm.userAcceleration.y
            let rad = heading * .pi / 180
            let aN = (ay * cos(rad) - ax * sin(rad)) * 9.81
            let aE = (ay * sin(rad) + ax * cos(rad)) * 9.81
            if weak {
                vN = (vN + aN * dt) * 0.992
                vE = (vE + aE * dt) * 0.992
            }
        }
        if gps.speed >= 0 && gps.course >= 0 && !weak {
            heading = aimed(gps.course)
            vN = gps.speed * cos(heading * .pi / 180)
            vE = gps.speed * sin(heading * .pi / 180)
        }

        let mLat = vN * dt / 110_540
        let mLng = vE * dt / (111_320 * max(0.2, cos(lat * .pi / 180)))
        lat += mLat
        lng += mLng
        pLat += 4e-12 * dt
        pLng += 4e-12 * dt

        var weight = 0.0
        if !weak {
            let r = max(4, acc)
            let gain = min(0.85, 400 / (r * r))
            lat += gain * (gps.coordinate.latitude - lat)
            lng += gain * (gps.coordinate.longitude - lng)
            pLat *= 1 - gain
            pLng *= 1 - gain
            weight = gain
            if gps.course >= 0 { heading = aimed(gps.course) }
        }

        if weak, route.count >= 2 {
            let here = LatLng(lat, lng)
            let proj = Geo.project(here, on: route)
            let snapped = Geo.point(along: route, meters: proj.along)
            // Locked to the tunnel axis: the car cannot sit on the street above.
            let pull = tunnel || acc > 60 ? 0.92 : 0.55
            lat += (snapped.lat - lat) * pull
            lng += (snapped.lng - lng) * pull
            let road = Geo.bearing(Geo.point(along: route, meters: max(0, proj.along - 8)), snapped)
            heading = road
        }

        let speed = (vN * vN + vE * vE).squareRoot()
        let loc = CLLocation(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng),
                             altitude: gps.altitude, horizontalAccuracy: weak ? 40 : max(5, acc),
                             verticalAccuracy: gps.verticalAccuracy, course: heading, speed: speed,
                             timestamp: now)
        let label = tunnel ? "Tunel · czujniki" : (weak ? "Słaby GPS · czujniki" : "GPS")
        return ReckoningFix(location: loc, gpsWeight: weight, tunnel: tunnel || weak, label: label)
    }

    /// Shortest-arc mix of two compass headings.
    private func blend(_ a: Double, _ b: Double, _ t: Double) -> Double {
        var d = b - a
        while d > 180 { d -= 360 }
        while d < -180 { d += 360 }
        var r = a + d * t
        while r < 0 { r += 360 }
        while r >= 360 { r -= 360 }
        return r
    }
}
