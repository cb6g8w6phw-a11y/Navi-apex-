import SceneKit
import SwiftUI
import UIKit

/**
 * Google Street View drawn by the app itself: the panorama's image tiles stitched together and
 * wrapped inside a sphere. Drag to look around, pinch to zoom. A low-detail image comes first,
 * then a sharp one.
 */
struct PanoramaViewer: UIViewRepresentable {
    let pano: StreetView.Panorama
    /** Which way to face at the start (toward the place). */
    let heading: Double

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let c = context.coordinator
        let view = SCNView()
        view.backgroundColor = .black
        view.antialiasingMode = .multisampling2X
        let scene = SCNScene()
        let sphere = SCNSphere(radius: 10)
        sphere.segmentCount = 96
        let m = SCNMaterial()
        m.diffuse.contents = UIColor.black
        m.lightingModel = .constant
        m.cullMode = .front
        // Seen from inside, the picture has to be mirrored.
        m.diffuse.contentsTransform = SCNMatrix4Translate(SCNMatrix4MakeScale(-1, 1, 1), 1, 0, 0)
        m.diffuse.wrapS = .repeat
        sphere.materials = [m]
        scene.rootNode.addChildNode(SCNNode(geometry: sphere))
        let cam = SCNNode()
        cam.camera = SCNCamera()
        cam.camera?.fieldOfView = 80
        cam.camera?.zNear = 0.1
        scene.rootNode.addChildNode(cam)
        view.scene = scene
        view.pointOfView = cam
        c.camera = cam
        c.material = m
        c.yaw = Coordinator.yaw(facing: heading, pano: pano)
        c.apply()
        view.addGestureRecognizer(UIPanGestureRecognizer(target: c, action: #selector(Coordinator.panned(_:))))
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.pinched(_:))))
        if pano.id == Self.testID { m.diffuse.contents = Self.testPattern() } else { c.load(pano) }
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {}

    /** A made-up panorama for the screenshot run: each column says how far right of the
     *  panorama's own heading it is, so the run shows which way the viewer faces. */
    static let testID = "demo-test"

    static func testPattern() -> UIImage {
        let size = CGSize(width: 2048, height: 1024)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            for i in 0..<16 {
                UIColor(hue: CGFloat(i) / 16, saturation: 0.6, brightness: 0.9, alpha: 1).setFill()
                ctx.fill(CGRect(x: CGFloat(i) * 128, y: 0, width: 128, height: size.height))
            }
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 40), .foregroundColor: UIColor.black]
            for i in 0..<16 {
                let deg = i * 360 / 16 - 180
                let x = CGFloat(i) * 128
                UIColor.black.setFill()
                ctx.fill(CGRect(x: x - 2, y: 380, width: 4, height: 264))
                ("\(deg)" as NSString).draw(at: CGPoint(x: x + 6, y: 490), withAttributes: attrs)
            }
        }
    }

    static func dismantleUIView(_ view: SCNView, coordinator: Coordinator) {
        coordinator.task?.cancel()
    }

    @MainActor
    final class Coordinator: NSObject {
        var camera: SCNNode?
        var material: SCNMaterial?
        var yaw: Float = 0
        var pitch: Float = 0
        var fov: CGFloat = 80
        var task: Task<Void, Never>?

        /** SceneKit turns left for a bigger angle; compass headings turn right. At yaw 0 the camera
         *  looks at the image's edge, half a turn from its middle (the panorama's own heading). */
        static func yaw(facing heading: Double, pano: StreetView.Panorama) -> Float {
            Float(-(heading - pano.heading + 180) * .pi / 180)
        }

        func apply() {
            camera?.eulerAngles = SCNVector3(pitch, yaw, 0)
            camera?.camera?.fieldOfView = fov
        }

        @objc func panned(_ g: UIPanGestureRecognizer) {
            guard let v = g.view else { return }
            let t = g.translation(in: v)
            g.setTranslation(.zero, in: v)
            // One screen width turns by about the field of view.
            let perPoint = Float(fov * .pi / 180) / Float(max(v.bounds.width, 1))
            yaw += Float(t.x) * perPoint
            pitch = min(max(pitch + Float(t.y) * perPoint, -1.4), 1.4)
            apply()
        }

        @objc func pinched(_ g: UIPinchGestureRecognizer) {
            fov = min(max(fov / g.scale, 30), 100)
            g.scale = 1
            apply()
        }

        func load(_ pano: StreetView.Panorama) {
            task = Task { [weak self] in
                for zoom in [2, 3] {
                    guard let image = await Self.stitch(pano, zoom: zoom), !Task.isCancelled else { continue }
                    self?.material?.diffuse.contents = image
                }
            }
        }

        /** All of the panorama's tiles at [zoom], drawn into one picture. */
        nonisolated static func stitch(_ pano: StreetView.Panorama, zoom: Int) async -> UIImage? {
            let size = pano.size(zoom: zoom)
            let cols = Int((Double(size.width) / 512).rounded(.up)), rows = Int((Double(size.height) / 512).rounded(.up))
            var tiles: [(Int, Int, UIImage)] = []
            await withTaskGroup(of: (Int, Int, UIImage?).self) { group in
                for y in 0..<rows {
                    for x in 0..<cols {
                        group.addTask {
                            let data = try? await URLSession.shared.data(from: StreetView.tileURL(pano, x: x, y: y, zoom: zoom)).0
                            return (x, y, data.flatMap(UIImage.init(data:)))
                        }
                    }
                }
                for await (x, y, img) in group { if let img { tiles.append((x, y, img)) } }
            }
            guard !tiles.isEmpty else { return nil }
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            return UIGraphicsImageRenderer(size: CGSize(width: size.width, height: size.height), format: format).image { ctx in
                UIColor.black.setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
                for (x, y, img) in tiles {
                    img.draw(in: CGRect(x: x * 512, y: y * 512, width: 512, height: 512))
                }
            }
        }
    }
}
