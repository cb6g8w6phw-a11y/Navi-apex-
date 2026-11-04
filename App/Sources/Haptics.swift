import UIKit

@MainActor
enum Haptics {
    enum Level: String, CaseIterable, Identifiable {
        case off, light, medium, strong
        var id: String { rawValue }
        var label: String {
            switch self {
            case .off: return "Off"
            case .light: return "Light"
            case .medium: return "Medium"
            case .strong: return "Strong"
            }
        }
    }
    static var level: Level {
        get { Level(rawValue: UserDefaults.standard.string(forKey: "hapticLevel") ?? "") ?? .medium }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "hapticLevel") }
    }
    static func tap() { play(.light) }
    static func light() { play(.light) }
    static func select() { play(.light) }
    static func success() { play(.medium) }
    static func warning() { play(.strong) }
    static func play(_ min: Level) {
        let l = level
        guard l != .off else { return }
        let order: [Level] = [.off, .light, .medium, .strong]
        guard let a = order.firstIndex(of: l), let b = order.firstIndex(of: min), a >= b else { return }
        switch l {
        case .off: return
        case .light: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .medium: UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .strong: UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        }
    }
}
