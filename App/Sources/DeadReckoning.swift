import CoreLocation
import CoreMotion
import Foundation

/**
 * GPS is the measurement. Between fixes, and when the sky drops out, the car keeps moving
 * from the phone's motion: Core Motion's attitude (gyro, held upright by the accelerometer)
 * turns the last GPS course, and the accelerometer updates the speed along the car.
 * A pressure rise marks a tunnel and the estimate is pulled onto the route.
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
    private var speed = 0.0
    private var heading = 0.0
    private var ready = false
    private var lockYaw: Double?
    private var lockCourse: Double?
    private var forward: (x: Double, y: Double, z: Double)?
    private var lastMotion: Date?
    private var lastGps: Date?
    private var lastGpsSpeed = 0.0
    private var lastEmit: Date?
    private var pressureBase: Double?
    private var pressureTunnel = false
    private var weakGps = false
    private var route: [LatLng] = []
    /// Fired while the sky is gone, so the puck keeps moving after GPS stops.
    var onCoast: ((ReckoningFix) -> Void)?

    func start() {
        guard !started else { return }
        started = true
        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 1.0 / 30.0
            motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] dm, _ in
                guard let self, let dm else { return }
                self.integrate(dm)
            }
        }
        if CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
                guard let self, let data else { return }
                let p = data.pressure.doubleValue
                if self.pressureBase == nil { self.pressureBase = p }
                if let base = self.pressureBase, p - base > 1.2 { self.pressureTunnel = true }
                if let base = self.pressureBase, p - base < 0.4 { self.pressureTunnel = false }
            }
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        started = false
        ready = false
        lockYaw = nil
        lockCourse = nil
    }

    /// A GPS measurement. Motion keeps integrating on its own after this returns.
    func fuse(_ gps: CLLocation, route line: [LatLng]) -> ReckoningFix {
        if MindSettings.shared.resetAsked {
            MindSettings.shared.resetAsked = false
            stop()
            pressureBase = nil
            pressureTunnel = false
            ready = false
            forward = nil
            lockYaw = nil
            lockCourse = nil
        }
        start()
        route = line
        let acc = gps.horizontalAccuracy
        let limit = Double(max(25, MindSettings.shared.gpsTrust))
        let trim = Double(MindSettings.shared.headingTrim)
        weakGps = pressureTunnel || acc < 0 || acc > limit
        let now = gps.timestamp
        if !ready {
            lat = gps.coordinate.latitude
            lng = gps.coordinate.longitude
            speed = max(0, gps.speed)
            ready = true
        }
        if !weakGps {
            if gps.course >= 0 {
                let course = wrap(gps.course + trim)
                heading = course
                lockCourse = course
                if let dm = motion.deviceMotion { lockYaw = dm.attitude.yaw * 180 / .pi }
            }
            if gps.speed >= 0 {
                if let dm = motion.deviceMotion, let prev = lastGps {
                    let dv = (gps.speed - lastGpsSpeed) / max(0.2, now.timeIntervalSince(prev))
                    learnForward(dm, along: dv)
                }
                speed = gps.speed
                lastGpsSpeed = gps.speed
            }
            let r = max(4, acc)
            let gain = min(0.85, 400 / (r * r))
            lat += gain * (gps.coordinate.latitude - lat)
            lng += gain * (gps.coordinate.longitude - lng)
            lastGps = now
        }
        return makeFix(at: now, weight: weakGps ? 0 : 0.7)
    }

    /// One motion sample: turn the heading with the gyro and, without GPS, the speed with the accelerometer.
    private func integrate(_ dm: CMDeviceMotion) {
        let now = Date()
        let dt = min(0.2, max(0.005, lastMotion.map { now.timeIntervalSince($0) } ?? 0.03))
        lastMotion = now
        guard ready else { return }
        let yaw = dm.attitude.yaw * 180 / .pi
        if let lockYaw, let lockCourse {
            heading = wrap(lockCourse + wrapSigned(yaw - lockYaw))
        }
        let stale = lastGps.map { now.timeIntervalSince($0) > 1.1 } ?? true
        let coast = pressureTunnel || weakGps || stale
        if coast, let forward {
            let h = horizontal(dm)
            let a = (h.x * forward.x + h.y * forward.y + h.z * forward.z) * 9.81
            speed = min(70, max(0, speed + a * dt))
        }
        let rad = heading * .pi / 180
        lat += speed * cos(rad) * dt / 110_540
        lng += speed * sin(rad) * dt / (111_320 * max(0.2, cos(lat * .pi / 180)))
        if coast { snapToRoute() }
        guard coast, lastEmit.map({ now.timeIntervalSince($0) >= 0.1 }) ?? true else { return }
        lastEmit = now
        onCoast?(makeFix(at: now, weight: 0))
    }

    /// Which way the car points in the phone's axes, learned from real speed changes.
    private func learnForward(_ dm: CMDeviceMotion, along dv: Double) {
        let h = horizontal(dm)
        let mag = (h.x * h.x + h.y * h.y + h.z * h.z).squareRoot()
        guard abs(dv) > 0.35, mag > 0.04 else { return }
        let s = dv > 0 ? 1.0 : -1.0
        let ux = s * h.x / mag, uy = s * h.y / mag, uz = s * h.z / mag
        if var f = forward {
            f.x = f.x * 0.85 + ux * 0.15
            f.y = f.y * 0.85 + uy * 0.15
            f.z = f.z * 0.85 + uz * 0.15
            let n = max(0.05, (f.x * f.x + f.y * f.y + f.z * f.z).squareRoot())
            forward = (f.x / n, f.y / n, f.z / n)
        } else {
            forward = (ux, uy, uz)
        }
    }

    private func horizontal(_ dm: CMDeviceMotion) -> (x: Double, y: Double, z: Double) {
        let a = dm.userAcceleration
        let g = dm.gravity
        let n = max(0.2, (g.x * g.x + g.y * g.y + g.z * g.z).squareRoot())
        let gx = g.x / n, gy = g.y / n, gz = g.z / n
        let dot = a.x * gx + a.y * gy + a.z * gz
        return (a.x - dot * gx, a.y - dot * gy, a.z - dot * gz)
    }

    private func snapToRoute() {
        guard route.count >= 2 else { return }
        let proj = Geo.project(LatLng(lat, lng), on: route)
        let snapped = Geo.point(along: route, meters: proj.along)
        let pull = pressureTunnel || weakGps ? 0.94 : 0.72
        lat += (snapped.lat - lat) * pull
        lng += (snapped.lng - lng) * pull
        let back = Geo.point(along: route, meters: max(0, proj.along - 8))
        heading = Geo.bearing(back, snapped)
    }

    private func makeFix(at time: Date, weight: Double) -> ReckoningFix {
        let stale = lastGps.map { time.timeIntervalSince($0) > 1.1 } ?? true
        let coast = pressureTunnel || weakGps || stale
        let loc = CLLocation(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng),
                             altitude: 0, horizontalAccuracy: coast ? 35 : 8,
                             verticalAccuracy: -1, course: heading, speed: speed, timestamp: time)
        let label = pressureTunnel ? "Tunel · czujniki" : (coast ? "Słaby GPS · czujniki" : "GPS")
        return ReckoningFix(location: loc, gpsWeight: weight, tunnel: coast, label: label)
    }

    private func wrap(_ c: Double) -> Double {
        var x = c
        while x < 0 { x += 360 }
        while x >= 360 { x -= 360 }
        return x
    }

    private func wrapSigned(_ d: Double) -> Double {
        var x = d
        while x > 180 { x -= 360 }
        while x < -180 { x += 360 }
        return x
    }
}
