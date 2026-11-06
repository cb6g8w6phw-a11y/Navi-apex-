import Foundation

extension Geo {
    /// Fill long chords so the stroke stays on the bends instead of cutting across them.
    public static func densify(_ line: [LatLng], step: Double = 18) -> [LatLng] {
        guard line.count >= 2, step > 2 else { return line }
        var out: [LatLng] = [line[0]]
        out.reserveCapacity(line.count * 2)
        for i in 1..<line.count {
            let a = line[i - 1], b = line[i]
            let d = a.distance(to: b)
            if d > step {
                let n = Int(ceil(d / step))
                if n > 1 && n < 400 {
                    for k in 1..<n {
                        let f = Double(k) / Double(n)
                        out.append(LatLng(a.lat + (b.lat - a.lat) * f, a.lng + (b.lng - a.lng) * f))
                    }
                }
            }
            if let last = out.last, last.distance(to: b) < 0.4 { continue }
            out.append(b)
        }
        return out
    }

    /// Slice that keeps a join under the car and never returns a broken stub.
    public static func routeSlice(_ line: [LatLng], from: Double, to: Double, cumulative cum: [Double]? = nil) -> [LatLng] {
        let c = cum ?? cumulative(line)
        let total = c.last ?? 0
        guard total > 1 else { return line }
        let a = min(max(0, from), max(0, total - 3))
        let b = min(max(a + 3, to), total)
        let pts = slice(line, from: a, to: b, cumulative: c)
        return pts.count >= 2 ? pts : line
    }

    public struct Chevron {
        public var point: LatLng
        public var bearing: Double
        public var along: Double
    }

    /// Direction marks along the road. Stable `along` values so the icons are not reborn every frame.
    public static func chevrons(on line: [LatLng], from: Double, to: Double, every: Double = 150, limit: Int = 40, cumulative cum: [Double]? = nil) -> [Chevron] {
        let c = cum ?? cumulative(line)
        let total = c.last ?? 0
        guard total > 1, every > 10 else { return [] }
        var out: [Chevron] = []
        var m = max(0, from)
        let end = min(total, to)
        while m < end && out.count < limit {
            let p = point(along: line, meters: m, cumulative: c)
            let ahead = point(along: line, meters: min(total, m + 18), cumulative: c)
            let back = point(along: line, meters: max(0, m - 8), cumulative: c)
            out.append(Chevron(point: p, bearing: bearing(back, ahead), along: m))
            m += every
        }
        return out
    }
}
