import UIKit
import PencilKit

// MARK: - Shape straightening ("draw and hold")
//
// PencilKit ships the same inking engine as Apple Notes, but NOT its private
// shape recognition ("Smart Shapes"). This module reproduces that interaction
// on top of PencilKit: hold the Pencil still for a moment while finishing a
// stroke and the freehand ink morphs into an idealized shape THE MOMENT the
// hold fires — the pen never has to lift (Apple Notes behavior).
//
// PencilKit has no API to read or replace a wet (in-flight) stroke, so the
// live snap works around it: the hold recognizer records the touch trace
// itself, and on hold the snapper cancels PencilKit's drawing gesture (an
// `isEnabled` toggle — the only WORKING way to end a wet stroke early;
// forcing `state = .ended` is silently ignored) and swaps in ideal strokes
// built from that trace. The cancel DISCARDS the wet stroke, so there is no
// committed ink to copy params from — styling from the tool's nominal width
// renders far too thick. Instead, every committed ink stroke refreshes a
// per-ink-type CALIBRATION of its real, pressure-derived point sizes (tagged
// with the tool width that produced them), and live-snapped shapes are
// styled from that, scaled to the current tool width. Until the first stroke
// of an ink type commits (fresh note, fresh tool), the hold arms the on-lift
// snap instead — same result, styled from the committed stroke itself, just
// one pen-lift later. The on-lift path also covers traces that are not
// idealizable at hold time.
//
// Recognized forms (pure geometry over the traced points — no private API):
//   open:   straight line (snapped to the 45° grid), polyline (L/V/zigzag),
//           arrow (straight OR curved shaft, hook or V head), circular arc,
//           smooth Bézier curve (least-squares piecewise cubic fit)
//   closed: circle, ellipse (any tilt), triangle, rectangle (any rotation),
//           quadrilateral, polygon (5–8 corners), cleaned smooth loop
//
// Guards: the live snap only runs while an INKING tool interaction is active
// (holding the eraser or lasso still does nothing), a new tool interaction
// clears any stale hold, and the on-lift fallback additionally requires the
// hold to have happened at the stroke's end.

// MARK: Hold-still recognizer

/// Passive observer that calls `onHold` when the Pencil has stayed within
/// `moveTolerance` of a spot for `stillDuration`. It never leaves `.possible`,
/// so it cannot interfere with PencilKit's own drawing/scroll gestures; it is
/// re-armable — pausing mid-stroke and holding again at the true end fires
/// again with the newer location.
final class HoldStillGestureRecognizer: UIGestureRecognizer {
    var stillDuration: TimeInterval = 0.42
    var moveTolerance: CGFloat = 7
    /// The stroke must have traveled at least this far before a hold can fire
    /// (a dot + hold should not buzz).
    var minTravel: CGFloat = 24
    /// Developer/simulator mode: also observe finger and pointer touches (the
    /// Simulator has no Pencil; the canvas draws with .anyInput there).
    var acceptsFingerTouches = false
    /// Called on stillness with the hold location (view/content coordinates).
    /// Return true to CONSUME the touch — the live snap replaced the stroke,
    /// so tracking (and any re-arming) stops until the next touch begins.
    var onHold: ((CGPoint) -> Bool)?
    /// Full path of the observed touch in view coordinates (coalesced
    /// samples) — the wet stroke PencilKit won't share, recorded first-hand.
    private(set) var trace: [CGPoint] = []

    private weak var pencilTouch: UITouch?
    private var anchor: CGPoint = .zero
    private var lastLocation: CGPoint = .zero
    private var traveled: CGFloat = 0
    private var timer: Timer?

    private func isObservable(_ touch: UITouch) -> Bool {
        touch.type == .pencil
            || (acceptsFingerTouches && (touch.type == .direct || touch.type == .indirectPointer))
    }

    // Belt and braces on top of the simultaneous-recognition delegate: this
    // observer must NEVER be force-reset by PencilKit's drawing recognizer
    // claiming the touch (reset kills the stillness timer mid-stroke).
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard pencilTouch == nil,
              let touch = touches.first(where: { isObservable($0) })
        else { return }
        pencilTouch = touch
        anchor = touch.location(in: view)
        lastLocation = anchor
        traveled = 0
        trace.removeAll(keepingCapacity: true)
        trace.append(anchor)
        arm()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let touch = pencilTouch, touches.contains(touch) else { return }
        // Coalesced samples keep the trace faithful at Pencil rates (240 Hz).
        for sample in event.coalescedTouches(for: touch) ?? [touch] {
            trace.append(sample.location(in: view))
        }
        let p = touch.location(in: view)
        traveled += hypot(p.x - lastLocation.x, p.y - lastLocation.y)
        lastLocation = p
        if hypot(p.x - anchor.x, p.y - anchor.y) > moveTolerance {
            anchor = p
            arm()          // moved on: restart the stillness clock
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        finish(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        finish(touches)
    }

    private func finish(_ touches: Set<UITouch>) {
        guard let touch = pencilTouch, touches.contains(touch) else { return }
        pencilTouch = nil
        timer?.invalidate()
        timer = nil
    }

    private func arm() {
        timer?.invalidate()
        let t = Timer(timeInterval: stillDuration, repeats: false) { [weak self] _ in
            guard let self, self.pencilTouch != nil, self.traveled >= self.minTravel else { return }
            if self.onHold?(self.anchor) == true {
                // Consumed by a live snap: stop observing this touch — its
                // remaining movement belongs to a stroke that no longer exists.
                self.pencilTouch = nil
                self.timer?.invalidate()
                self.timer = nil
                self.trace.removeAll()
            }
        }
        // .common keeps the timer firing even while UIKit is in tracking mode
        // (e.g. a simultaneous two-finger scroll).
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    override func reset() {
        super.reset()
        pencilTouch = nil
        timer?.invalidate()
        timer = nil
        trace.removeAll()
    }
}

// MARK: Snapper — ties the recognizer to the canvas

final class ShapeSnapper: NSObject, UIGestureRecognizerDelegate {
    /// Called after the last stroke has been replaced by its ideal shape, with
    /// the drawing as it was *before* the swap (so the change can be committed
    /// and made undoable by the owner).
    var onSnap: ((PKDrawing) -> Void)?
    var isEnabled = true
    /// Developer/simulator mode: the hold trigger also listens to finger and
    /// pointer touches (mirrors the canvas drawing with .anyInput).
    var acceptsFingerTouches = false {
        didSet { hold.acceptsFingerTouches = acceptsFingerTouches }
    }

    private weak var canvasView: PKCanvasView?
    private let hold = HoldStillGestureRecognizer()
    // Fallback path only: set when a hold fired but the trace was not
    // idealizable mid-touch; the snap then retries on lift, once PencilKit
    // has committed the stroke.
    private var pendingSnap = false
    // Where the fallback hold fired, in canvas content coordinates — the
    // on-lift snap only happens when the stroke also ENDS there.
    private var holdLocation: CGPoint = .zero
    // True while an inking/erasing tool interaction is in flight (mirrors the
    // container's canvasViewDidBegin/EndUsingTool) — the live snap must never
    // fire from a bare hold with no stroke under it.
    private var toolStrokeActive = false
    // Set when the live snap cancels PencilKit's drawing gesture: the
    // resulting canvasViewDidEndUsingTool is bookkeeping, not a stroke end,
    // and the container must skip its on-lift snap check.
    private var suppressToolEnd = false
    // Measured ink params of the most recent committed stroke, per ink type.
    // The live snap's own wet stroke never commits (the cancel discards it),
    // so ideal shapes are styled from these instead of the tool's nominal
    // width, which renders far too thick.
    private var inkCalibrations: [PKInkingTool.InkType: ShapeRecognizer.InkCalibration] = [:]

    init(canvasView: PKCanvasView) {
        self.canvasView = canvasView
        super.init()
        hold.onHold = { [weak self] location in
            guard let self, self.isEnabled else { return false }
            snapLog("hold fired at (%.0f, %.0f)", location.x, location.y)
            // Preferred: replace the ink RIGHT NOW, pen still down.
            if self.performLiveSnap() { return true }
            // Fallback: arm the on-lift snap (PencilKit's committed stroke
            // may still be idealizable even when the raw trace wasn't).
            self.pendingSnap = true
            self.holdLocation = location
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            return false
        }
        // Purely passive: never withhold or cancel touch delivery — PencilKit
        // must see the pencil lift the instant it happens.
        hold.cancelsTouchesInView = false
        hold.delaysTouchesBegan = false
        hold.delaysTouchesEnded = false
        // CRITICAL: without simultaneous recognition, the moment PencilKit's
        // own drawing recognizer claims the pencil touch, this observer is
        // PREVENTED → reset() → its timer dies → the hold never fires at all.
        hold.delegate = self
        canvasView.addGestureRecognizer(hold)
    }

    // Observe alongside everything (PencilKit drawing / scroll / zoom); the
    // hold never leaves .possible, so allowing simultaneity costs nothing.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }

    /// A new tool interaction started — a hold left over from a previous
    /// stroke (or from an erase / lasso pass) must not leak into this one.
    func strokeDidBegin() {
        pendingSnap = false
        toolStrokeActive = true
        suppressToolEnd = false
    }

    /// Called from `canvasViewDidEndUsingTool` — ALWAYS, before any snap
    /// bookkeeping. Returns true when this tool end is just the tail of a
    /// live snap's gesture cancellation (skip the on-lift snap check).
    func toolInteractionDidEnd() -> Bool {
        toolStrokeActive = false
        let suppressed = suppressToolEnd
        suppressToolEnd = false
        if suppressed { snapLog("tool end suppressed (live snap already replaced the stroke)") }
        return suppressed
    }

    /// Replace the WET stroke with its ideal shape while the pen is still
    /// down. PencilKit won't hand over an in-flight stroke, so this cancels
    /// the drawing gesture (the only public way to end a wet stroke) and
    /// rebuilds the ink from the hold recognizer's own trace.
    private func performLiveSnap() -> Bool {
        guard toolStrokeActive,
              let canvasView,
              let tool = canvasView.tool as? PKInkingTool
        else { return false }
        // Live styling needs ink params measured from a real committed
        // stroke of this ink type — until one lands (fresh note, fresh
        // tool), snap on lift instead: same result, one pen-lift later.
        guard let calibration = inkCalibrations[tool.inkType] else {
            snapLog("live: no ink calibration for %@ yet — arming on-lift fallback", tool.inkType.rawValue)
            return false
        }

        let zoom = max(0.01, canvasView.zoomScale)
        let pagePoints = hold.trace.map { CGPoint(x: $0.x / zoom, y: $0.y / zoom) }
        let minDiag = max(7, 22 / max(1, zoom))
        guard let outlines = ShapeRecognizer.idealOutlines(for: pagePoints, minDiag: minDiag),
              !outlines.isEmpty
        else {
            snapLog("live: trace not idealizable — arming on-lift fallback")
            return false
        }

        // Cancel the in-flight drawing (`isEnabled` toggle — the only
        // WORKING way to end a wet stroke early; `state = .ended` is
        // silently ignored by PencilKit's recognizer). The resulting
        // DidEndUsingTool must not run the on-lift snap logic — flag it
        // BEFORE toggling, the callback can fire synchronously.
        suppressToolEnd = true
        pendingSnap = false
        let strokesBeforeCancel = canvasView.drawing.strokes.count
        canvasView.drawingGestureRecognizer.isEnabled = false
        canvasView.drawingGestureRecognizer.isEnabled = true

        var strokes = canvasView.drawing.strokes
        let ideal: [PKStroke]
        let undoBase: PKDrawing
        if strokes.count > strokesBeforeCancel, let wet = strokes.last {
            // The cancel COMMITTED the wet stroke: best case — style from
            // its real ink params, replace it, undo restores it as drawn.
            ideal = ShapeRecognizer.strokes(along: outlines, matching: wet)
            undoBase = canvasView.drawing
            strokes.removeLast()
            snapLog("live: wet stroke committed on cancel — styling from it")
        } else {
            // The cancel DISCARDED the wet stroke (the usual case): style
            // from the calibration, and rebuild the freehand from the trace
            // purely as the undo target.
            ideal = ShapeRecognizer.strokes(along: outlines, calibration: calibration, tool: tool)
            let freehand = ShapeRecognizer.strokes(
                along: [ShapeRecognizer.resampled(pagePoints)],
                calibration: calibration,
                tool: tool
            )
            undoBase = PKDrawing(strokes: strokes + freehand)
        }
        strokes.append(contentsOf: ideal)
        canvasView.drawing = PKDrawing(strokes: strokes)
        snapLog("live-snapped mid-touch (calibrated ink) -> %d outline(s)", outlines.count)
        UISelectionFeedbackGenerator().selectionChanged()
        onSnap?(undoBase)
        return true
    }

    /// Called by the container from `canvasViewDidEndUsingTool` once a fresh
    /// ink stroke has landed. Snaps it if the Pencil was held at its end.
    func inkStrokeDidEnd() {
        // Every committed ink stroke refreshes the calibration for its ink
        // type — the live snap styles ideal shapes from these measured
        // params, because its own wet stroke never commits. Recorded before
        // any gate (and before a lift-snap swaps the stroke away).
        if let canvasView, let tool = canvasView.tool as? PKInkingTool,
           let last = canvasView.drawing.strokes.last {
            let calibration = ShapeRecognizer.calibration(from: last, toolWidth: tool.width)
            inkCalibrations[tool.inkType] = calibration
            snapLog("ink calibration %@: size=%.2f (tool width %.2f)",
                    tool.inkType.rawValue, Double(calibration.style.size.width), Double(tool.width))
        }
        defer { pendingSnap = false }
        guard isEnabled else { return }
        guard pendingSnap else {
            snapLog("stroke ended without a hold — no snap")
            return
        }
        guard let canvasView, let last = canvasView.drawing.strokes.last else { return }

        // The hold must have happened at the stroke's end: a mid-stroke pause
        // followed by more drawing means the user was thinking, not snapping.
        let zoom = max(0.01, canvasView.zoomScale)
        if let end = last.path.last?.location.applying(last.transform) {
            let endContent = CGPoint(x: end.x * zoom, y: end.y * zoom)
            let drift = hypot(endContent.x - holdLocation.x, endContent.y - holdLocation.y)
            guard drift < 60 else {
                snapLog("hold was mid-stroke (%.0f pt from the end) — no snap", drift)
                return
            }
        }

        // The "too small to mean anything" gate lives in page points — scale
        // it by zoom so a shape drawn at a comfortable SCREEN size still snaps
        // when the canvas is zoomed far in.
        let minDiag = max(7, 22 / max(1, zoom))
        guard let ideal = ShapeRecognizer.idealize(last, minDiag: minDiag), !ideal.isEmpty else {
            snapLog("no ideal fit for the stroke — kept as drawn")
            return
        }

        let before = canvasView.drawing
        var strokes = before.strokes
        strokes.removeLast()
        strokes.append(contentsOf: ideal)
        canvasView.drawing = PKDrawing(strokes: strokes)
        snapLog("snapped stroke -> %d outline(s)", ideal.count)
        UISelectionFeedbackGenerator().selectionChanged()
        onSnap?(before)
    }
}

/// Debug trace for the draw-and-hold pipeline (visible via
/// `log stream --predicate 'processImagePath CONTAINS "Notey"'`).
func snapLog(_ format: String, _ args: CVarArg...) {
    #if DEBUG
    NSLog("[ShapeSnap] \(String(format: format, arguments: args))")
    #endif
}

// MARK: - Recognition engine (pure geometry — no PencilKit below this line
// until the "PencilKit bridge" mark, so a host-side harness can compile and
// exercise the classifier with synthetic strokes)

enum ShapeRecognizer {

    // Tunables. Fractions are relative to the stroke's own size; absolute
    // values are page points. (Internal, not private: minDiag is the default
    // argument of the internal entry points.)
    enum Tune {
        static let minDiag: CGFloat = 22            // ignore dots / tiny scribbles
        static let resample: CGFloat = 3            // uniform sampling step
        static let cornerTurn: CGFloat = .pi * 47 / 180
        static let lineTolerance: CGFloat = 0.05    // maxPerp / chord
        static let segmentTolerance: CGFloat = 0.07 // per polyline segment
        static let angleSnap: CGFloat = .pi * 6 / 180
        static let ellipseResidual: CGFloat = 0.085 // mean |ρ−1|
        static let arcResidual: CGFloat = 0.04      // rms vs radius
        static let curveError: CGFloat = 2.6        // Bézier fit tolerance
        static let outlineStep: CGFloat = 3.5       // output sampling
    }

    /// Pure geometry entry point: a freehand outline (already in page
    /// coordinates, uniformly resampled) → the idealized outline(s), or nil
    /// when the stroke is too small to mean anything. Always produces
    /// SOMETHING for a deliberate hold: an exact primitive when one fits,
    /// otherwise a cleaned-up curve.
    static func idealOutlines(for raw: [CGPoint], minDiag: CGFloat = Tune.minDiag) -> [[CGPoint]]? {
        // Normalize the input first: live touch traces are TIME-sampled, so
        // slow passages pile points up and sample-count windows (smoothing,
        // corner detection) stop meaning a consistent arc span — resample to
        // uniform spacing. Then collapse the dwell knots at either end (the
        // pencil resting during hold-to-snap) that read as phantom corners.
        let cleaned = collapseDwell(resampled(raw))
        guard cleaned.count >= 6 else { return nil }
        let pts = smoothed(cleaned)

        let box = boundingBox(pts)
        let diag = hypot(box.width, box.height)
        guard diag > minDiag else { return nil }

        let len = pathLength(pts)
        let gap = dist(pts.first!, pts.last!)
        let closed = gap < min(0.30 * len, 0.42 * diag) && len > 1.55 * diag

        let outlines = closed
            ? closedShape(pts, diag: diag, len: len)
            : openShape(pts, diag: diag, len: len)
        return outlines?.filter { $0.count >= 2 }
    }

    // MARK: Closed shapes

    private static func closedShape(_ pts: [CGPoint], diag: CGFloat, len: CGFloat) -> [[CGPoint]]? {
        let cornerIdx = cornerIndices(of: pts, closed: true)

        // Ellipse first: a smooth loop has no true corners (an elongated
        // ellipse can read up to two high-curvature "corners" at its ends).
        // A very clean ellipse fit wins even over detected corners — on small
        // circles the curvature inside a corner window exceeds the corner
        // threshold by itself, sprouting phantom corners (a real square still
        // loses: its residual against an ellipse is far worse).
        let ellipse = fitEllipse(pts)
        if let e = ellipse, e.residual < 0.055 {
            return [ellipseOutline(e)]
        }
        if cornerIdx.count <= 2, let e = ellipse, e.residual < Tune.ellipseResidual {
            return [ellipseOutline(e)]
        }

        let vertices = cornerIdx.map { pts[$0] }
        switch vertices.count {
        case 3:
            return [sampleOutline(vertices, closed: true)]
        case 4:
            if let rect = fitRectangle(vertices) {
                return [sampleOutline(rect, closed: true)]
            }
            return [sampleOutline(vertices, closed: true)]
        case 5...8:
            return [sampleOutline(vertices, closed: true)]
        default:
            // Not an ellipse and no clean corner structure — a heart, a cloud,
            // an organic blob. Clean it into a smooth closed curve instead of
            // forcing a wrong primitive.
            return [smoothedLoop(pts, len: len)]
        }
    }

    // MARK: Open shapes

    private static func openShape(_ pts: [CGPoint], diag: CGFloat, len: CGFloat) -> [[CGPoint]]? {
        let cornerIdx = cornerIndices(of: pts, closed: false)

        // 1. Arrow — the specific pattern goes first so its head is not eaten
        //    by the generic line / polyline cases.
        if let arrow = fitArrow(pts, cornerIdx: cornerIdx, len: len) {
            let back = mul(arrow.dir, -1)
            let b1 = add(arrow.tip, mul(rotated(back, .pi / 6.4), arrow.barb))   // ≈28°
            let b2 = add(arrow.tip, mul(rotated(back, -.pi / 6.4), arrow.barb))
            return [
                arrow.shaft,
                sampleOutline([arrow.tip, b1], closed: false),
                sampleOutline([arrow.tip, b2], closed: false)
            ]
        }

        // 2. Straight line, snapped to the 45° grid when close.
        let chord = dist(pts.first!, pts.last!)
        if chord > 1, maxPerpDistance(pts, a: pts.first!, b: pts.last!) < max(Tune.lineTolerance * chord, 4) {
            return [idealLinePoints(from: pts.first!, to: pts.last!)]
        }

        // 3. Polyline with straight segments (L, V, zigzag).
        if !cornerIdx.isEmpty, cornerIdx.count <= 4, segmentsAreStraight(pts, cornerIdx: cornerIdx) {
            let vertices = [pts.first!] + cornerIdx.map { pts[$0] } + [pts.last!]
            return [sampleOutline(vertices, closed: false)]
        }

        // 4. Circular arc (C / U shapes, semicircles).
        if cornerIdx.isEmpty, let arc = fitArc(pts, diag: diag) {
            return [arcOutline(arc)]
        }

        // 5. Everything else: a smooth piecewise-cubic Bézier fit — corners
        //    split the fit so sharp features survive.
        let curve = fitCurvePolyline(pts, cornerIdx: cornerIdx, maxError: max(Tune.curveError, 0.008 * len))
        guard curve.count >= 2 else { return nil }
        return [curve]
    }

    private static func segmentsAreStraight(_ pts: [CGPoint], cornerIdx: [Int]) -> Bool {
        let cuts = [0] + cornerIdx + [pts.count - 1]
        for k in 0..<cuts.count - 1 where cuts[k + 1] > cuts[k] {
            let seg = Array(pts[cuts[k]...cuts[k + 1]])
            guard seg.count >= 2 else { continue }
            let chord = dist(seg.first!, seg.last!)
            if maxPerpDistance(seg, a: seg.first!, b: seg.last!) > max(Tune.segmentTolerance * chord, 4) {
                return false
            }
        }
        return true
    }

    // MARK: Line

    private static func idealLinePoints(from a: CGPoint, to b: CGPoint) -> [CGPoint] {
        let d = dist(a, b)
        guard d > 1 else { return [a, b] }
        let angle = atan2(b.y - a.y, b.x - a.x)
        let step: CGFloat = .pi / 4
        let snapped = (angle / step).rounded() * step
        if abs(normalizedAngle(angle - snapped)) < Tune.angleSnap {
            // Rotate around the midpoint so the line stays where it was drawn.
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            let half = mul(CGPoint(x: cos(snapped), y: sin(snapped)), d / 2)
            return sampleOutline([sub(mid, half), add(mid, half)], closed: false)
        }
        return sampleOutline([a, b], closed: false)
    }

    // MARK: Arrow

    private struct ArrowFit {
        let shaft: [CGPoint]     // sampled ideal shaft, tail → tip
        let tip: CGPoint
        let dir: CGPoint         // unit tangent INTO the tip
        let barb: CGFloat
    }

    /// Single-stroke arrows: a long shaft (straight or smoothly curved) whose
    /// trailing 1–3 short segments fold back sharply around the tip — covers
    /// hook heads (shaft→tip→barb) and full V heads (…→barb→tip→barb).
    private static func fitArrow(_ pts: [CGPoint], cornerIdx: [Int], len: CGFloat) -> ArrowFit? {
        guard (1...3).contains(cornerIdx.count) else { return nil }
        // The first corner is the tip — everything before it must be the
        // smooth shaft (any shaft bend would have registered as a corner).
        let tipIdx = cornerIdx[0]
        guard tipIdx > 4, tipIdx < pts.count - 2 else { return nil }

        let shaftPts = Array(pts[0...tipIdx])
        let headPts = Array(pts[tipIdx...])
        let shaftLen = pathLength(shaftPts)
        let headLen = pathLength(headPts)
        let tip = pts[tipIdx]
        guard headLen > 7, headLen < 0.55 * shaftLen, shaftLen > 30 else { return nil }

        // Sharp turn into the head (> ~100°).
        let backIdx = max(0, tipIdx - max(3, min(8, tipIdx / 4)))
        let outIdx = min(pts.count - 1, tipIdx + max(2, min(8, (pts.count - 1 - tipIdx) / 2)))
        let incoming = unit(sub(tip, pts[backIdx]))
        let outgoing = unit(sub(pts[outIdx], tip))
        guard dot(incoming, outgoing) < -0.2 else { return nil }

        // The head folds BACK: no head point keeps making forward progress
        // past the tip along the shaft direction (that would be the stroke
        // continuing, not an arrowhead).
        let forwardReach = headPts.map { dot(sub($0, tip), incoming) }.max() ?? 0
        guard forwardReach < max(6, 0.25 * headLen) else { return nil }

        let headSegments = CGFloat(cornerIdx.count)
        let barb = min(max(headLen / headSegments * 0.9, 11), 46)
        let chord = dist(shaftPts[0], tip)

        if maxPerpDistance(shaftPts, a: shaftPts[0], b: tip) < max(0.06 * chord, 4.5) {
            // Straight shaft → snapped ideal line.
            let line = idealLinePoints(from: shaftPts[0], to: tip)
            guard line.count >= 2 else { return nil }
            return ArrowFit(
                shaft: line,
                tip: line.last!,
                dir: unit(sub(line.last!, line.first!)),
                barb: barb
            )
        }

        // Curved shaft → Bézier-fit it; the head follows the end tangent.
        let fitted = fitSmoothCurve(shaftPts, maxError: max(Tune.curveError, 0.01 * shaftLen))
        guard fitted.count >= 2 else { return nil }
        return ArrowFit(
            shaft: fitted,
            tip: fitted.last!,
            dir: unit(sub(fitted.last!, fitted[fitted.count - 2])),
            barb: barb
        )
    }

    // MARK: Ellipse (second-moment fit — handles any tilt)

    private struct EllipseFit {
        let center: CGPoint
        let angle: CGFloat
        let rx: CGFloat
        let ry: CGFloat
        let residual: CGFloat    // mean |ρ − 1| in the ellipse frame
    }

    private static func fitEllipse(_ pts: [CGPoint]) -> EllipseFit? {
        guard pts.count >= 12 else { return nil }
        let n = CGFloat(pts.count)
        var cx: CGFloat = 0, cy: CGFloat = 0
        for p in pts { cx += p.x; cy += p.y }
        cx /= n; cy /= n

        var sxx: CGFloat = 0, syy: CGFloat = 0, sxy: CGFloat = 0
        for p in pts {
            let dx = p.x - cx, dy = p.y - cy
            sxx += dx * dx; syy += dy * dy; sxy += dx * dy
        }
        sxx /= n; syy /= n; sxy /= n

        var angle = 0.5 * atan2(2 * sxy, sxx - syy)
        let tr = sxx + syy
        let det = sxx * syy - sxy * sxy
        let disc = max(0, tr * tr / 4 - det)
        // Outline points sampled around an ellipse have variance ≈ r²/2 along
        // each principal axis.
        var rx = sqrt(2 * max(0.0001, tr / 2 + sqrt(disc)))
        var ry = sqrt(2 * max(0.0001, tr / 2 - sqrt(disc)))
        guard rx > 5, ry > 3 else { return nil }

        let ca = cos(angle), sa = sin(angle)
        var sum: CGFloat = 0
        for p in pts {
            let dx = p.x - cx, dy = p.y - cy
            let x = (dx * ca + dy * sa) / rx
            let y = (-dx * sa + dy * ca) / ry
            sum += abs(hypot(x, y) - 1)
        }
        let residual = sum / n

        if ry / rx > 0.82 {
            // Nearly round → perfect circle.
            let r = (rx + ry) / 2
            rx = r; ry = r; angle = 0
        } else {
            // Snap a slightly tilted ellipse onto the axes.
            if abs(normalizedAngle(angle)) < Tune.angleSnap { angle = 0 }
            if abs(abs(normalizedAngle(angle)) - .pi / 2) < Tune.angleSnap { angle = .pi / 2 }
        }
        return EllipseFit(center: CGPoint(x: cx, y: cy), angle: angle, rx: rx, ry: ry, residual: residual)
    }

    private static func ellipseOutline(_ e: EllipseFit) -> [CGPoint] {
        let steps = max(48, Int((2 * .pi * max(e.rx, e.ry)) / Tune.outlineStep))
        let ca = cos(e.angle), sa = sin(e.angle)
        var out: [CGPoint] = []
        out.reserveCapacity(steps + 1)
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
            let x = e.rx * cos(t), y = e.ry * sin(t)
            out.append(CGPoint(
                x: e.center.x + x * ca - y * sa,
                y: e.center.y + x * sa + y * ca
            ))
        }
        return out
    }

    // MARK: Rectangle (any rotation, from 4 corner points)

    private static func fitRectangle(_ v: [CGPoint]) -> [CGPoint]? {
        guard v.count == 4 else { return nil }
        let tol: CGFloat = .pi * 15 / 180
        let edges = (0..<4).map { sub(v[($0 + 1) % 4], v[$0]) }
        let dirs = edges.map { atan2($0.y, $0.x) }

        func deltaMod(_ a: CGFloat, _ b: CGFloat, _ m: CGFloat) -> CGFloat {
            var d = abs(a - b).truncatingRemainder(dividingBy: m)
            if d > m / 2 { d = m - d }
            return d
        }
        // Opposite sides parallel, adjacent sides perpendicular.
        guard deltaMod(dirs[0], dirs[2], .pi) < tol,
              deltaMod(dirs[1], dirs[3], .pi) < tol,
              abs(deltaMod(dirs[0], dirs[1], .pi) - .pi / 2) < tol
        else { return nil }

        // Mean orientation modulo 90° (angles ×4 on the unit circle), weighted
        // by edge length so long sides dominate.
        var sx: CGFloat = 0, sy: CGFloat = 0
        for (i, d) in dirs.enumerated() {
            let w = hypot(edges[i].x, edges[i].y)
            sx += cos(d * 4) * w
            sy += sin(d * 4) * w
        }
        var theta = atan2(sy, sx) / 4
        if abs(theta) < .pi * 7 / 180 { theta = 0 }   // axis snap

        let u = CGPoint(x: cos(theta), y: sin(theta))
        let nrm = CGPoint(x: -u.y, y: u.x)
        let c = CGPoint(
            x: (v[0].x + v[1].x + v[2].x + v[3].x) / 4,
            y: (v[0].y + v[1].y + v[2].y + v[3].y) / 4
        )
        let du = v.map { dot(sub($0, c), u) }
        let dn = v.map { dot(sub($0, c), nrm) }
        let halfW = du.map(abs).reduce(0, +) / 4
        let halfH = dn.map(abs).reduce(0, +) / 4
        guard halfW > 4, halfH > 4 else { return nil }

        // Rebuild each drawn corner at its ideal spot (order preserved).
        return v.indices.map { i in
            add(c, add(mul(u, du[i] < 0 ? -halfW : halfW), mul(nrm, dn[i] < 0 ? -halfH : halfH)))
        }
    }

    // MARK: Circular arc (Kåsa least-squares circle)

    private struct ArcFitResult {
        let center: CGPoint
        let radius: CGFloat
        let start: CGFloat
        let sweep: CGFloat
    }

    private static func fitArc(_ pts: [CGPoint], diag: CGFloat) -> ArcFitResult? {
        let n = CGFloat(pts.count)
        guard pts.count >= 8 else { return nil }
        var sx: CGFloat = 0, sy: CGFloat = 0, sxx: CGFloat = 0, syy: CGFloat = 0, sxy: CGFloat = 0
        var sxz: CGFloat = 0, syz: CGFloat = 0, sz: CGFloat = 0
        for p in pts {
            let z = p.x * p.x + p.y * p.y
            sx += p.x; sy += p.y
            sxx += p.x * p.x; syy += p.y * p.y; sxy += p.x * p.y
            sxz += p.x * z; syz += p.y * z; sz += z
        }
        // Solve for x² + y² + Dx + Ey + F = 0 (3×3 normal equations).
        var m: [[CGFloat]] = [
            [sxx, sxy, sx, -sxz],
            [sxy, syy, sy, -syz],
            [sx, sy, n, -sz]
        ]
        guard solve3(&m), m[0][3].isFinite, m[1][3].isFinite, m[2][3].isFinite else { return nil }
        let center = CGPoint(x: -m[0][3] / 2, y: -m[1][3] / 2)
        let r2 = center.x * center.x + center.y * center.y - m[2][3]
        guard r2 > 0 else { return nil }
        let r = sqrt(r2)
        // A straight-ish stroke fits a huge circle — that is a line, not an arc.
        guard r > 6, r < 2.4 * diag else { return nil }

        var rms: CGFloat = 0
        for p in pts {
            let d = dist(p, center) - r
            rms += d * d
        }
        rms = sqrt(rms / n)
        guard rms < max(3, Tune.arcResidual * r) else { return nil }

        // Unwrapped angles along the stroke: keeps the sweep direction and
        // rejects strokes that double back.
        var angles: [CGFloat] = []
        angles.reserveCapacity(pts.count)
        var acc = atan2(pts[0].y - center.y, pts[0].x - center.x)
        angles.append(acc)
        var total: CGFloat = 0
        for p in pts.dropFirst() {
            let raw = atan2(p.y - center.y, p.x - center.x)
            let delta = normalizedAngle(raw - acc.truncatingRemainder(dividingBy: 2 * .pi))
            acc += delta
            total += abs(delta)
            angles.append(acc)
        }
        let sweep = angles.last! - angles.first!
        guard abs(sweep) > .pi * 30 / 180, abs(sweep) < .pi * 1.97,
              total < abs(sweep) * 1.4 + 0.2
        else { return nil }
        return ArcFitResult(center: center, radius: r, start: angles.first!, sweep: sweep)
    }

    private static func arcOutline(_ arc: ArcFitResult) -> [CGPoint] {
        let steps = max(10, Int(abs(arc.sweep) * arc.radius / Tune.outlineStep))
        var out: [CGPoint] = []
        out.reserveCapacity(steps + 1)
        for i in 0...steps {
            let a = arc.start + arc.sweep * CGFloat(i) / CGFloat(steps)
            out.append(CGPoint(
                x: arc.center.x + arc.radius * cos(a),
                y: arc.center.y + arc.radius * sin(a)
            ))
        }
        return out
    }

    /// In-place Gaussian elimination with partial pivoting for a 3×4 system.
    private static func solve3(_ m: inout [[CGFloat]]) -> Bool {
        for col in 0..<3 {
            var pivot = col
            for row in (col + 1)..<3 where abs(m[row][col]) > abs(m[pivot][col]) { pivot = row }
            if abs(m[pivot][col]) < 1e-9 { return false }
            m.swapAt(col, pivot)
            let div = m[col][col]
            for k in col..<4 { m[col][k] /= div }
            for row in 0..<3 where row != col {
                let f = m[row][col]
                guard f != 0 else { continue }
                for k in col..<4 { m[row][k] -= f * m[col][k] }
            }
        }
        return true
    }

    // MARK: Smooth curve (piecewise cubic Bézier, Schneider's algorithm)

    private static func fitCurvePolyline(_ pts: [CGPoint], cornerIdx: [Int], maxError: CGFloat) -> [CGPoint] {
        let cuts = ([0] + cornerIdx + [pts.count - 1]).reduce(into: [Int]()) {
            if $0.last != $1 { $0.append($1) }
        }
        var out: [CGPoint] = []
        for k in 0..<cuts.count - 1 {
            let piece = Array(pts[cuts[k]...cuts[k + 1]])
            let sampled = fitSmoothCurve(piece, maxError: maxError)
            out += out.isEmpty ? sampled : Array(sampled.dropFirst())
        }
        return out
    }

    private static func fitSmoothCurve(_ pts: [CGPoint], maxError: CGFloat) -> [CGPoint] {
        guard pts.count >= 2 else { return pts }
        let cubics = BezierFitter.fit(pts, maxError: maxError)
        guard !cubics.isEmpty else { return pts }
        var out: [CGPoint] = []
        for (i, c) in cubics.enumerated() {
            let samples = c.sampled(spacing: Tune.outlineStep)
            out += i == 0 ? samples : Array(samples.dropFirst())
        }
        return out
    }

    // MARK: Smooth closed loop (cleaned organic shape)

    private static func smoothedLoop(_ pts: [CGPoint], len: CGFloat) -> [CGPoint] {
        var v = rdp(pts, epsilon: max(3, len * 0.008))
        if v.count > 1, dist(v[0], v[v.count - 1]) < 1 { v.removeLast() }
        guard v.count >= 3 else { return pts }
        let n = v.count
        var out: [CGPoint] = []
        for i in 0..<n {
            let p0 = v[(i + n - 1) % n]
            let p1 = v[i]
            let p2 = v[(i + 1) % n]
            let p3 = v[(i + 2) % n]
            let steps = max(2, Int(dist(p1, p2) / Tune.outlineStep))
            for s in 0..<steps {
                out.append(catmullRom(p0, p1, p2, p3, CGFloat(s) / CGFloat(steps)))
            }
        }
        if let first = out.first { out.append(first) }
        return out
    }

    private static func catmullRom(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ t: CGFloat) -> CGPoint {
        let t2 = t * t, t3 = t2 * t
        func axis(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
            0.5 * ((2 * b) + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3)
        }
        return CGPoint(x: axis(p0.x, p1.x, p2.x, p3.x), y: axis(p0.y, p1.y, p2.y, p3.y))
    }

    // MARK: Corners

    /// Indices of true direction changes: local maxima of the turning angle
    /// measured over a size-adaptive window (so gentle curvature never reads
    /// as a corner, and real corners always do).
    private static func cornerIndices(of pts: [CGPoint], closed: Bool) -> [Int] {
        let n = pts.count
        guard n >= 8 else { return [] }
        let w = max(2, min(12, n / 16))

        func pt(_ i: Int) -> CGPoint {
            closed ? pts[((i % n) + n) % n] : pts[max(0, min(n - 1, i))]
        }

        var turn = [CGFloat](repeating: 0, count: n)
        let lo = closed ? 0 : w
        let hi = closed ? n : n - w
        for i in lo..<hi {
            let a = sub(pt(i), pt(i - w))
            let b = sub(pt(i + w), pt(i))
            guard hypot(a.x, a.y) > 0.5, hypot(b.x, b.y) > 0.5 else { continue }
            turn[i] = angleBetween(a, b)
        }

        var result: [Int] = []
        var i = lo
        while i < hi {
            guard turn[i] >= Tune.cornerTurn else { i += 1; continue }
            // Take the peak of this above-threshold hump.
            var peak = i
            var j = i + 1
            while j < hi, turn[j] >= Tune.cornerTurn * 0.75 {
                if turn[j] > turn[peak] { peak = j }
                j += 1
            }
            result.append(peak)
            i = max(j, peak + w)
        }

        // A closed stroke can split one corner across the wrap seam.
        if closed, result.count >= 2,
           let first = result.first, let last = result.last,
           first + n - last < 2 * w {
            result.removeLast()
        }
        return result
    }

    /// Sample a polyline for PencilKit: ~4pt spacing along edges plus tight
    /// 1pt brackets around each vertex, so the spline keeps corners sharp.
    private static func sampleOutline(_ vertices: [CGPoint], closed: Bool) -> [CGPoint] {
        var v = vertices
        if closed, let first = v.first { v.append(first) }
        guard v.count >= 2 else { return v }
        var out: [CGPoint] = []
        for i in 0..<v.count - 1 {
            let a = v[i], b = v[i + 1]
            let d = dist(a, b)
            guard d > 0.01 else { continue }
            var distances: [CGFloat] = [0]
            if d > 3 { distances.append(1) }
            var s: CGFloat = 4
            while s < d - 2 { distances.append(s); s += 4 }
            if d > 3 { distances.append(d - 1) }
            for t in distances {
                out.append(lerp(a, b, t / d))
            }
        }
        out.append(v.last!)
        return out
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

    // MARK: Geometry helpers

    /// Uniform arc-length resampling (also subsumes de-duplication — points
    /// that don't advance the path emit nothing).
    static func resampled(_ pts: [CGPoint], step: CGFloat = Tune.resample) -> [CGPoint] {
        guard let first = pts.first, pts.count > 1 else { return pts }
        var out = [first]
        var acc: CGFloat = 0
        var prev = first
        for p in pts.dropFirst() {
            var from = prev
            var remaining = dist(from, p)
            while remaining > 0, acc + remaining >= step {
                let t = (step - acc) / remaining
                let next = lerp(from, p, t)
                out.append(next)
                remaining -= (step - acc)
                from = next
                acc = 0
            }
            acc += remaining
            prev = p
        }
        if let last = pts.last, dist(out[out.count - 1], last) > 0.5 {
            out.append(last)
        }
        return out
    }

    /// Collapse a dwell cluster (pencil resting in place) at either end of the
    /// stroke into its centroid — one clean endpoint instead of a noise knot.
    private static func collapseDwell(_ pts: [CGPoint]) -> [CGPoint] {
        func clusterEnd(_ seq: [CGPoint]) -> [CGPoint] {
            guard let anchor = seq.last, seq.count > 3 else { return seq }
            var i = seq.count - 1
            while i > 0, dist(seq[i - 1], anchor) < 3.5 { i -= 1 }
            let cluster = seq.count - i
            guard cluster >= 3 else { return seq }
            var cx: CGFloat = 0, cy: CGFloat = 0
            for p in seq[i...] { cx += p.x; cy += p.y }
            return Array(seq[..<i]) + [CGPoint(x: cx / CGFloat(cluster), y: cy / CGFloat(cluster))]
        }
        return Array(clusterEnd(Array(clusterEnd(pts).reversed())).reversed())
    }

    private static func smoothed(_ pts: [CGPoint]) -> [CGPoint] {
        guard pts.count >= 5 else { return pts }
        var out = pts
        for i in 1..<pts.count - 1 {
            out[i] = CGPoint(
                x: (pts[i - 1].x + 2 * pts[i].x + pts[i + 1].x) / 4,
                y: (pts[i - 1].y + 2 * pts[i].y + pts[i + 1].y) / 4
            )
        }
        return out
    }

    private static func boundingBox(_ pts: [CGPoint]) -> CGRect {
        var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for p in pts {
            minX = min(minX, p.x); minY = min(minY, p.y)
            maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func pathLength(_ pts: [CGPoint]) -> CGFloat {
        guard pts.count > 1 else { return 0 }
        var total: CGFloat = 0
        for i in 1..<pts.count { total += dist(pts[i - 1], pts[i]) }
        return total
    }

    private static func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
    private static func sub(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    private static func add(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    private static func mul(_ v: CGPoint, _ k: CGFloat) -> CGPoint { CGPoint(x: v.x * k, y: v.y * k) }
    private static func dot(_ a: CGPoint, _ b: CGPoint) -> CGFloat { a.x * b.x + a.y * b.y }
    private static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    private static func unit(_ v: CGPoint) -> CGPoint {
        let l = hypot(v.x, v.y)
        return l > 0.0001 ? CGPoint(x: v.x / l, y: v.y / l) : .zero
    }

    private static func rotated(_ v: CGPoint, _ angle: CGFloat) -> CGPoint {
        let c = cos(angle), s = sin(angle)
        return CGPoint(x: v.x * c - v.y * s, y: v.x * s + v.y * c)
    }

    /// Fold an angle into (−π, π].
    private static func normalizedAngle(_ a: CGFloat) -> CGFloat {
        var x = a.truncatingRemainder(dividingBy: 2 * .pi)
        if x > .pi { x -= 2 * .pi }
        if x <= -.pi { x += 2 * .pi }
        return x
    }

    private static func angleBetween(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let d = dot(unit(a), unit(b))
        return acos(max(-1, min(1, d)))
    }

    private static func perpendicularDistance(_ p: CGPoint, a: CGPoint, b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = hypot(dx, dy)
        guard len > 0.0001 else { return dist(p, a) }
        return abs((p.x - a.x) * dy - (p.y - a.y) * dx) / len
    }

    private static func maxPerpDistance(_ pts: [CGPoint], a: CGPoint, b: CGPoint) -> CGFloat {
        pts.reduce(0) { max($0, perpendicularDistance($1, a: a, b: b)) }
    }
}

// MARK: - Least-squares piecewise cubic Bézier fit (Schneider, Graphics Gems)

private enum BezierFitter {

    struct Cubic {
        var p0: CGPoint, c1: CGPoint, c2: CGPoint, p3: CGPoint

        func point(_ t: CGFloat) -> CGPoint {
            let u = 1 - t
            let b0 = u * u * u
            let b1 = 3 * u * u * t
            let b2 = 3 * u * t * t
            let b3 = t * t * t
            return CGPoint(
                x: b0 * p0.x + b1 * c1.x + b2 * c2.x + b3 * p3.x,
                y: b0 * p0.y + b1 * c1.y + b2 * c2.y + b3 * p3.y
            )
        }

        func sampled(spacing: CGFloat) -> [CGPoint] {
            let approxLen = (dist(p0, c1) + dist(c1, c2) + dist(c2, p3) + dist(p0, p3)) / 2
            let steps = max(3, Int(approxLen / spacing))
            return (0...steps).map { point(CGFloat($0) / CGFloat(steps)) }
        }
    }

    static func fit(_ points: [CGPoint], maxError: CGFloat) -> [Cubic] {
        guard points.count >= 2 else { return [] }
        if points.count <= 3 {
            return [lineCubic(points.first!, points.last!)]
        }
        let leftTangent = tangent(points, at: 0, forward: true)
        let rightTangent = tangent(points, at: points.count - 1, forward: false)
        var result: [Cubic] = []
        fitCubic(points, 0, points.count - 1, leftTangent, rightTangent, maxError, &result, depth: 0)
        return result.isEmpty ? [lineCubic(points.first!, points.last!)] : result
    }

    private static func lineCubic(_ a: CGPoint, _ b: CGPoint) -> Cubic {
        let d = CGPoint(x: (b.x - a.x) / 3, y: (b.y - a.y) / 3)
        return Cubic(p0: a, c1: CGPoint(x: a.x + d.x, y: a.y + d.y), c2: CGPoint(x: b.x - d.x, y: b.y - d.y), p3: b)
    }

    /// Tangent averaged over a few samples for noise robustness.
    private static func tangent(_ pts: [CGPoint], at i: Int, forward: Bool) -> CGPoint {
        let reach = min(4, pts.count - 1)
        let j = forward ? min(pts.count - 1, i + reach) : max(0, i - reach)
        return unit(CGPoint(x: pts[j].x - pts[i].x, y: pts[j].y - pts[i].y))
    }

    private static func fitCubic(
        _ pts: [CGPoint], _ first: Int, _ last: Int,
        _ tHat1: CGPoint, _ tHat2: CGPoint,
        _ maxError: CGFloat, _ result: inout [Cubic], depth: Int
    ) {
        let nPts = last - first + 1

        // Two points: straight cubic.
        if nPts == 2 {
            result.append(lineCubic(pts[first], pts[last]))
            return
        }

        var u = chordLengthParameterize(pts, first, last)
        var bez = generateBezier(pts, first, last, u, tHat1, tHat2)
        var (maxDist, splitPoint) = computeMaxError(pts, first, last, bez, u)

        if maxDist < maxError {
            result.append(bez)
            return
        }

        // Try reparameterizing a couple of times before giving up.
        if maxDist < maxError * maxError {
            for _ in 0..<3 {
                u = reparameterize(pts, first, last, u, bez)
                bez = generateBezier(pts, first, last, u, tHat1, tHat2)
                (maxDist, splitPoint) = computeMaxError(pts, first, last, bez, u)
                if maxDist < maxError {
                    result.append(bez)
                    return
                }
            }
        }

        if depth > 16 || splitPoint <= first || splitPoint >= last {
            result.append(bez)
            return
        }

        // Split at the worst point; center tangent keeps G1 continuity.
        let centerTangent = unit(CGPoint(
            x: pts[splitPoint - 1].x - pts[splitPoint + 1].x,
            y: pts[splitPoint - 1].y - pts[splitPoint + 1].y
        ))
        fitCubic(pts, first, splitPoint, tHat1, centerTangent, maxError, &result, depth: depth + 1)
        fitCubic(pts, splitPoint, last, CGPoint(x: -centerTangent.x, y: -centerTangent.y), tHat2, maxError, &result, depth: depth + 1)
    }

    private static func generateBezier(
        _ pts: [CGPoint], _ first: Int, _ last: Int,
        _ u: [CGFloat], _ tHat1: CGPoint, _ tHat2: CGPoint
    ) -> Cubic {
        let nPts = last - first + 1
        var c00: CGFloat = 0, c01: CGFloat = 0, c11: CGFloat = 0
        var x0: CGFloat = 0, x1: CGFloat = 0
        let p0 = pts[first], p3 = pts[last]

        for i in 0..<nPts {
            let t = u[i]
            let om = 1 - t
            let b0 = om * om * om
            let b1 = 3 * t * om * om
            let b2 = 3 * t * t * om
            let b3 = t * t * t
            let a1 = CGPoint(x: tHat1.x * b1, y: tHat1.y * b1)
            let a2 = CGPoint(x: tHat2.x * b2, y: tHat2.y * b2)

            c00 += a1.x * a1.x + a1.y * a1.y
            c01 += a1.x * a2.x + a1.y * a2.y
            c11 += a2.x * a2.x + a2.y * a2.y

            let tmp = CGPoint(
                x: pts[first + i].x - (p0.x * (b0 + b1) + p3.x * (b2 + b3)),
                y: pts[first + i].y - (p0.y * (b0 + b1) + p3.y * (b2 + b3))
            )
            x0 += a1.x * tmp.x + a1.y * tmp.y
            x1 += a2.x * tmp.x + a2.y * tmp.y
        }

        let detC0C1 = c00 * c11 - c01 * c01
        let detC0X = c00 * x1 - c01 * x0
        let detXC1 = x0 * c11 - x1 * c01
        var alphaL = detC0C1 == 0 ? 0 : detXC1 / detC0C1
        var alphaR = detC0C1 == 0 ? 0 : detC0X / detC0C1

        // Degenerate alphas → Wu/Barsky heuristic (1/3 of the chord).
        let segLength = dist(p0, p3)
        let epsilon = 1e-6 * segLength
        if alphaL < epsilon || alphaR < epsilon {
            alphaL = segLength / 3
            alphaR = segLength / 3
        }

        return Cubic(
            p0: p0,
            c1: CGPoint(x: p0.x + tHat1.x * alphaL, y: p0.y + tHat1.y * alphaL),
            c2: CGPoint(x: p3.x + tHat2.x * alphaR, y: p3.y + tHat2.y * alphaR),
            p3: p3
        )
    }

    private static func chordLengthParameterize(_ pts: [CGPoint], _ first: Int, _ last: Int) -> [CGFloat] {
        var u: [CGFloat] = [0]
        u.reserveCapacity(last - first + 1)
        for i in (first + 1)...last {
            u.append(u[u.count - 1] + dist(pts[i - 1], pts[i]))
        }
        let total = max(u.last!, 0.0001)
        return u.map { $0 / total }
    }

    private static func computeMaxError(
        _ pts: [CGPoint], _ first: Int, _ last: Int, _ bez: Cubic, _ u: [CGFloat]
    ) -> (CGFloat, Int) {
        var maxDist: CGFloat = 0
        var splitPoint = (last - first + 1) / 2 + first
        for i in (first + 1)..<last {
            let p = bez.point(u[i - first])
            let d = dist(p, pts[i])
            if d >= maxDist {
                maxDist = d
                splitPoint = i
            }
        }
        return (maxDist, splitPoint)
    }

    /// One Newton–Raphson step per point, moving each parameter toward the
    /// closest spot on the current curve.
    private static func reparameterize(
        _ pts: [CGPoint], _ first: Int, _ last: Int, _ u: [CGFloat], _ bez: Cubic
    ) -> [CGFloat] {
        var out = u
        for i in first...last {
            out[i - first] = newtonRaphson(bez, pts[i], u[i - first])
        }
        return out
    }

    private static func newtonRaphson(_ q: Cubic, _ p: CGPoint, _ u: CGFloat) -> CGFloat {
        // Q(u) and its first/second derivative control points.
        let q1 = [
            CGPoint(x: (q.c1.x - q.p0.x) * 3, y: (q.c1.y - q.p0.y) * 3),
            CGPoint(x: (q.c2.x - q.c1.x) * 3, y: (q.c2.y - q.c1.y) * 3),
            CGPoint(x: (q.p3.x - q.c2.x) * 3, y: (q.p3.y - q.c2.y) * 3)
        ]
        let q2 = [
            CGPoint(x: (q1[1].x - q1[0].x) * 2, y: (q1[1].y - q1[0].y) * 2),
            CGPoint(x: (q1[2].x - q1[1].x) * 2, y: (q1[2].y - q1[1].y) * 2)
        ]
        let qu = q.point(u)
        let om = 1 - u
        let q1u = CGPoint(
            x: om * om * q1[0].x + 2 * om * u * q1[1].x + u * u * q1[2].x,
            y: om * om * q1[0].y + 2 * om * u * q1[1].y + u * u * q1[2].y
        )
        let q2u = CGPoint(
            x: om * q2[0].x + u * q2[1].x,
            y: om * q2[0].y + u * q2[1].y
        )
        let numerator = (qu.x - p.x) * q1u.x + (qu.y - p.y) * q1u.y
        let denominator = q1u.x * q1u.x + q1u.y * q1u.y + (qu.x - p.x) * q2u.x + (qu.y - p.y) * q2u.y
        guard abs(denominator) > 1e-9 else { return u }
        return min(1, max(0, u - numerator / denominator))
    }

    private static func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    private static func unit(_ v: CGPoint) -> CGPoint {
        let l = hypot(v.x, v.y)
        return l > 0.0001 ? CGPoint(x: v.x / l, y: v.y / l) : .zero
    }
}

// MARK: - PencilKit bridge

extension ShapeRecognizer {

    /// Returns the idealized stroke(s) for `stroke`, or nil when nothing
    /// should change. Geometry comes from `idealOutlines`; the original ink
    /// character (tool, color, width) is preserved via `InkStyle`.
    static func idealize(_ stroke: PKStroke, minDiag: CGFloat = Tune.minDiag) -> [PKStroke]? {
        let raw = stroke.path.interpolatedPoints(by: .distance(3))
            .map { $0.location.applying(stroke.transform) }
        guard let outlines = idealOutlines(for: raw, minDiag: minDiag), !outlines.isEmpty else { return nil }
        return strokes(along: outlines, matching: stroke)
    }

    /// Strokes along `outlines` styled like an existing stroke (median ink
    /// params — pressure spikes don't skew the rebuilt width).
    static func strokes(along outlines: [[CGPoint]], matching stroke: PKStroke) -> [PKStroke] {
        let ink = InkStyle(stroke: stroke)
        return outlines.map { ink.stroke(along: $0) }
    }

    /// Measured ink params of a real committed stroke, tagged with the tool
    /// width that produced them. The live snap styles its ideal shapes from
    /// these (scaled to the current tool width) — its own wet stroke never
    /// commits, and the tool's NOMINAL width bears no relation to the point
    /// sizes PencilKit derives from pressure (it renders far too thick).
    fileprivate struct InkCalibration {
        let style: InkStyle
        let toolWidth: CGFloat
    }

    fileprivate static func calibration(from stroke: PKStroke, toolWidth: CGFloat) -> InkCalibration {
        InkCalibration(style: InkStyle(stroke: stroke), toolWidth: max(0.01, toolWidth))
    }

    /// Strokes along `outlines` styled from a calibration, re-colored and
    /// width-scaled to the CURRENT tool.
    fileprivate static func strokes(
        along outlines: [[CGPoint]],
        calibration: InkCalibration,
        tool: PKInkingTool
    ) -> [PKStroke] {
        let ink = InkStyle(calibration: calibration, tool: tool)
        return outlines.map { ink.stroke(along: $0) }
    }

    /// Uniform ink parameters sampled from the original stroke (medians, so a
    /// single pressure spike doesn't skew the rebuilt width), applied along
    /// the idealized outline.
    fileprivate struct InkStyle {
        let ink: PKInk
        let size: CGSize
        let opacity: CGFloat
        let force: CGFloat
        let azimuth: CGFloat
        let altitude: CGFloat
        let created: Date

        init(stroke: PKStroke) {
            ink = stroke.ink
            created = stroke.path.creationDate
            let n = stroke.path.count
            var widths: [CGFloat] = []
            var heights: [CGFloat] = []
            let step = max(1, n / 24)
            var i = 0
            while i < n {
                let p = stroke.path[i]
                widths.append(p.size.width)
                heights.append(p.size.height)
                i += step
            }
            widths.sort(); heights.sort()
            size = CGSize(width: widths[widths.count / 2], height: heights[heights.count / 2])
            let mid = stroke.path[n / 2]
            opacity = mid.opacity
            force = mid.force
            azimuth = mid.azimuth
            altitude = mid.altitude
        }

        /// Calibrated params re-targeted at the current tool: measured sizes
        /// scaled by the width ratio, ink (and thus color) from the tool.
        init(calibration: InkCalibration, tool: PKInkingTool) {
            let scale = tool.width / calibration.toolWidth
            let base = calibration.style
            ink = tool.ink
            created = Date()
            size = CGSize(width: base.size.width * scale, height: base.size.height * scale)
            opacity = base.opacity
            force = base.force
            azimuth = base.azimuth
            altitude = base.altitude
        }

        func stroke(along points: [CGPoint]) -> PKStroke {
            var sp: [PKStrokePoint] = []
            sp.reserveCapacity(points.count)
            for (i, p) in points.enumerated() {
                sp.append(PKStrokePoint(
                    location: p,
                    timeOffset: TimeInterval(i) * 0.008,
                    size: size,
                    opacity: opacity,
                    force: force,
                    azimuth: azimuth,
                    altitude: altitude
                ))
            }
            let path = PKStrokePath(controlPoints: sp, creationDate: created)
            return PKStroke(ink: ink, path: path, transform: .identity, mask: nil)
        }
    }
}
