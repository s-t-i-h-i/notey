import UIKit
import PencilKit

// MARK: - Shape straightening ("draw and hold")
//
// PencilKit ships the same inking engine as Apple Notes, but NOT its private
// shape-recognition ("Smart Shapes"). This module reproduces that interaction
// on top of PencilKit: the Pencil is held still for a moment at the end of a
// stroke, and on lift the freehand stroke is replaced by an idealized shape
// (line, arrow, triangle, rectangle, ellipse). It is a pure geometry pass over
// the last PKStroke — no private API.

// MARK: Hold-still recognizer

/// Fires once when the Pencil has stayed within `moveTolerance` of a spot for
/// `stillDuration` — i.e. the user paused at the end of a shape. It observes
/// touches passively: `cancelsTouchesInView = false` plus simultaneous
/// recognition means PencilKit keeps drawing the stroke undisturbed.
final class HoldStillGestureRecognizer: UIGestureRecognizer {
    var stillDuration: TimeInterval = 0.4
    var moveTolerance: CGFloat = 9

    private var anchor: CGPoint = .zero
    private var timer: Timer?
    private var didFire = false

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard let touch = touches.first, touch.type == .pencil else { return }
        didFire = false
        anchor = touch.location(in: view)
        arm()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard !didFire, let touch = touches.first else { return }
        let p = touch.location(in: view)
        if hypot(p.x - anchor.x, p.y - anchor.y) > moveTolerance {
            anchor = p
            arm()          // moved: restart the stillness clock
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        timer?.invalidate()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        timer?.invalidate()
    }

    private func arm() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: stillDuration, repeats: false) { [weak self] _ in
            guard let self, !self.didFire else { return }
            self.didFire = true
            // Fire the target-action once, without lingering in a recognized
            // state (which could interfere with PencilKit's own gesture).
            self.state = .began
            self.state = .ended
        }
    }

    override func reset() {
        super.reset()
        timer?.invalidate()
        timer = nil
        didFire = false
    }
}

// MARK: Snapper — ties the recognizer to the canvas

final class ShapeSnapper: NSObject, UIGestureRecognizerDelegate {
    /// Called after the last stroke has been replaced by its ideal shape, with
    /// the drawing as it was *before* the swap (so the change can be committed
    /// and made undoable by the owner).
    var onSnap: ((PKDrawing) -> Void)?
    var isEnabled = true

    private weak var canvasView: PKCanvasView?
    private let hold = HoldStillGestureRecognizer()
    // Set while the Pencil is held still at the end of the current stroke; the
    // actual snap happens on lift, once PencilKit has committed the stroke.
    private var pendingSnap = false

    init(canvasView: PKCanvasView) {
        self.canvasView = canvasView
        super.init()
        hold.addTarget(self, action: #selector(handleHold(_:)))
        hold.delegate = self
        hold.cancelsTouchesInView = false
        hold.delaysTouchesBegan = false
        hold.delaysTouchesEnded = false
        canvasView.addGestureRecognizer(hold)
    }

    @objc private func handleHold(_ gesture: UIGestureRecognizer) {
        guard isEnabled, gesture.state == .began else { return }
        pendingSnap = true
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
    }

    /// Called by the container from `canvasViewDidEndUsingTool` once a fresh
    /// ink stroke has landed. Snaps it if the Pencil was held at its end.
    func inkStrokeDidEnd() {
        defer { pendingSnap = false }
        guard isEnabled, pendingSnap,
              let canvasView, let last = canvasView.drawing.strokes.last,
              let ideal = ShapeRecognizer.idealize(last), !ideal.isEmpty
        else { return }

        let before = canvasView.drawing
        var strokes = before.strokes
        strokes.removeLast()
        strokes.append(contentsOf: ideal)
        canvasView.drawing = PKDrawing(strokes: strokes)
        UISelectionFeedbackGenerator().selectionChanged()
        onSnap?(before)
    }

    // Observe passively — never block PencilKit's drawing / scroll / zoom.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }
}

// MARK: - Geometry: classify a freehand stroke and rebuild it as an ideal shape

enum ShapeRecognizer {

    /// Returns the idealized stroke(s) for `stroke`, or nil when nothing is
    /// recognized confidently (the freehand stroke is then left as-is).
    static func idealize(_ stroke: PKStroke) -> [PKStroke]? {
        // Uniformly sampled outline in page coordinates — robust regardless of
        // how many control points PencilKit stored.
        let pts = stroke.path.interpolatedPoints(by: .distance(4))
            .map { $0.location.applying(stroke.transform) }
        guard pts.count >= 8 else { return nil }

        let box = boundingBox(pts)
        let diag = hypot(box.width, box.height)
        guard diag > 26 else { return nil }   // ignore dots / tiny scribbles

        // Ink + a representative point (thickness, force, tilt) to reuse.
        let ink = stroke.ink
        let template = stroke.path[stroke.path.count / 2]
        let created = stroke.path.creationDate

        let closed = distance(pts.first!, pts.last!) < 0.24 * diag && diag > 44

        if closed {
            // Round blob → ellipse (covers sloppy circles that RDP might read
            // as a 4-gon), tested before corner counting.
            if ellipseFitsWell(pts, box: box, diag: diag) {
                return [makeStroke(ellipseOutline(in: box), ink: ink, template: template, created: created)]
            }
            var corners = rdp(pts, epsilon: diag * 0.055)
            if corners.count > 1, distance(corners.first!, corners.last!) < 0.16 * diag {
                corners.removeLast()   // drop the duplicated closing vertex
            }
            switch corners.count {
            case 3:
                return [makeStroke(closeLoop(corners), ink: ink, template: template, created: created)]
            case 4:
                if isAxisRectangle(corners, box: box, diag: diag) {
                    return [makeStroke(rectangleOutline(box), ink: ink, template: template, created: created)]
                }
                return [makeStroke(closeLoop(corners), ink: ink, template: template, created: created)]
            default:
                // Many smooth turns we didn't catch as an ellipse, or a rare
                // hand-drawn polygon — trace the simplified corners.
                return corners.count >= 5
                    ? [makeStroke(ellipseOutline(in: box), ink: ink, template: template, created: created)]
                    : nil
            }
        }

        // Open stroke: arrow first (a line with a folded-back head), else line.
        if let arrow = arrowStrokes(pts, diag: diag, ink: ink, template: template, created: created) {
            return arrow
        }
        let straightness = maxPerpDistance(pts, a: pts.first!, b: pts.last!) / diag
        if straightness < 0.14 {
            return [makeStroke(densify([pts.first!, pts.last!], spacing: 6, closed: false),
                               ink: ink, template: template, created: created)]
        }
        return nil
    }

    // MARK: Shape builders

    private static func arrowStrokes(
        _ pts: [CGPoint], diag: CGFloat, ink: PKInk, template: PKStrokePoint, created: Date
    ) -> [PKStroke]? {
        guard let tail = pts.first else { return nil }
        // Tip = farthest point from the tail.
        var tipIdx = 0
        var best: CGFloat = -1
        for (i, p) in pts.enumerated() {
            let d = distance(p, tail)
            if d > best { best = d; tipIdx = i }
        }
        let tip = pts[tipIdx]
        let shaftLen = best
        // The head must fold back: several points after the tip, ending nearer
        // the tail than the tip. And the shaft must be long and straight.
        guard tipIdx < pts.count - 2, shaftLen > 0.55 * diag else { return nil }
        guard distance(pts.last!, tail) < 0.82 * shaftLen else { return nil }
        let shaft = Array(pts[0...tipIdx])
        guard maxPerpDistance(shaft, a: tail, b: tip) / max(shaftLen, 1) < 0.18 else { return nil }

        let dir = unit(CGPoint(x: tip.x - tail.x, y: tip.y - tail.y))
        let back = CGPoint(x: -dir.x, y: -dir.y)
        let barbLen = min(shaftLen * 0.28, 46)
        let a1 = add(tip, mul(rotate(back, .pi / 7), barbLen))    // ~25.7°
        let a2 = add(tip, mul(rotate(back, -.pi / 7), barbLen))

        return [
            makeStroke(densify([tail, tip], spacing: 6, closed: false), ink: ink, template: template, created: created),
            makeStroke(densify([tip, a1], spacing: 6, closed: false), ink: ink, template: template, created: created),
            makeStroke(densify([tip, a2], spacing: 6, closed: false), ink: ink, template: template, created: created)
        ]
    }

    private static func rectangleOutline(_ box: CGRect) -> [CGPoint] {
        let corners = [
            CGPoint(x: box.minX, y: box.minY),
            CGPoint(x: box.maxX, y: box.minY),
            CGPoint(x: box.maxX, y: box.maxY),
            CGPoint(x: box.minX, y: box.maxY)
        ]
        return densify(corners, spacing: 6, closed: true)
    }

    private static func closeLoop(_ corners: [CGPoint]) -> [CGPoint] {
        densify(corners, spacing: 6, closed: true)
    }

    private static func ellipseOutline(in box: CGRect) -> [CGPoint] {
        let cx = box.midX, cy = box.midY
        let rx = box.width / 2, ry = box.height / 2
        let steps = 72
        var out: [CGPoint] = []
        out.reserveCapacity(steps + 1)
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
            out.append(CGPoint(x: cx + rx * cos(t), y: cy + ry * sin(t)))
        }
        return out
    }

    // MARK: Stroke assembly

    private static func makeStroke(
        _ points: [CGPoint], ink: PKInk, template: PKStrokePoint, created: Date
    ) -> PKStroke {
        var sp: [PKStrokePoint] = []
        sp.reserveCapacity(points.count)
        for (i, p) in points.enumerated() {
            sp.append(PKStrokePoint(
                location: p,
                timeOffset: TimeInterval(i) * 0.01,
                size: template.size,
                opacity: template.opacity,
                force: template.force,
                azimuth: template.azimuth,
                altitude: template.altitude
            ))
        }
        let path = PKStrokePath(controlPoints: sp, creationDate: created)
        return PKStroke(ink: ink, path: path, transform: .identity, mask: nil)
    }

    /// Even sampling along a polyline so PencilKit's spline follows the ideal
    /// edges (and only lightly rounds the corners).
    private static func densify(_ poly: [CGPoint], spacing: CGFloat, closed: Bool) -> [CGPoint] {
        var pts = poly
        if closed, let first = poly.first { pts.append(first) }
        guard pts.count >= 2 else { return pts }
        var out: [CGPoint] = []
        for i in 0..<(pts.count - 1) {
            let a = pts[i], b = pts[i + 1]
            let d = distance(a, b)
            let steps = max(1, Int((d / spacing).rounded()))
            for s in 0..<steps {
                let t = CGFloat(s) / CGFloat(steps)
                out.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        out.append(pts.last!)
        return out
    }

    // MARK: Classification helpers

    /// Average distance of the points from the bounding-box-inscribed ellipse,
    /// normalized by the diagonal. Small ⇒ the stroke is an ellipse/circle.
    private static func ellipseFitsWell(_ pts: [CGPoint], box: CGRect, diag: CGFloat) -> Bool {
        let rx = box.width / 2, ry = box.height / 2
        guard rx > 6, ry > 6 else { return false }
        let cx = box.midX, cy = box.midY
        var sum: CGFloat = 0
        for p in pts {
            let nx = (p.x - cx) / rx
            let ny = (p.y - cy) / ry
            // |‖(nx,ny)‖ - 1| · min(rx,ry) ≈ radial distance to the ellipse.
            sum += abs(hypot(nx, ny) - 1) * min(rx, ry)
        }
        return (sum / CGFloat(pts.count)) / diag < 0.07
    }

    private static func isAxisRectangle(_ corners: [CGPoint], box: CGRect, diag: CGFloat) -> Bool {
        let boxCorners = [
            CGPoint(x: box.minX, y: box.minY),
            CGPoint(x: box.maxX, y: box.minY),
            CGPoint(x: box.maxX, y: box.maxY),
            CGPoint(x: box.minX, y: box.maxY)
        ]
        // Every drawn corner must sit near some box corner (⇒ roughly
        // axis-aligned, so snapping to the bounding box is faithful).
        for c in corners {
            let nearest = boxCorners.map { distance($0, c) }.min() ?? .greatestFiniteMagnitude
            if nearest > 0.2 * diag { return false }
        }
        return true
    }

    // MARK: Ramer–Douglas–Peucker

    private static func rdp(_ points: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }
        let end = points.count - 1
        var dmax: CGFloat = 0
        var index = 0
        for i in 1..<end {
            let d = perpendicularDistance(points[i], a: points[0], b: points[end])
            if d > dmax { index = i; dmax = d }
        }
        if dmax > epsilon {
            let left = rdp(Array(points[0...index]), epsilon: epsilon)
            let right = rdp(Array(points[index...end]), epsilon: epsilon)
            return Array(left.dropLast()) + right
        }
        return [points[0], points[end]]
    }

    // MARK: Vector math

    private static func boundingBox(_ pts: [CGPoint]) -> CGRect {
        var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for p in pts {
            minX = min(minX, p.x); minY = min(minY, p.y)
            maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private static func perpendicularDistance(_ p: CGPoint, a: CGPoint, b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = hypot(dx, dy)
        guard len > 0.0001 else { return distance(p, a) }
        return abs((p.x - a.x) * dy - (p.y - a.y) * dx) / len
    }

    private static func maxPerpDistance(_ pts: [CGPoint], a: CGPoint, b: CGPoint) -> CGFloat {
        pts.reduce(0) { max($0, perpendicularDistance($1, a: a, b: b)) }
    }

    private static func unit(_ v: CGPoint) -> CGPoint {
        let l = hypot(v.x, v.y)
        return l > 0.0001 ? CGPoint(x: v.x / l, y: v.y / l) : .zero
    }

    private static func rotate(_ v: CGPoint, _ angle: CGFloat) -> CGPoint {
        let c = cos(angle), s = sin(angle)
        return CGPoint(x: v.x * c - v.y * s, y: v.x * s + v.y * c)
    }

    private static func add(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: a.x + b.x, y: a.y + b.y)
    }

    private static func mul(_ v: CGPoint, _ k: CGFloat) -> CGPoint {
        CGPoint(x: v.x * k, y: v.y * k)
    }
}
