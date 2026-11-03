import Foundation

/**
 * When to say you're over the posted limit (ported from Vela's SpeedingAlerts): a GPS blip
 * over the limit never speaks, a long stretch over it speaks once, and slowing down then
 * speeding up again speaks again. The tolerance matches the speed badge's red state.
 */
public struct SpeedingAlerts {
    public var toleranceKmh = 5.0
    /** How long you must stay over before it speaks. */
    public var hold: TimeInterval = 4
    /** How long you must stay back under before the next time can speak. */
    public var rearm: TimeInterval = 8
    /** Never more often than this. */
    public var minGap: TimeInterval = 45

    private var overSince: TimeInterval?
    private var underSince: TimeInterval?
    private var armed = true
    private var lastSpoken = -TimeInterval.greatestFiniteMagnitude

    public init() {}

    /** Feed each fix; true when the alert should be spoken now. */
    public mutating func update(speedKmh: Double?, limitKmh: Double?, now: TimeInterval) -> Bool {
        guard let speed = speedKmh, let limit = limitKmh, limit > 0 else {
            overSince = nil
            return false
        }
        guard speed > limit + toleranceKmh else {
            overSince = nil
            if underSince == nil { underSince = now }
            if now - (underSince ?? now) >= rearm { armed = true }
            return false
        }
        underSince = nil
        if overSince == nil { overSince = now }
        guard armed, now - (overSince ?? now) >= hold, now - lastSpoken >= minGap else { return false }
        armed = false
        lastSpoken = now
        return true
    }
}
