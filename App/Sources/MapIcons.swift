import UIKit

/** The images Vela's map layers draw: category pins, the red picked pin, the puck, route bubbles. */
enum MapIcons {
    struct Kind {
        let name: String
        let symbol: String
        let color: UInt32
        let words: [String]
    }

    static let kinds: [Kind] = [
        Kind(name: "cat-coffee", symbol: "cup.and.saucer.fill", color: 0xE8710A, words: ["coffee", "cafe", "café", "bakery", "tea", "donut"]),
        Kind(name: "cat-food", symbol: "fork.knife", color: 0xE8453C, words: ["restaurant", "food", "pizza", "sushi", "burger", "grill", "bar", "pub", "diner", "taco", "bistro", "steak", "ramen", "noodle", "kitchen", "eatery", "sandwich", "chicken"]),
        Kind(name: "cat-gas", symbol: "fuelpump.fill", color: 0x1A73E8, words: ["gas", "fuel", "petrol", "charging"]),
        Kind(name: "cat-shop", symbol: "cart.fill", color: 0x1A73E8, words: ["grocery", "supermarket", "store", "shop", "market", "mall", "pharmacy", "drugstore"]),
        Kind(name: "cat-hotel", symbol: "bed.double.fill", color: 0xD01884, words: ["hotel", "motel", "inn", "lodging", "hostel", "resort"]),
        Kind(name: "cat-park", symbol: "leaf.fill", color: 0x188038, words: ["park", "garden", "trail", "playground", "beach"]),
        Kind(name: "cat-health", symbol: "cross.case.fill", color: 0xC5221F, words: ["hospital", "clinic", "doctor", "dentist", "medical", "urgent"]),
        Kind(name: "cat-transit", symbol: "tram.fill", color: 0x12B5A5, words: ["station", "bus", "subway", "metro", "train", "airport"]),
        Kind(name: "cat-money", symbol: "banknote.fill", color: 0x5F6368, words: ["atm", "bank"]),
        Kind(name: "cat-parking", symbol: "parkingsign", color: 0x1A73E8, words: ["parking", "garage"]),
    ]

    static func iconName(for p: Place) -> String {
        let c = (p.category ?? "").lowercased()
        return kinds.first { k in k.words.contains { c.contains($0) } }?.name ?? "cat-default"
    }

    private static var cache: [String: UIImage] = [:]

    /** The picture for an icon name used by the map layers (category pins, cameras, Waze badges, the car…). */
    static func image(_ name: String, dark: Bool) -> UIImage? {
        let key = name == "puck" ? "puck-\(dark)" : name
        if let hit = cache[key] { return hit }
        let img: UIImage?
        if let k = kinds.first(where: { $0.name == name }) {
            img = dot(k.symbol, UIColor(hex: k.color))
        } else if name.hasPrefix("waze-"), let k = WazeAlert.Kind(rawValue: String(name.dropFirst(5))) {
            img = waze(k)
        } else {
            switch name {
            case "cat-default": img = dot("mappin", UIColor(hex: 0xE8453C))
            case "pin-selected": img = selectedPin()
            case "pin-origin": img = originDot()
            case "puck": img = puck(dark: dark)
            case "cam-speed": img = speedCamera()
            case "cam-plate": img = plateCamera()
            case "cam-watch": img = watchCamera()
            case "traffic-light": img = trafficLight()
            case "turn-head": img = turnHead()
            case "fuel": img = dot("fuelpump.fill", UIColor(hex: 0x2563EB))
            case "fuel-best": img = dot("fuelpump.fill", UIColor(hex: 0x16A34A))
            case "road-works": img = waze(.roadworks)
            case "road-closure": img = noEntrySign()
            case "road-warning": img = warningSign()
            case "pin-stop": img = dot("smallcircle.filled.circle", UIColor(hex: 0x5F6368))
            case "mine-home": img = dot("house.fill", UIColor(hex: 0x1A73E8))
            case "mine-work": img = dot("briefcase.fill", UIColor(hex: 0x8D6E63))
            case "mine-parking": img = dot("parkingsign", UIColor(hex: 0x1967D2))
            case "mine-saved": img = dot("bookmark.fill", UIColor(hex: 0x0F9D58))
            default: img = nil
            }
        }
        if let img { cache[key] = img }
        return img
    }

    /** The head of the turn arrow drawn on the road: chunky white with a dark teal edge and a soft shadow, pointing up. */
    static func turnHead() -> UIImage {
        let size = CGSize(width: 44, height: 40)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let p = UIBezierPath()
            p.move(to: CGPoint(x: 22, y: 6))
            p.addLine(to: CGPoint(x: 38, y: 32))
            p.addLine(to: CGPoint(x: 6, y: 32))
            p.close()
            p.lineJoinStyle = .round
            ctx.cgContext.setShadow(offset: CGSize(width: 0, height: 2), blur: 3, color: UIColor.black.withAlphaComponent(0.4).cgColor)
            UIColor(hex: 0x0F766E).setStroke()
            p.lineWidth = 8
            p.stroke()
            ctx.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
            UIColor.white.setFill()
            UIColor.white.setStroke()
            p.lineWidth = 2.5
            p.fill()
            p.stroke()
        }
    }

    static func speedCamera() -> UIImage {
        badge(UIColor(hex: 0xEF6C00)) { amber in
            UIColor.white.setFill()
            UIBezierPath(roundedRect: CGRect(x: 15, y: 12, width: 16, height: 20), cornerRadius: 3).fill()
            amber.setFill()
            UIBezierPath(ovalIn: CGRect(x: 23 - 4.6, y: 20 - 4.6, width: 9.2, height: 9.2)).fill()
            UIColor.white.setFill()
            UIBezierPath(ovalIn: CGRect(x: 21, y: 18, width: 4, height: 4)).fill()
            amber.setFill()
            UIBezierPath(rect: CGRect(x: 18, y: 26.5, width: 10, height: 3)).fill()
        }
    }

    /** A small traffic light, like Waze's: a dark upright box with red, amber and green lamps. */
    static func trafficLight() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 12, height: 25.5)).image { ctx in
            // Drawn in the old 14x30 space, shrunk to fit: same look, smaller on the map.
            ctx.cgContext.scaleBy(x: 12.0 / 14.0, y: 12.0 / 14.0)
            UIColor.white.setFill()
            UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: 14, height: 30), cornerRadius: 5).fill()
            UIColor(hex: 0x263238).setFill()
            UIBezierPath(roundedRect: CGRect(x: 1.5, y: 1.5, width: 11, height: 27), cornerRadius: 4).fill()
            for (i, c) in [0xFF3B30, 0xFFB300, 0x34C759].enumerated() {
                UIColor(hex: UInt32(c)).setFill()
                UIBezierPath(ovalIn: CGRect(x: 3.5, y: 3.5 + CGFloat(i) * 8, width: 7, height: 7)).fill()
            }
        }
    }

    /** Vela's plate reader badge: purple rounded square with a CCTV camera on a mount. */
    static func plateCamera() -> UIImage {
        badge(UIColor(hex: 0x7B1FA2)) { purple in
            UIColor.white.setFill()
            UIBezierPath(roundedRect: CGRect(x: 12, y: 18, width: 18, height: 9), cornerRadius: 2).fill()
            UIBezierPath(ovalIn: CGRect(x: 31 - 4.2, y: 22.5 - 4.2, width: 8.4, height: 8.4)).fill()
            purple.setFill()
            UIBezierPath(ovalIn: CGRect(x: 29, y: 20.5, width: 4, height: 4)).fill()
            let arm = UIBezierPath()
            arm.move(to: CGPoint(x: 17, y: 18)); arm.addLine(to: CGPoint(x: 17, y: 12))
            arm.move(to: CGPoint(x: 12, y: 12)); arm.addLine(to: CGPoint(x: 24, y: 12))
            arm.lineWidth = 2.4
            UIColor.white.setStroke()
            arm.stroke()
        }
    }

    /** A plain town camera: slate badge, small so a street of them stays readable. */
    static func watchCamera() -> UIImage {
        badge(UIColor(hex: 0x475569)) { slate in
            UIColor.white.setFill()
            UIBezierPath(roundedRect: CGRect(x: 11, y: 16, width: 16, height: 12), cornerRadius: 3).fill()
            UIBezierPath(ovalIn: CGRect(x: 28, y: 18, width: 8, height: 8)).fill()
            slate.setFill()
            UIBezierPath(ovalIn: CGRect(x: 30, y: 20, width: 4, height: 4)).fill()
        }
    }

    /** Waze report badges, in Waze's own colors: blue police, red crashes, amber hazards… */
    static func waze(_ k: WazeAlert.Kind) -> UIImage {
        switch k {
        case .closure: return noEntrySign()
        case .hazard: return warningSign()
        default: break
        }
        let symbol: String
        switch k {
        case .police: symbol = "shield.fill"
        case .accident: symbol = "burst.fill"
        case .hazard: symbol = "exclamationmark.triangle.fill"
        case .weather: symbol = "cloud.fog.fill"
        case .roadworks: symbol = "wrench.and.screwdriver.fill"
        case .closure: symbol = "nosign"
        case .jam: symbol = "car.2.fill"
        }
        return badge(wazeColor(k)) { _ in
            draw(symbol, in: CGRect(x: 12, y: 12, width: 22, height: 22), color: .white)
        }
    }

    static func wazeColor(_ k: WazeAlert.Kind) -> UIColor {
        switch k {
        case .police: return UIColor(hex: 0x1E88E5)
        case .accident, .jam: return UIColor(hex: 0xD93025)
        case .hazard: return UIColor(hex: 0xF29900)
        case .weather: return UIColor(hex: 0x00897B)
        case .roadworks: return UIColor(hex: 0xE8710A)
        case .closure: return UIColor(hex: 0xB71C1C)
        }
    }

    /** A 46-unit badge drawn at 21 points (sharp when the map scales it up): white rim, colored field, then the glyph. */
    private static func badge(_ color: UIColor, glyph: (UIColor) -> Void) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 21, height: 21)).image { ctx in
            ctx.cgContext.scaleBy(x: 21.0 / 46.0, y: 21.0 / 46.0)
            UIColor.white.setFill()
            UIBezierPath(roundedRect: CGRect(x: 2, y: 2, width: 42, height: 42), cornerRadius: 11).fill()
            color.setFill()
            UIBezierPath(roundedRect: CGRect(x: 4.5, y: 4.5, width: 37, height: 37), cornerRadius: 9).fill()
            glyph(color)
        }
    }


    // MARK: Road signs (what the road shows, drawn small)

    /** A warning triangle with a red rim, like the one on the road. */
    private static func triangleSign(fill: UIColor, glyph: (CGRect) -> Void) -> UIImage {
        let size = CGSize(width: 20, height: 18.5)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            // Drawn in the old 26x24 space, shrunk to fit: same look, smaller on the map.
            ctx.cgContext.scaleBy(x: 20.0 / 26.0, y: 20.0 / 26.0)
            let g = ctx.cgContext
            let tri = UIBezierPath()
            tri.move(to: CGPoint(x: 13, y: 3))
            tri.addLine(to: CGPoint(x: 23, y: 20))
            tri.addLine(to: CGPoint(x: 3, y: 20))
            tri.close()
            tri.lineJoinStyle = .round
            g.setShadow(offset: CGSize(width: 0, height: 1), blur: 2, color: UIColor.black.withAlphaComponent(0.35).cgColor)
            UIColor(hex: 0xD32F2F).setStroke()
            tri.lineWidth = 5
            tri.stroke()
            g.setShadow(offset: .zero, blur: 0, color: nil)
            fill.setFill()
            tri.fill()
            UIColor(hex: 0xD32F2F).setStroke()
            tri.lineWidth = 3.2
            tri.stroke()
            glyph(CGRect(x: 8.5, y: 9.5, width: 9, height: 9))
        }
    }

    /** A traffic warning: the white triangle with the exclamation mark. */
    static func warningSign() -> UIImage {
        triangleSign(fill: .white) { r in draw("exclamationmark", in: r.insetBy(dx: 1.2, dy: 0), color: UIColor(hex: 0x1F1F1F)) }
    }

    /** A closed road: the red disc with the white bar. */
    static func noEntrySign() -> UIImage {
        let size = CGSize(width: 19, height: 19)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            // Drawn in the old 24x24 space, shrunk to fit: same look, smaller on the map.
            ctx.cgContext.scaleBy(x: 19.0 / 24.0, y: 19.0 / 24.0)
            let g = ctx.cgContext
            let disc = CGRect(x: 2, y: 2, width: 20, height: 20)
            g.setShadow(offset: CGSize(width: 0, height: 1), blur: 2, color: UIColor.black.withAlphaComponent(0.35).cgColor)
            UIColor.white.setFill()
            UIBezierPath(ovalIn: disc).fill()
            g.setShadow(offset: .zero, blur: 0, color: nil)
            UIColor(hex: 0xD32F2F).setFill()
            UIBezierPath(ovalIn: disc.insetBy(dx: 2, dy: 2)).fill()
            UIColor.white.setFill()
            UIBezierPath(roundedRect: CGRect(x: 6.5, y: 10, width: 11, height: 4), cornerRadius: 1).fill()
        }
    }

    private static func dot(_ symbol: String, _ color: UIColor) -> UIImage {
        let size = CGSize(width: 22, height: 22)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            ctx.cgContext.scaleBy(x: 22.0 / 28.0, y: 22.0 / 28.0)
            let r = CGRect(x: 0, y: 0, width: 28, height: 28).insetBy(dx: 1.5, dy: 1.5)
            color.setFill()
            UIColor.white.setStroke()
            let path = UIBezierPath(ovalIn: r)
            path.lineWidth = 2
            path.fill()
            path.stroke()
            draw(symbol, in: r.insetBy(dx: 6, dy: 6), color: .white)
        }
    }

    private static func draw(_ symbol: String, in r: CGRect, color: UIColor) {
        let cfg = UIImage.SymbolConfiguration(pointSize: r.height, weight: .semibold)
        guard let img = UIImage(systemName: symbol, withConfiguration: cfg)?.withTintColor(color, renderingMode: .alwaysOriginal) else { return }
        let s = img.size
        let scale = min(r.width / s.width, r.height / s.height)
        let w = s.width * scale, h = s.height * scale
        img.draw(in: CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h))
    }

    private static func selectedPin() -> UIImage {
        let size = CGSize(width: 34, height: 46)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let red = UIColor(hex: 0xEA4335)
            let head = CGRect(x: 2, y: 2, width: 30, height: 30)
            let p = UIBezierPath()
            p.move(to: CGPoint(x: 17, y: 44))
            p.addCurve(to: CGPoint(x: 3.5, y: 23), controlPoint1: CGPoint(x: 13, y: 37), controlPoint2: CGPoint(x: 6, y: 29))
            p.addArc(withCenter: CGPoint(x: head.midX, y: head.midY), radius: 15, startAngle: .pi * 0.86, endAngle: .pi * 0.14, clockwise: true)
            p.addCurve(to: CGPoint(x: 17, y: 44), controlPoint1: CGPoint(x: 28, y: 29), controlPoint2: CGPoint(x: 21, y: 37))
            p.close()
            red.setFill()
            UIColor(hex: 0xA50E0E).setStroke()
            p.lineWidth = 1.5
            p.fill()
            p.stroke()
            UIColor(hex: 0x7A0B0B).setFill()
            UIBezierPath(ovalIn: CGRect(x: 12, y: 12, width: 10, height: 10)).fill()
        }
    }

    private static func originDot() -> UIImage {
        let size = CGSize(width: 22, height: 22)
        return UIGraphicsImageRenderer(size: size).image { _ in
            UIColor.white.setFill()
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)).fill()
            UIColor(hex: 0x14B8A6).setStroke()
            let ring = UIBezierPath(ovalIn: CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4))
            ring.lineWidth = 4
            ring.stroke()
        }
    }

    /**
     * The car while navigating, Waze-style in Kite's teal: a chunky teal arrow with a white rim and a
     * darker right half so it reads as raised, sitting on a disc with a teal ring (navy at night,
     * white by day).
     */
    static func puck(dark: Bool) -> UIImage {
        let size = CGSize(width: 76, height: 76)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let g = ctx.cgContext
            let disc = UIBezierPath(ovalIn: CGRect(x: 6, y: 6, width: 64, height: 64))
            (dark ? UIColor(hex: 0x0F172A, alpha: 0.6) : UIColor(white: 1, alpha: 0.75)).setFill()
            disc.fill()
            UIColor(hex: 0x2DD4BF, alpha: 0.75).setStroke()
            disc.lineWidth = 2.5
            disc.stroke()
            let tip = CGPoint(x: 38, y: 13), left = CGPoint(x: 18, y: 60), right = CGPoint(x: 58, y: 60), notch = CGPoint(x: 38, y: 50)
            let outline = UIBezierPath()
            outline.move(to: tip); outline.addLine(to: right); outline.addLine(to: notch); outline.addLine(to: left); outline.close()
            outline.lineJoinStyle = .round
            g.setShadow(offset: CGSize(width: 0, height: 2), blur: 4, color: UIColor.black.withAlphaComponent(0.45).cgColor)
            UIColor.white.setStroke()
            outline.lineWidth = 5
            outline.stroke()
            g.setShadow(offset: .zero, blur: 0, color: nil)
            g.saveGState()
            outline.addClip()
            let space = CGColorSpaceCreateDeviceRGB()
            if let grad = CGGradient(colorsSpace: space, colors: [UIColor(hex: 0x99F6E4).cgColor, UIColor(hex: 0x0D9488).cgColor] as CFArray, locations: [0, 1]) {
                g.drawLinearGradient(grad, start: tip, end: CGPoint(x: 52, y: 60), options: [])
            }
            // The right half a shade darker.
            UIColor(hex: 0x064E3B, alpha: 0.3).setFill()
            let shade = UIBezierPath()
            shade.move(to: tip); shade.addLine(to: right); shade.addLine(to: notch); shade.close()
            shade.fill()
            g.restoreGState()
        }
    }

}
