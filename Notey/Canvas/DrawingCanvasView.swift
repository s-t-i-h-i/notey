import UIKit
import SwiftUI
import PencilKit

// MARK: - Tool model

enum EditorTool: String, Equatable {
    case pen, marker, eraser, lasso, objects, annotation
}

enum PenStyle: String, Equatable, CaseIterable, Identifiable {
    case ballpoint, fountain, pencil, monoline, crayon

    var id: String { rawValue }

    var inkType: PKInkingTool.InkType {
        switch self {
        case .ballpoint: return .pen
        case .fountain: return .fountainPen
        case .pencil: return .pencil
        case .monoline: return .monoline
        case .crayon: return .crayon
        }
    }

    var label: String {
        switch self {
        case .ballpoint: return "Długopis"
        case .fountain: return "Pióro"
        case .pencil: return "Ołówek"
        case .monoline: return "Cienkopis"
        case .crayon: return "Kredka"
        }
    }

    var icon: String {
        switch self {
        case .ballpoint: return "pencil.tip"
        case .fountain: return "paintbrush.pointed.fill"
        case .pencil: return "pencil"
        case .monoline: return "scribble"
        case .crayon: return "paintbrush.fill"
        }
    }
}

enum MarkerStyle: String, Equatable, CaseIterable, Identifiable {
    case classic, watercolor

    var id: String { rawValue }

    var inkType: PKInkingTool.InkType {
        switch self {
        case .classic: return .marker
        case .watercolor: return .watercolor
        }
    }

    var label: String {
        switch self {
        case .classic: return "Zakreślacz"
        case .watercolor: return "Akwarela"
        }
    }
}

enum EraserMode: String, Equatable, CaseIterable, Identifiable {
    case stroke, point, lasso

    var id: String { rawValue }

    var label: String {
        switch self {
        case .stroke: return "Cała kreska"
        case .point: return "Punktowa"
        case .lasso: return "Lasso"
        }
    }

    var icon: String {
        switch self {
        case .stroke: return "eraser"
        case .point: return "eraser.line.dashed"
        case .lasso: return "lasso"
        }
    }
}

struct CanvasToolConfig: Equatable {
    var tool: EditorTool = .pen
    var penStyle: PenStyle = .ballpoint
    var penColor: UIColor = Theme.inkColors[0]
    var penWidth: CGFloat = 4
    var markerStyle: MarkerStyle = .classic
    var markerColor: UIColor = Theme.markerColors[0]
    var markerWidth: CGFloat = 16
    var eraserMode: EraserMode = .stroke
    var eraserWidth: CGFloat = 24
    var annotationColor: UIColor = Theme.annotationColors[0]
    var fingerDraws: Bool = true
    var background: CanvasBackground = .dots
    var paperColorHex: String?
    var layout: NoteLayout = .pages
}

enum SelectedElement: Equatable {
    case image(UUID)
    case annotation(UUID)
}

// MARK: - Proxy (SwiftUI -> UIKit commands)

final class CanvasProxy: ObservableObject {
    weak var container: CanvasContainer?

    func addImage(_ image: UIImage) { container?.addImage(image) }
    func addPage() { container?.addPage() }
    func removePage() { container?.removePage() }
    func deleteSelected() { container?.deleteSelectedElement() }
    func clearAll() { container?.clearAll() }
    func undo() { container?.undoManagerForCanvas?.undo() }
    func redo() { container?.undoManagerForCanvas?.redo() }
    func exportPDF(title: String) -> URL? { container?.exportPDF(title: title) }
    /// Paste foreign ink (e.g. a quick note) into the open canvas.
    func pasteDrawing(_ drawing: PKDrawing, atViewPoint point: CGPoint? = nil) {
        container?.pasteDrawing(drawing, atViewPoint: point)
    }
}

// MARK: - SwiftUI wrapper

struct DrawingCanvas: UIViewRepresentable {
    let initialDrawing: PKDrawing
    let initialElements: CanvasElements
    var config: CanvasToolConfig
    var compact: Bool = false
    let proxy: CanvasProxy
    let onChange: (PKDrawing, CanvasElements) -> Void
    let onSelection: (SelectedElement?) -> Void

    func makeUIView(context: Context) -> CanvasContainer {
        let container = CanvasContainer(
            drawing: initialDrawing,
            elements: initialElements,
            compact: compact
        )
        container.onChange = onChange
        container.onSelection = onSelection
        container.apply(config: config)
        proxy.container = container
        return container
    }

    func updateUIView(_ container: CanvasContainer, context: Context) {
        container.onChange = onChange
        container.onSelection = onSelection
        container.apply(config: config)
        proxy.container = container
    }
}

// MARK: - Annotation card (rendered BELOW the ink)

// A colored highlight patch sitting under the handwriting. The ink image is
// only used while the card is dragged: its attached strokes are lifted off
// the canvas and baked onto the card so they cannot lag behind the drag.
private final class AnnotationCardView: UIView {
    private let content = UIView()
    private let inkView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.12
        layer.shadowRadius = 5
        layer.shadowOffset = CGSize(width: 0, height: 2)

        content.frame = bounds
        content.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        content.clipsToBounds = true
        addSubview(content)

        inkView.frame = bounds
        inkView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        inkView.contentMode = .scaleToFill
        content.addSubview(inkView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(color: UIColor) {
        content.backgroundColor = color
    }

    func setInk(_ image: UIImage?) {
        inkView.image = image
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let radius = min(14, bounds.width / 4, bounds.height / 4)
        content.layer.cornerRadius = radius
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: radius).cgPath
    }
}

// Overlay layers (lasso-eraser trail, annotation draft, selection outline)
// are standalone CAShapeLayers without a backing view, so every property
// change would get the implicit 0.25s CATransaction animation — the shape
// visibly trails behind the finger. No actions = the overlay tracks 1:1.
private final class ImmediateShapeLayer: CAShapeLayer {
    override func action(forKey event: String) -> CAAction? { nil }
}

// MARK: - Container view (pages + pattern + objects + annotations + PencilKit ink)

// Z-order, bottom to top:
//   1. page cards + background pattern
//   2. photos
//   3. annotation cards (highlight patches under the writing)
//   4. handwriting (PencilKit) — always fully visible, wet strokes included
//   5. selection outline / draft shapes (overlayHost)

final class ImmediatePanGestureRecognizer: UIPanGestureRecognizer {
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        if state == .possible {
            state = .began
        }
    }
}

final class NoteyCanvasView: PKCanvasView {
    var allowEditMenu: Bool = true
    
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if !allowEditMenu {
            return false
        }
        let actionName = NSStringFromSelector(action)
        if actionName.contains("insertSpace") || actionName.contains("selectAll") {
            return false
        }
        return super.canPerformAction(action, withSender: sender)
    }
}

final class CanvasContainer: UIView, PKCanvasViewDelegate, UIGestureRecognizerDelegate {

    let canvasView = NoteyCanvasView()
    private let objectsHost = UIView()      // below the ink: pages + photos
    private let annotationsHost = UIView()  // below the ink too: annotation cards
    private let overlayHost = UIView()      // above the ink: selection + drafts
    private let pagesHost = UIView()
    private var pageCards: [UIView] = []
    private var patternLayers: [CAShapeLayer] = []
    private let selectionLayer = ImmediateShapeLayer()
    private let draftLayer = ImmediateShapeLayer()

    private(set) var elements: CanvasElements
    private var config = CanvasToolConfig()
    private var imageViews: [UUID: UIView] = [:]
    private var annotationViews: [UUID: AnnotationCardView] = [:]
    private let compact: Bool

    var onChange: ((PKDrawing, CanvasElements) -> Void)?
    var onSelection: ((SelectedElement?) -> Void)?

    private(set) var selected: SelectedElement? {
        didSet { refreshSelectionLayer(); onSelection?(selected); updateGestureStates() }
    }

    private let page = CanvasPage.size
    private var pagesCount: Int { max(1, elements.pages ?? 1) }
    // Infinite layout: the sheet is a growing window, not a fixed size. It is
    // extended whenever the viewport or the ink nears an edge, so the canvas
    // never ends in any direction.
    private var infiniteSheet: CGSize = CanvasPage.infiniteSize
    private var sheetSize: CGSize {
        config.layout == .infinite ? infiniteSheet : page
    }
    private var totalSize: CGSize {
        config.layout == .infinite ? infiniteSheet : CanvasPage.totalSize(pages: pagesCount)
    }
    // Left/top growth must move the whole coordinate space — deferred while
    // ink or a drag is mid-flight, retried from the matching "did end" hooks.
    private var toolInUse = false
    private var pendingEdgeShift = false
    private var isAdjustingSheet = false
    private var fitScale: CGFloat = 1
    private var didInitialLayout = false
    private var horizontalInset: CGFloat { compact ? 6 : 16 }

    /// Live zoom factor (page points -> screen points).
    private var zoom: CGFloat { max(0.01, canvasView.zoomScale) }

    // Gesture state
    private var objectPan: UIPanGestureRecognizer!
    private var objectTap: UITapGestureRecognizer!
    private var annotationPan: ImmediatePanGestureRecognizer!
    private var lassoErasePan: ImmediatePanGestureRecognizer!
    private var holdPress: UILongPressGestureRecognizer!
    private var dragOriginalFrame: CGRect = .zero
    private var dragBaseDrawing = PKDrawing()
    private var dragBaseElements = CanvasElements()
    private var dragAttachedStrokes: [Int] = []
    private var dragIsResize = false
    private var dragActive = false
    // While an annotation is dragged its attached strokes are removed from
    // the PKCanvasView (the card image carries them), so the real ink can't
    // lag behind the card as a "ghost". They're re-inserted on release.
    private var dragStrokesHidden = false
    private var annotationStart: CGPoint = .zero
    private var annotationDrafting = false
    private var lassoErasePoints: [CGPoint] = []
    private var holdStartLocation: CGPoint = .zero

    // Stroke identity tracking: a stroke seen for the first time on top of an
    // annotation gets attached to it (and only then).
    private var knownStrokeKeys: Set<String> = []

    var undoManagerForCanvas: UndoManager? { canvasView.undoManager ?? undoManager }

    // MARK: Init

    init(drawing: PKDrawing, elements: CanvasElements, compact: Bool = false) {
        self.elements = elements
        self.compact = compact
        super.init(frame: .zero)
        backgroundColor = compact ? Theme.cardUI : UIColor(Theme.bg)

        // Ink colors must not invert in dark mode (WYSIWYG on the beige page).
        overrideUserInterfaceStyle = .light

        canvasView.drawing = drawing
        knownStrokeKeys = Set(drawing.strokes.map(\.fingerprint))
        canvasView.delegate = self
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.alwaysBounceVertical = true
        canvasView.contentInsetAdjustmentBehavior = .never
        // Single finger / pencil draws; two fingers scroll, pinch zooms.
        canvasView.panGestureRecognizer.minimumNumberOfTouches = 2
        // Trackpad / mouse wheel pans too (touch pans still need two fingers).
        canvasView.panGestureRecognizer.allowedScrollTypesMask = .all
        addSubview(canvasView)

        objectsHost.frame = CGRect(origin: .zero, size: totalSize)
        objectsHost.layer.anchorPoint = .zero
        objectsHost.layer.position = .zero

        pagesHost.frame = CGRect(origin: .zero, size: totalSize)
        objectsHost.addSubview(pagesHost)

        annotationsHost.frame = CGRect(origin: .zero, size: totalSize)
        annotationsHost.layer.anchorPoint = .zero
        annotationsHost.layer.position = .zero
        annotationsHost.isUserInteractionEnabled = false

        overlayHost.frame = CGRect(origin: .zero, size: totalSize)
        overlayHost.layer.anchorPoint = .zero
        overlayHost.layer.position = .zero
        overlayHost.isUserInteractionEnabled = false

        selectionLayer.fillColor = nil
        selectionLayer.strokeColor = UIColor(Theme.navy).cgColor
        selectionLayer.lineWidth = 1.5
        selectionLayer.lineDashPattern = [6, 4]

        draftLayer.fillColor = nil

        overlayHost.layer.addSublayer(selectionLayer)
        overlayHost.layer.addSublayer(draftLayer)

        // Both hosts stay under PencilKit's own rendering; only overlayHost
        // (added last) sits above the ink.
        canvasView.insertSubview(objectsHost, at: 0)
        canvasView.insertSubview(annotationsHost, aboveSubview: objectsHost)
        canvasView.addSubview(overlayHost)

        // Object mode gestures
        objectTap = UITapGestureRecognizer(target: self, action: #selector(handleObjectTap(_:)))
        objectTap.delegate = self
        objectTap.isEnabled = false
        canvasView.addGestureRecognizer(objectTap)

        objectPan = UIPanGestureRecognizer(target: self, action: #selector(handleObjectPan(_:)))
        objectPan.maximumNumberOfTouches = 1
        objectPan.isEnabled = false
        canvasView.addGestureRecognizer(objectPan)

        annotationPan = ImmediatePanGestureRecognizer(target: self, action: #selector(handleAnnotationPan(_:)))
        annotationPan.maximumNumberOfTouches = 1
        annotationPan.isEnabled = false
        canvasView.addGestureRecognizer(annotationPan)

        // Freeform eraser: circle strokes to delete them.
        lassoErasePan = ImmediatePanGestureRecognizer(target: self, action: #selector(handleLassoErase(_:)))
        lassoErasePan.maximumNumberOfTouches = 1
        lassoErasePan.isEnabled = false
        canvasView.addGestureRecognizer(lassoErasePan)

        // Hold & drag: select an annotation (with its own writing) or a photo
        // and move it, even while an ink tool is active.
        holdPress = UILongPressGestureRecognizer(target: self, action: #selector(handleHoldPress(_:)))
        holdPress.minimumPressDuration = 0.4
        holdPress.delegate = self
        holdPress.isEnabled = false
        canvasView.addGestureRecognizer(holdPress)

        rebuildPages()
        rebuildElementViews()

        // TEMP DEBUG: triple-tap teleports the viewport 40k pt toward the
        // top-left corner to torture-test infinite growth. REMOVE.
        let debugJump = UITapGestureRecognizer(target: self, action: #selector(debugJumpTowardOrigin))
        debugJump.numberOfTapsRequired = 3
        canvasView.addGestureRecognizer(debugJump)
    }

    // TEMP DEBUG — REMOVE.
    @objc private func debugJumpTowardOrigin() {
        guard config.layout == .infinite else { return }
        NSLog("[notey-dbg] jump: offset=%@ sheet=%@", NSCoder.string(for: canvasView.contentOffset), NSCoder.string(for: infiniteSheet))
        canvasView.setContentOffset(
            CGPoint(
                x: canvasView.contentOffset.x - 40_000 * zoom,
                y: canvasView.contentOffset.y - 40_000 * zoom
            ),
            animated: false
        )
        NSLog("[notey-dbg] after: offset=%@ sheet=%@", NSCoder.string(for: canvasView.contentOffset), NSCoder.string(for: infiniteSheet))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Pages

    private var paperUIColor: UIColor {
        config.paperColorHex.map { UIColor(hexString: $0) } ?? Theme.cardUI
    }

    private func rebuildPages() {
        for card in pageCards { card.removeFromSuperview() }
        pageCards.removeAll()
        patternLayers.removeAll()

        pagesHost.frame = CGRect(origin: .zero, size: totalSize)

        let cardCount = config.layout == .infinite ? 1 : pagesCount
        for index in 0..<cardCount {
            let frame = config.layout == .infinite
                ? CGRect(origin: .zero, size: sheetSize)
                : pageFrame(index)
            let card = UIView(frame: frame)
            card.backgroundColor = paperUIColor
            let decorated = !compact && config.layout == .pages
            card.layer.cornerRadius = decorated ? 18 : 0
            card.layer.borderWidth = decorated ? 1 : 0
            card.layer.borderColor = UIColor(Theme.border).cgColor
            if decorated {
                card.layer.shadowColor = UIColor(Theme.navy).cgColor
                card.layer.shadowOpacity = 0.08
                card.layer.shadowRadius = 14
                card.layer.shadowOffset = CGSize(width: 0, height: 4)
            }
            let pattern = CAShapeLayer()
            pattern.frame = CGRect(origin: .zero, size: frame.size)
            card.layer.addSublayer(pattern)
            patternLayers.append(pattern)
            pagesHost.addSubview(card)
            pageCards.append(card)
        }
        redrawPattern()
        updateGeometry()
    }

    private func pageFrame(_ index: Int) -> CGRect {
        CGRect(
            x: 0,
            y: CGFloat(index) * (page.height + CanvasPage.gap),
            width: page.width,
            height: page.height
        )
    }

    func addPage() {
        guard config.layout == .pages else { return }
        let before = elements
        elements.pages = pagesCount + 1
        rebuildPages()
        commitElementChange(from: before, fromDrawing: canvasView.drawing)
        // Scroll to the fresh page.
        let targetY = (CGFloat(pagesCount - 1) * (page.height + CanvasPage.gap)) * zoom
        canvasView.setContentOffset(
            CGPoint(x: canvasView.contentOffset.x, y: max(-canvasView.contentInset.top, targetY - 40)),
            animated: true
        )
    }

    func removePage() {
        guard config.layout == .pages, pagesCount > 1 else { return }
        let before = elements
        elements.pages = pagesCount - 1
        rebuildPages()
        commitElementChange(from: before, fromDrawing: canvasView.drawing)
        // Keep the viewport inside the shrunken content.
        let maxY = max(-canvasView.contentInset.top, canvasView.contentSize.height - canvasView.bounds.height)
        if canvasView.contentOffset.y > maxY {
            canvasView.setContentOffset(CGPoint(x: canvasView.contentOffset.x, y: maxY), animated: true)
        }
    }

    // MARK: Layout — fit page width, free pinch zoom

    private func updateGeometry(resetZoom: Bool = false) {
        guard bounds.width > 0 else { return }
        fitScale = max(0.2, (bounds.width - horizontalInset * 2) / page.width)
        if compact {
            // Tiny live tiles (calendar) keep a locked fit — no pinch fights
            // with the surrounding scroll views.
            canvasView.minimumZoomScale = fitScale
            canvasView.maximumZoomScale = fitScale
        } else if config.layout == .infinite {
            // Zoom far out for overview, far in to write details. The sheet is
            // effectively endless, so the minimum only frames ~10 pages.
            canvasView.minimumZoomScale = fitScale * 0.1
            canvasView.maximumZoomScale = max(fitScale * 8, 4)
        } else {
            canvasView.minimumZoomScale = fitScale * 0.35
            canvasView.maximumZoomScale = max(fitScale * 8, 4)
        }
        if resetZoom
            || canvasView.zoomScale < canvasView.minimumZoomScale
            || canvasView.zoomScale > canvasView.maximumZoomScale {
            canvasView.zoomScale = fitScale
        }
        canvasView.contentSize = CGSize(width: totalSize.width * zoom, height: totalSize.height * zoom)
        canvasView.contentInset = UIEdgeInsets(
            top: compact ? 4 : 16,
            left: horizontalInset,
            bottom: compact ? 8 : 140,
            right: horizontalInset
        )
        syncOverlay()
    }

    private func syncOverlay() {
        let z = zoom
        let transform = CGAffineTransform(scaleX: z, y: z)
        objectsHost.transform = transform
        annotationsHost.transform = transform
        overlayHost.transform = transform
        // Overlay lines live in page space (they scale with the zoom); keep
        // them visually constant.
        let rel = max(0.05, z / fitScale)
        selectionLayer.lineWidth = 1.5 / rel
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        canvasView.frame = bounds
        guard bounds.width > 0 else { return }
        let newFit = max(0.2, (bounds.width - horizontalInset * 2) / page.width)
        if !didInitialLayout {
            didInitialLayout = true
            updateGeometry(resetZoom: true)
            if config.layout == .infinite {
                centerViewportOnContent()
            } else {
                canvasView.contentOffset = CGPoint(x: -horizontalInset, y: -(compact ? 4 : 16))
            }
        } else if abs(newFit - fitScale) > 0.001 {
            // Rotation / split-view resize: refit, but keep a user zoom level.
            let wasAtFit = abs(canvasView.zoomScale - fitScale) < 0.001
            updateGeometry(resetZoom: wasAtFit)
        }
    }

    // PKCanvasViewDelegate (UIScrollViewDelegate) — keep overlays glued to ink.
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        syncOverlay()
    }

    // Scrolling drives the infinite growth; deferred edge shifts are retried
    // once the gesture settles.
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        ensureRunwayForViewport()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { retryPendingEdgeShift() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        retryPendingEdgeShift()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        retryPendingEdgeShift()
        ensureRunwayForViewport()
    }

    // MARK: Config

    func apply(config: CanvasToolConfig) {
        let previousConfig = self.config
        self.config = config

        switch config.tool {
        case .pen:
            canvasView.tool = PKInkingTool(config.penStyle.inkType, color: config.penColor, width: config.penWidth)
        case .marker:
            canvasView.tool = PKInkingTool(config.markerStyle.inkType, color: config.markerColor, width: config.markerWidth)
        case .eraser:
            switch config.eraserMode {
            case .stroke: canvasView.tool = PKEraserTool(.vector)
            case .point: canvasView.tool = PKEraserTool(.bitmap, width: config.eraserWidth)
            case .lasso: break
            }
        case .lasso:
            canvasView.tool = PKLassoTool()
        case .objects, .annotation:
            break
        }

        updateGestureStates()
        canvasView.drawingPolicy = config.fingerDraws ? .anyInput : .pencilOnly

        if previousConfig.tool != config.tool, config.tool != .objects, config.tool != .annotation {
            selected = nil
        }
        if previousConfig.layout != config.layout {
            // Keep the ink where the layout expects it: centered on a freshly
            // sized sheet (infinite) or tucked into the top-left page (pages).
            if config.layout == .infinite {
                sizeInfiniteSheetForContent()
                recenterInfiniteContent()
            } else {
                normalizeContentToTopLeft()
            }
            rebuildPages()
            updateGeometry(resetZoom: true)
            if config.layout == .infinite, didInitialLayout {
                centerViewportOnContent()
            }
        } else if previousConfig.background != config.background {
            redrawPattern()
        }
        if previousConfig.paperColorHex != config.paperColorHex {
            if config.layout == .infinite {
                redrawPattern()
            } else {
                for card in pageCards { card.backgroundColor = paperUIColor }
            }
        }
    }

    // MARK: Infinite sheet — content placement & unbounded growth

    private func contentBounds() -> CGRect {
        var union: CGRect = .null
        if !canvasView.drawing.strokes.isEmpty { union = union.union(canvasView.drawing.bounds) }
        for image in elements.images { union = union.union(image.frame) }
        for annotation in elements.annotations { union = union.union(annotation.frame) }
        return union
    }

    /// Pattern spacing multiples keep coordinate-space shifts pixel-invisible
    /// (the dot grid lands exactly on itself).
    private func patternAligned(_ value: CGFloat) -> CGFloat {
        ceil(value / 56) * 56
    }

    /// Empty space required between content/viewport and every sheet edge.
    /// Scales with the viewport so even a full-speed fling while zoomed far
    /// out cannot cross it before the next top-up.
    private var requiredRunway: CGFloat {
        guard canvasView.bounds.width > 0 else { return CanvasPage.infiniteRunway }
        return max(CanvasPage.infiniteRunway, canvasView.bounds.width / zoom * 2)
    }

    private func visiblePageRect() -> CGRect {
        CGRect(
            x: canvasView.contentOffset.x / zoom,
            y: canvasView.contentOffset.y / zoom,
            width: canvasView.bounds.width / zoom,
            height: canvasView.bounds.height / zoom
        )
    }

    /// Opening size: the base window plus whatever the content already spans,
    /// so the runway invariant holds from the first frame.
    private func sizeInfiniteSheetForContent() {
        var sheet = CanvasPage.infiniteSize
        let content = contentBounds()
        if !content.isNull {
            sheet.width = patternAligned(sheet.width + content.width)
            sheet.height = patternAligned(sheet.height + content.height)
        }
        infiniteSheet = sheet
    }

    /// Infinite notes reopen with their content centered on a fresh sheet —
    /// this also re-normalizes coordinates after long sessions of growth.
    private func recenterInfiniteContent() {
        let bounds = contentBounds()
        guard !bounds.isNull else { return }
        let dx = (totalSize.width / 2 - bounds.midX).rounded()
        let dy = (totalSize.height / 2 - bounds.midY).rounded()
        // Only shift when the content sits far off-center (fresh migration).
        guard abs(dx) > 2000 || abs(dy) > 2000 else { return }
        shiftContent(dx: dx, dy: dy)
    }

    /// Infinite -> pages: bring the content back to the first page.
    private func normalizeContentToTopLeft() {
        let bounds = contentBounds()
        guard !bounds.isNull else { return }
        guard bounds.minX < 0 || bounds.minY < 0 || bounds.minX > page.width || bounds.minY > page.height else { return }
        shiftContent(dx: (60 - bounds.minX).rounded(), dy: (60 - bounds.minY).rounded())
    }

    /// Rigid shift of the whole coordinate space (drawing + elements). Views
    /// are moved in place; the drawing assignment fires the change delegate,
    /// which persists the new coordinates.
    private func shiftContent(dx: CGFloat, dy: CGFloat) {
        guard dx != 0 || dy != 0 else { return }
        for i in elements.images.indices {
            elements.images[i].frame = elements.images[i].frame.offsetBy(dx: dx, dy: dy)
            imageViews[elements.images[i].id]?.frame = elements.images[i].frame
        }
        for i in elements.annotations.indices {
            elements.annotations[i].frame = elements.annotations[i].frame.offsetBy(dx: dx, dy: dy)
            annotationViews[elements.annotations[i].id]?.frame = elements.annotations[i].frame
        }
        canvasView.drawing = canvasView.drawing.transformed(using: CGAffineTransform(translationX: dx, y: dy))
        refreshSelectionLayer()
    }

    /// The heart of the truly infinite canvas: whenever the viewport or the
    /// ink gets within `requiredRunway` of a sheet edge, the sheet is grown.
    /// Right/bottom growth is a plain size change. Left/top growth shifts the
    /// whole coordinate space by a pattern-aligned delta and moves the scroll
    /// offset with it, so nothing moves on screen — the wall just recedes.
    private func ensureInfiniteRunway(around occupied: CGRect) {
        guard config.layout == .infinite, !compact, didInitialLayout,
              !isAdjustingSheet, !canvasView.isZooming, !occupied.isNull
        else { return }
        let runway = requiredRunway
        let topUp = runway * 1.5
        // Precision safety net: unreachable in practice (reopening a note
        // re-normalizes coordinates), but never grow into Float32 mush.
        let maxSheet: CGFloat = 1_500_000

        var extendX = infiniteSheet.width - occupied.maxX < runway
            ? topUp - (infiniteSheet.width - occupied.maxX) : 0
        var extendY = infiniteSheet.height - occupied.maxY < runway
            ? topUp - (infiniteSheet.height - occupied.maxY) : 0
        var dx = occupied.minX < runway ? patternAligned(topUp - occupied.minX) : 0
        var dy = occupied.minY < runway ? patternAligned(topUp - occupied.minY) : 0
        if infiniteSheet.width + extendX + dx > maxSheet { extendX = 0; dx = 0 }
        if infiniteSheet.height + extendY + dy > maxSheet { extendY = 0; dy = 0 }
        guard extendX > 0 || extendY > 0 || dx > 0 || dy > 0 else { return }

        // A coordinate shift under a wet stroke or an active drag would tear
        // it — grow the cheap sides now, retry the shift when the gesture ends.
        if dx > 0 || dy > 0,
           toolInUse || dragActive || annotationDrafting || !lassoErasePoints.isEmpty {
            pendingEdgeShift = true
            dx = 0
            dy = 0
            guard extendX > 0 || extendY > 0 else { return }
        } else if dx > 0 || dy > 0 {
            pendingEdgeShift = false
        }

        isAdjustingSheet = true
        infiniteSheet.width += extendX + dx
        infiniteSheet.height += extendY + dy
        applySheetGeometry()
        if dx > 0 || dy > 0 {
            shiftContent(dx: dx, dy: dy)
            canvasView.contentOffset = CGPoint(
                x: canvasView.contentOffset.x + dx * zoom,
                y: canvasView.contentOffset.y + dy * zoom
            )
        }
        isAdjustingSheet = false
    }

    /// O(1) check driven by scrolling.
    private func ensureRunwayForViewport() {
        ensureInfiniteRunway(around: visiblePageRect())
    }

    /// Content-aware check after ink/element changes.
    private func ensureRunwayForContent() {
        guard config.layout == .infinite, !compact, didInitialLayout else { return }
        ensureInfiniteRunway(around: contentBounds().union(visiblePageRect()))
    }

    private func retryPendingEdgeShift() {
        guard pendingEdgeShift else { return }
        pendingEdgeShift = false
        ensureRunwayForContent()
    }

    /// Resize the (single) infinite page card and the scrollable area in
    /// place — no rebuild, the tiled pattern just covers the new frame.
    private func applySheetGeometry() {
        guard config.layout == .infinite else { return }
        pagesHost.frame = CGRect(origin: .zero, size: infiniteSheet)
        if let card = pageCards.first {
            card.frame = CGRect(origin: .zero, size: infiniteSheet)
            patternLayers.first?.frame = card.bounds
        }
        canvasView.contentSize = CGSize(
            width: infiniteSheet.width * zoom,
            height: infiniteSheet.height * zoom
        )
    }

    private func centerViewportOnContent() {
        guard bounds.width > 0 else { return }
        let content = contentBounds()
        let target = content.isNull
            ? CGPoint(x: totalSize.width / 2, y: totalSize.height / 2)
            : CGPoint(x: content.midX, y: content.midY)
        let offset = CGPoint(
            x: max(-canvasView.contentInset.left, target.x * zoom - canvasView.bounds.width / 2),
            y: max(-canvasView.contentInset.top, target.y * zoom - canvasView.bounds.height / 2)
        )
        canvasView.contentOffset = offset
    }

    // MARK: Pattern

    private func redrawPattern() {
        // Infinite sheet: a vector path over 120k x 120k would mean millions
        // of segments. A 56pt tiled pattern image renders in O(viewport).
        if config.layout == .infinite {
            for pattern in patternLayers {
                pattern.path = nil
                pattern.fillColor = nil
                pattern.strokeColor = nil
            }
            pageCards.first?.backgroundColor = tiledPatternColor()
            return
        }
        for card in pageCards { card.backgroundColor = paperUIColor }

        let path = UIBezierPath()
        let spacing: CGFloat = 56
        let area = sheetSize
        var isDots = false
        switch config.background {
        case .blank:
            break
        case .dots:
            isDots = true
            var y = spacing
            while y < area.height {
                var x = spacing
                while x < area.width {
                    path.append(UIBezierPath(ovalIn: CGRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3)))
                    x += spacing
                }
                y += spacing
            }
        case .lines, .grid:
            var y = spacing
            while y < area.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: area.width, y: y))
                y += spacing
            }
            if config.background == .grid {
                var x = spacing
                while x < area.width {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: area.height))
                    x += spacing
                }
            }
        }
        for pattern in patternLayers {
            pattern.path = path.cgPath
            pattern.fillColor = isDots ? Theme.patternUI.cgColor : nil
            pattern.strokeColor = isDots ? nil : Theme.patternUI.withAlphaComponent(0.55).cgColor
            pattern.lineWidth = 1
        }
    }

    /// Paper + pattern baked into one repeating 56pt tile (rendered at 4x so
    /// it stays crisp at max zoom).
    private func tiledPatternColor() -> UIColor {
        let spacing: CGFloat = 56
        let format = UIGraphicsImageRendererFormat()
        format.scale = 4
        format.opaque = true
        let tile = UIGraphicsImageRenderer(size: CGSize(width: spacing, height: spacing), format: format)
            .image { ctx in
                paperUIColor.setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: spacing, height: spacing))
                switch config.background {
                case .blank:
                    break
                case .dots:
                    Theme.patternUI.setFill()
                    ctx.cgContext.fillEllipse(in: CGRect(x: spacing / 2 - 1.5, y: spacing / 2 - 1.5, width: 3, height: 3))
                case .lines, .grid:
                    Theme.patternUI.withAlphaComponent(0.55).setFill()
                    ctx.fill(CGRect(x: 0, y: spacing - 1, width: spacing, height: 1))
                    if config.background == .grid {
                        ctx.fill(CGRect(x: spacing - 1, y: 0, width: 1, height: spacing))
                    }
                }
            }
        return UIColor(patternImage: tile)
    }

    // MARK: Element views

    private func rebuildElementViews() {
        for (_, v) in imageViews { v.removeFromSuperview() }
        imageViews.removeAll()
        for (_, v) in annotationViews { v.removeFromSuperview() }
        annotationViews.removeAll()

        for image in elements.images {
            let v = UIImageView(frame: image.frame)
            v.image = UIImage(data: image.imageData)
            v.contentMode = .scaleAspectFill
            v.clipsToBounds = true
            v.layer.cornerRadius = 6
            objectsHost.addSubview(v)
            imageViews[image.id] = v
        }
        for annotation in elements.annotations {
            let card = AnnotationCardView(frame: annotation.frame)
            card.configure(color: UIColor(hexString: annotation.colorHex))
            annotationsHost.addSubview(card)
            annotationViews[annotation.id] = card
        }
        refreshSelectionLayer()
    }

    private func refreshSelectionLayer() {
        guard let selected, let frame = frameOf(selected) else {
            selectionLayer.path = nil
            return
        }
        let path = UIBezierPath(roundedRect: frame.insetBy(dx: -6, dy: -6), cornerRadius: 10)
        if case .image = selected {
            // Resize handle (bottom-right)
            path.append(UIBezierPath(ovalIn: CGRect(x: frame.maxX - 9, y: frame.maxY - 9, width: 18, height: 18)))
        }
        selectionLayer.path = path.cgPath
    }

    private func frameOf(_ element: SelectedElement) -> CGRect? {
        switch element {
        case .image(let id): return elements.images.first { $0.id == id }?.frame
        case .annotation(let id): return elements.annotations.first { $0.id == id }?.frame
        }
    }

    // Annotations sit on top, so they win the hit-test over photos.
    private func elementAt(_ point: CGPoint) -> SelectedElement? {
        if let annotation = annotationAt(point) {
            return .annotation(annotation.id)
        }
        for image in elements.images.reversed() where image.frame.contains(point) {
            return .image(image.id)
        }
        return nil
    }

    private func annotationAt(_ point: CGPoint) -> AnnotationElement? {
        elements.annotations.reversed().first { $0.frame.contains(point) }
    }

    private func pagePoint(from gesture: UIGestureRecognizer) -> CGPoint {
        let p = gesture.location(in: canvasView)
        return CGPoint(x: p.x / zoom, y: p.y / zoom)
    }

    /// Where the touch actually went down, in page coordinates. A pan only
    /// recognizes after ~10pt of movement, so at `.began` its location has
    /// already drifted — hit-testing must use the original touch point or
    /// fast drags slip off the element they started on.
    private func startPagePoint(of gesture: UIPanGestureRecognizer) -> CGPoint {
        let loc = gesture.location(in: canvasView)
        let t = gesture.translation(in: canvasView)
        return CGPoint(x: (loc.x - t.x) / zoom, y: (loc.y - t.y) / zoom)
    }

    // MARK: Annotation ink (attached strokes rendered on the card)

    /// Any stroke that appears for the first time while sitting on top of an
    /// annotation gets fingerprinted into that annotation — and only such
    /// strokes ever belong to it. Sliding the annotation over old writing or
    /// lassoing foreign text onto it never captures anything.
    private func trackNewStrokes(in drawing: PKDrawing) {
        var currentKeys = Set<String>()
        currentKeys.reserveCapacity(drawing.strokes.count)
        for stroke in drawing.strokes {
            let key = stroke.fingerprint
            currentKeys.insert(key)
            guard !knownStrokeKeys.contains(key), !elements.annotations.isEmpty else { continue }
            let center = CGPoint(x: stroke.renderBounds.midX, y: stroke.renderBounds.midY)
            // Topmost annotation under the fresh stroke wins.
            if let idx = elements.annotations.lastIndex(where: { $0.frame.contains(center) }) {
                var keys = elements.annotations[idx].strokeKeys ?? []
                if !keys.contains(key) {
                    keys.append(key)
                    elements.annotations[idx].strokeKeys = keys
                }
            }
        }
        knownStrokeKeys = currentKeys
    }

    /// Strokes attached to an annotation — strictly by fingerprint. Strokes
    /// that were meanwhile moved far away (e.g. with the lasso) are released.
    private func attachedStrokeIndexes(for annotation: AnnotationElement, of drawing: PKDrawing) -> [Int] {
        let keys = Set(annotation.strokeKeys ?? [])
        guard !keys.isEmpty else { return [] }
        let near = annotation.frame.insetBy(dx: -80, dy: -80)
        return drawing.strokes.enumerated().compactMap { index, stroke in
            keys.contains(stroke.fingerprint) && stroke.renderBounds.intersects(near) ? index : nil
        }
    }

    // The cards live under the ink, so writing (wet strokes included) is
    // always fully visible — no layer juggling while the tool is in use.
    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        toolInUse = true
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        toolInUse = false
        retryPendingEdgeShift()
        ensureRunwayForContent()
    }

    // MARK: Shared drag machinery

    private func beginDrag(of element: SelectedElement, resize: Bool) {
        guard let frame = frameOf(element) else { return }
        selected = element
        dragIsResize = resize
        dragActive = true
        dragStrokesHidden = false
        dragOriginalFrame = frame
        dragBaseDrawing = canvasView.drawing
        dragBaseElements = elements
        switch element {
        case .image:
            dragAttachedStrokes = []
        case .annotation(let id):
            if let annotation = elements.annotations.first(where: { $0.id == id }) {
                dragAttachedStrokes = attachedStrokeIndexes(for: annotation, of: dragBaseDrawing)
            } else {
                dragAttachedStrokes = []
            }
            // Bake the attached ink onto the card and take the real strokes
            // off the canvas for the duration of the drag — otherwise they
            // trail behind the card as a lagging double image.
            if !dragAttachedStrokes.isEmpty {
                if let annotation = elements.annotations.first(where: { $0.id == id }) {
                    let attached = dragAttachedStrokes.map { dragBaseDrawing.strokes[$0] }
                    annotationViews[id]?.setInk(
                        PKDrawing(strokes: attached).image(from: annotation.frame, scale: 2)
                    )
                }
                var strokes = dragBaseDrawing.strokes
                for index in dragAttachedStrokes.sorted(by: >) {
                    strokes.remove(at: index)
                }
                dragStrokesHidden = true
                canvasView.drawing = PKDrawing(strokes: strokes)
            }
        }
    }

    private func updateDrag(translation: CGPoint) {
        guard dragActive, let selected else { return }
        let dx = translation.x / zoom
        let dy = translation.y / zoom
        if dragIsResize, case .image = selected {
            let aspect = dragOriginalFrame.height / max(1, dragOriginalFrame.width)
            let w = max(40, dragOriginalFrame.width + dx)
            let newFrame = CGRect(x: dragOriginalFrame.minX, y: dragOriginalFrame.minY, width: w, height: w * aspect)
            setFrame(newFrame, for: selected)
        } else {
            let newFrame = dragOriginalFrame.offsetBy(dx: dx, dy: dy)
            setFrame(newFrame, for: selected)
            if !dragAttachedStrokes.isEmpty, !dragStrokesHidden {
                var strokes = dragBaseDrawing.strokes
                let move = CGAffineTransform(translationX: dx, y: dy)
                for i in dragAttachedStrokes {
                    strokes[i].transform = dragBaseDrawing.strokes[i].transform.concatenating(move)
                }
                canvasView.drawing = PKDrawing(strokes: strokes)
            }
        }
    }

    private func endDrag() {
        guard dragActive else { return }
        // Re-insert the strokes hidden at drag start, shifted by the total
        // drag delta, before committing (so undo captures the full drawing).
        if dragStrokesHidden, let selected, let frame = frameOf(selected) {
            let move = CGAffineTransform(
                translationX: frame.minX - dragOriginalFrame.minX,
                y: frame.minY - dragOriginalFrame.minY
            )
            var strokes = dragBaseDrawing.strokes
            for i in dragAttachedStrokes {
                strokes[i].transform = dragBaseDrawing.strokes[i].transform.concatenating(move)
            }
            canvasView.drawing = PKDrawing(strokes: strokes)
        }
        dragStrokesHidden = false
        dragActive = false
        commitElementChange(from: dragBaseElements, fromDrawing: dragBaseDrawing)
        // The real strokes are back on the canvas — drop the baked drag image.
        for card in annotationViews.values { card.setInk(nil) }
        retryPendingEdgeShift()
        ensureRunwayForContent()
    }

    /// Strokes whose render-bounds center lies inside the rect (images grab
    /// everything written on them).
    private func strokeIndexesCentered(in rect: CGRect, of drawing: PKDrawing) -> [Int] {
        drawing.strokes.enumerated().compactMap { index, stroke in
            let c = CGPoint(x: stroke.renderBounds.midX, y: stroke.renderBounds.midY)
            return rect.contains(c) ? index : nil
        }
    }

    private func updateGestureStates() {
        var inkMode = [EditorTool.pen, .marker, .eraser, .lasso].contains(config.tool)
        if config.tool == .eraser, config.eraserMode == .lasso { inkMode = false }
        canvasView.drawingGestureRecognizer.isEnabled = inkMode
        
        let allowTap = config.tool == .objects || config.tool == .annotation || selected != nil
        objectTap.isEnabled = allowTap
        
        objectPan.isEnabled = config.tool == .objects
        annotationPan.isEnabled = config.tool == .annotation
        lassoErasePan.isEnabled = config.tool == .eraser && config.eraserMode == .lasso
        holdPress.isEnabled = [EditorTool.pen, .marker].contains(config.tool)
        
        if selected != nil {
            canvasView.drawingPolicy = .pencilOnly
        } else {
            canvasView.drawingPolicy = config.fingerDraws ? .anyInput : .pencilOnly
        }
        
        canvasView.allowEditMenu = (config.tool == .lasso)
        
        canvasView.forceAppleTapsToWait(for: objectTap, ignoring: [objectsHost, annotationsHost])
    }

    // MARK: Object mode gestures

    @objc private func handleObjectTap(_ gesture: UITapGestureRecognizer) {
        let pt = pagePoint(from: gesture)
        
        if [EditorTool.pen, .marker, .eraser, .lasso].contains(config.tool) {
            if elementAt(pt) != selected {
                selected = nil
                canvasView.endEditing(true)
            }
            return
        }
        
        if config.tool == .annotation {
            selected = annotationAt(pt).map { .annotation($0.id) }
        } else {
            selected = elementAt(pt)
        }
    }

    @objc private func handleObjectPan(_ gesture: UIPanGestureRecognizer) {
        let pt = startPagePoint(of: gesture)
        switch gesture.state {
        case .began:
            // Grab the resize handle of a selected image first.
            if case .image(let id)? = selected,
               let frame = frameOf(.image(id)),
               hypot(pt.x - frame.maxX, pt.y - frame.maxY) < 28 {
                beginDrag(of: .image(id), resize: true)
                return
            }
            if let hit = elementAt(pt) {
                beginDrag(of: hit, resize: false)
            } else {
                selected = nil
                gesture.isEnabled = false
                gesture.isEnabled = true
            }
        case .changed:
            updateDrag(translation: gesture.translation(in: canvasView))
        case .ended, .cancelled, .failed:
            endDrag()
        default:
            break
        }
    }

    // Hold: select an annotation together with the writing that belongs to it
    // (or a photo), then drag to move both as one piece.
    @objc private func handleHoldPress(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            let pt = pagePoint(from: gesture)
            guard let hit = elementAt(pt) else { return }
            // Cancel any ink the touch already started.
            let drawingWasEnabled = canvasView.drawingGestureRecognizer.isEnabled
            canvasView.drawingGestureRecognizer.isEnabled = false
            canvasView.drawingGestureRecognizer.isEnabled = drawingWasEnabled
            holdStartLocation = gesture.location(in: canvasView)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            beginDrag(of: hit, resize: false)
        case .changed:
            guard dragActive else { return }
            let loc = gesture.location(in: canvasView)
            updateDrag(translation: CGPoint(x: loc.x - holdStartLocation.x, y: loc.y - holdStartLocation.y))
        case .ended, .cancelled, .failed:
            endDrag()
        default:
            break
        }
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === holdPress {
            let p = gestureRecognizer.location(in: canvasView)
            return elementAt(CGPoint(x: p.x / zoom, y: p.y / zoom)) != nil
        }
        if gestureRecognizer === objectTap {
            if [EditorTool.pen, .marker, .eraser, .lasso].contains(config.tool) {
                let p = gestureRecognizer.location(in: canvasView)
                let pt = CGPoint(x: p.x / zoom, y: p.y / zoom)
                return elementAt(pt) != selected
            }
        }
        return true
    }
    
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, canPrevent otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === objectTap {
            if otherGestureRecognizer is ImmediatePanGestureRecognizer {
                return false
            }
            return true
        }
        return false
    }
    
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === objectTap || otherGestureRecognizer === objectTap {
            return true
        }
        return false
    }

    // Annotation tool: drag on empty space draws a new annotation; drag that
    // starts on an existing annotation MOVES it (with its own writing).
    @objc private func handleAnnotationPan(_ gesture: UIPanGestureRecognizer) {
        let pt = pagePoint(from: gesture)
        switch gesture.state {
        case .began:
            let startPt = startPagePoint(of: gesture)
            if let annotation = annotationAt(startPt) {
                annotationDrafting = false
                beginDrag(of: .annotation(annotation.id), resize: false)
            } else {
                annotationDrafting = true
                annotationStart = startPt
            }
        case .changed:
            if annotationDrafting {
                let rect = normalizedRect(annotationStart, pt)
                draftLayer.path = UIBezierPath(roundedRect: rect, cornerRadius: 10).cgPath
                draftLayer.fillColor = config.annotationColor.withAlphaComponent(0.6).cgColor
                draftLayer.strokeColor = nil
            } else {
                updateDrag(translation: gesture.translation(in: canvasView))
            }
        case .ended:
            if annotationDrafting {
                annotationDrafting = false
                draftLayer.path = nil
                let rect = normalizedRect(annotationStart, pt)
                guard rect.width > 12, rect.height > 12 else { return }
                let before = elements
                var annotation = AnnotationElement(
                    x: 0, y: 0, w: 0, h: 0,
                    colorHex: config.annotationColor.hexString,
                    createdAt: Date().timeIntervalSince1970,
                    strokeKeys: []
                )
                annotation.frame = rect
                elements.annotations.append(annotation)
                rebuildElementViews()
                selected = .annotation(annotation.id)
                commitElementChange(from: before, fromDrawing: canvasView.drawing)
            } else {
                endDrag()
            }
        case .cancelled, .failed:
            annotationDrafting = false
            draftLayer.path = nil
            endDrag()
        default:
            break
        }
    }

    // Freeform (lasso) eraser: encircle strokes, lift to delete them.
    @objc private func handleLassoErase(_ gesture: UIPanGestureRecognizer) {
        let pt = pagePoint(from: gesture)
        switch gesture.state {
        case .began:
            lassoErasePoints = [startPagePoint(of: gesture), pt]
        case .changed:
            lassoErasePoints.append(pt)
            let path = UIBezierPath()
            path.move(to: lassoErasePoints[0])
            for p in lassoErasePoints.dropFirst() { path.addLine(to: p) }
            draftLayer.path = path.cgPath
            draftLayer.fillColor = UIColor(Theme.pink).withAlphaComponent(0.10).cgColor
            draftLayer.strokeColor = UIColor(Theme.pink).cgColor
            draftLayer.lineWidth = 2 / max(0.05, zoom / fitScale)
            draftLayer.lineDashPattern = [6, 4]
        case .ended:
            defer {
                draftLayer.path = nil
                draftLayer.strokeColor = nil
                draftLayer.lineDashPattern = nil
                lassoErasePoints = []
            }
            guard lassoErasePoints.count >= 3 else { return }
            let polygon = UIBezierPath()
            polygon.move(to: lassoErasePoints[0])
            for p in lassoErasePoints.dropFirst() { polygon.addLine(to: p) }
            polygon.close()
            let before = canvasView.drawing
            let kept = before.strokes.filter { stroke in
                let c = CGPoint(x: stroke.renderBounds.midX, y: stroke.renderBounds.midY)
                return !polygon.contains(c)
            }
            guard kept.count != before.strokes.count else { return }
            canvasView.drawing = PKDrawing(strokes: kept)
            commitElementChange(from: elements, fromDrawing: before)
        case .cancelled, .failed:
            draftLayer.path = nil
            draftLayer.strokeColor = nil
            draftLayer.lineDashPattern = nil
            lassoErasePoints = []
        default:
            break
        }
    }

    private func normalizedRect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        )
    }

    private func setFrame(_ frame: CGRect, for element: SelectedElement) {
        switch element {
        case .image(let id):
            if let i = elements.images.firstIndex(where: { $0.id == id }) {
                elements.images[i].frame = frame
                imageViews[id]?.frame = frame
            }
        case .annotation(let id):
            if let i = elements.annotations.firstIndex(where: { $0.id == id }) {
                elements.annotations[i].frame = frame
                annotationViews[id]?.frame = frame
            }
        }
        refreshSelectionLayer()
    }

    // MARK: Commands

    func addImage(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.85) ?? image.pngData() else { return }
        let maxDim: CGFloat = 480
        let scale = min(1, maxDim / max(image.size.width, image.size.height))
        let w = image.size.width * scale
        let h = image.size.height * scale
        // Center of the visible viewport, in page coordinates.
        let visibleCenter = CGPoint(
            x: (canvasView.contentOffset.x + canvasView.bounds.width / 2) / zoom,
            y: (canvasView.contentOffset.y + canvasView.bounds.height / 2) / zoom
        )
        var element = ImageElement(x: 0, y: 0, w: 0, h: 0, imageData: data)
        element.frame = CGRect(
            x: min(max(20, visibleCenter.x - w / 2), totalSize.width - w - 20),
            y: min(max(20, visibleCenter.y - h / 2), totalSize.height - h - 20),
            width: w,
            height: h
        )
        let before = elements
        elements.images.append(element)
        rebuildElementViews()
        selected = .image(element.id)
        commitElementChange(from: before, fromDrawing: canvasView.drawing)
    }

    /// Paste foreign ink (quick note) centered on the drop point, or on the
    /// visible viewport when no point is given.
    func pasteDrawing(_ drawing: PKDrawing, atViewPoint point: CGPoint?) {
        guard !drawing.strokes.isEmpty else { return }
        let target: CGPoint
        if let point {
            let inCanvas = canvasView.convert(point, from: self)
            target = CGPoint(x: inCanvas.x / zoom, y: inCanvas.y / zoom)
        } else {
            target = CGPoint(
                x: (canvasView.contentOffset.x + canvasView.bounds.width / 2) / zoom,
                y: (canvasView.contentOffset.y + canvasView.bounds.height / 2) / zoom
            )
        }
        let bounds = drawing.bounds
        let before = canvasView.drawing
        let moved = drawing.transformed(
            using: CGAffineTransform(translationX: target.x - bounds.midX, y: target.y - bounds.midY)
        )
        canvasView.drawing = before.appending(moved)
        commitElementChange(from: elements, fromDrawing: before)
        ensureRunwayForContent()
    }

    func deleteSelectedElement() {
        guard let selected else { return }
        let before = elements
        switch selected {
        case .image(let id): elements.images.removeAll { $0.id == id }
        case .annotation(let id): elements.annotations.removeAll { $0.id == id }
        }
        self.selected = nil
        rebuildElementViews()
        commitElementChange(from: before, fromDrawing: canvasView.drawing)
    }

    func clearAll() {
        let beforeElements = elements
        let beforeDrawing = canvasView.drawing
        elements.images = []
        elements.annotations = []
        canvasView.drawing = PKDrawing()
        selected = nil
        rebuildElementViews()
        commitElementChange(from: beforeElements, fromDrawing: beforeDrawing)
    }

    // MARK: Undo + change propagation

    private func commitElementChange(from beforeElements: CanvasElements, fromDrawing beforeDrawing: PKDrawing) {
        let afterElements = elements
        let afterDrawing = canvasView.drawing
        guard beforeElements != afterElements || beforeDrawing.dataRepresentation() != afterDrawing.dataRepresentation() else {
            return
        }
        undoManagerForCanvas?.registerUndo(withTarget: self) { target in
            target.restore(elements: beforeElements, drawing: beforeDrawing)
            target.undoManagerForCanvas?.registerUndo(withTarget: target) { redoTarget in
                redoTarget.restore(elements: afterElements, drawing: afterDrawing)
            }
        }
        onChange?(afterDrawing, afterElements)
    }

    private func restore(elements: CanvasElements, drawing: PKDrawing) {
        self.elements = elements
        canvasView.drawing = drawing
        selected = nil
        rebuildPages()
        rebuildElementViews()
        onChange?(drawing, elements)
        // Undo may bring back content recorded before an edge shift.
        ensureRunwayForContent()
    }

    // PKCanvasViewDelegate
    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        let drawing = canvasView.drawing
        trackNewStrokes(in: drawing)
        // Mid-drag frames are transient (annotation drags even hide their
        // attached strokes) — don't persist them; endDrag commits the final
        // state once.
        guard !dragActive else { return }
        onChange?(drawing, elements)
        if !toolInUse {
            ensureRunwayForContent()
        }
    }

    // MARK: PDF export (all stacked pages of this note)

    func exportPDF(title: String) -> URL? {
        NoteExporter.exportPDF(
            pages: [(
                drawing: canvasView.drawing,
                elements: elements,
                paperHex: config.paperColorHex,
                layout: config.layout
            )],
            title: title
        )
    }
}

extension UIView {
    func forceAppleTapsToWait(for objectTap: UITapGestureRecognizer, ignoring: [UIView]) {
        for gesture in gestureRecognizers ?? [] {
            if gesture === objectTap { continue }
            if gesture is UITapGestureRecognizer || String(describing: type(of: gesture)).contains("Tap") {
                gesture.require(toFail: objectTap)
            }
        }
        for subview in subviews {
            if ignoring.contains(where: { $0 === subview }) { continue }
            subview.forceAppleTapsToWait(for: objectTap, ignoring: ignoring)
        }
    }
}
