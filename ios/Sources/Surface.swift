import UIKit

func quiet(_ f: () -> Void) { CATransaction.begin(); CATransaction.setDisableActions(true); f(); CATransaction.commit() }

/// Still-image layer in stream pixels (top-left origin).
/// Hybrid: transparent overlay of lossless patches, holes punched where newer video changed.
/// Tiles:  opaque base image. New patches show instantly as sublayers and get flattened into one bitmap later.
final class Surface {
    let layer = CALayer()
    private var ctx: CGContext?
    private var W = 0, H = 0
    private var painted: [CGRect] = []
    private var pending = 0
    private var dirty = false
    private(set) var lastAdd: CFTimeInterval = 0

    init() {
        layer.anchorPoint = .zero
        layer.contentsGravity = .resize
        layer.actions = ["contents": NSNull(), "sublayers": NSNull(), "bounds": NSNull(), "position": NSNull(), "transform": NSNull()]
    }

    func reset(w: Int, h: Int, opaque: Bool) {
        W = w; H = h; painted = []; pending = 0; dirty = false
        ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        ctx?.setBlendMode(.copy)
        if opaque { ctx?.setFillColor(UIColor.black.cgColor); ctx?.fill(CGRect(x: 0, y: 0, width: w, height: h)) }
        quiet {
            layer.sublayers?.forEach { $0.removeFromSuperlayer() }
            layer.bounds = CGRect(x: 0, y: 0, width: w, height: h)
            layer.contents = opaque ? ctx?.makeImage() : nil
        }
    }

    private func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: CGFloat(H) - r.maxY, width: r.width, height: r.height) }

    func add(_ img: CGImage, _ r: CGRect) {
        guard let ctx else { return }
        ctx.draw(img, in: flip(r))
        let s = CALayer()
        s.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        s.contents = img; s.frame = r
        quiet { layer.addSublayer(s) }
        painted.append(r); pending += 1; lastAdd = CACurrentMediaTime()
        if pending > 48 { flatten() }
    }

    /// Fold instant sublayers into the bitmap (single upload).
    func flatten() {
        guard pending > 0, let ctx else { return }
        pending = 0; dirty = false
        quiet { layer.contents = ctx.makeImage(); layer.sublayers?.forEach { $0.removeFromSuperlayer() } }
    }

    func clear(_ rects: [CGRect]) {
        guard !painted.isEmpty, let ctx else { return }
        let hit = rects.filter { r in painted.contains { $0.intersects(r) } }
        if hit.isEmpty { return }
        if pending > 0 { pending = 0; quiet { layer.sublayers?.forEach { $0.removeFromSuperlayer() } } }
        for r in hit { ctx.clear(flip(r)) }
        painted.removeAll { p in hit.contains { $0.contains(p) } }
        dirty = true
    }

    /// once per display refresh
    func commit() {
        if dirty, let ctx { dirty = false; quiet { layer.contents = ctx.makeImage() } }
        if pending > 0 && CACurrentMediaTime() - lastAdd > 0.25 { flatten() }
    }
}
