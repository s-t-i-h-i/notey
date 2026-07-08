import UIKit
import SwiftUI
import PencilKit

// MARK: - Tool model

// Minimal ink tool for the compact calendar tiles, which have no PKToolPicker
// (42 live canvases would share one floating picker — pointless). The full
// editor gets the native picker instead and ignores these fields.
enum CompactTool: String, Equatable, CaseIterable, Identifiable {
    case pen, marker, eraser

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .pen: return "pencil.tip"
        case .marker: return "highlighter"
        case .eraser: return "eraser"
        }
    }
}

struct CanvasToolConfig: Equatable {
    // Page appearance — used by every canvas (editor, calendar, thumbnails).
    var background: CanvasBackground = .dots
    var paperColorHex: String?
    var layout: NoteLayout = .pages
    var orientation: PageOrientation = .portrait
    var template: PageTemplate = .none
    // Cheap change token for the custom template image (its byte count). The
    // image itself is delivered separately (DrawingCanvas.customTemplateImage)
    // so it stays out of the per-update Equatable comparison.
    var customTemplateKey: String?

    // Compact ink — used ONLY by compact calendar tiles (no tool picker there).
    // The full editor owns its tool through the native PKToolPicker.
    var compactTool: CompactTool = .pen
    var inkColor: UIColor = Theme.inkColors[0]
    var inkWidth: CGFloat = 3
}

enum SelectedElement: Equatable {
    case image(UUID)
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
    // Show the native floating PencilKit toolbar (PKToolPicker). Off for the
    // compact calendar tiles; on for the full editor and the day editor.
    var showsToolPicker: Bool = false
    // Auto-straighten hand-drawn shapes ("draw and hold" → ideal shape).
    var shapeDetection: Bool = true
    // Decoded custom template image (kept out of `config` so its bytes don't
    // enter the per-update Equatable check — change is tracked via config.customTemplateKey).
    var customTemplateImage: UIImage? = nil
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
        container.customTemplateImage = customTemplateImage
        container.shapeDetectionEnabled = shapeDetection
        container.apply(config: config)
        container.setToolPickerVisible(showsToolPicker)
        proxy.container = container
        return container
    }

    func updateUIView(_ container: CanvasContainer, context: Context) {
        container.onChange = onChange
        container.onSelection = onSelection
        container.customTemplateImage = customTemplateImage
        container.shapeDetectionEnabled = shapeDetection
        container.apply(config: config)
        container.setToolPickerVisible(showsToolPicker)
        proxy.container = container
    }
}

// The selection outline is a standalone CAShapeLayer without a backing view,
// so every property change would get the implicit 0.25s CATransaction
// animation — the outline visibly trails behind the finger. No actions = it
// tracks 1:1.
private final class ImmediateShapeLayer: CAShapeLayer {
    override func action(forKey event: String) -> CAAction? { nil }
}

// MARK: - Container view (pages + pattern + photos + PencilKit ink)

// Z-order, bottom to top:
//   1. page cards + background pattern
//   2. photos
//   3. handwriting (PencilKit)
//   4. selection outline (overlayHost, photos only)

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
    private let overlayHost = UIView()      // above the ink: selection outline
    private let pagesHost = UIView()
    private var pageCards: [UIView] = []
    private var patternLayers: [CAShapeLayer] = []
    private var templateLayers: [CALayer] = []
    // Delivered by DrawingCanvas; used to render the .custom page template.
    var customTemplateImage: UIImage?
    private let selectionLayer = ImmediateShapeLayer()

    private(set) var elements: CanvasElements
    private var config = CanvasToolConfig()
    private var imageViews: [UUID: UIView] = [:]
    private let compact: Bool

    var onChange: ((PKDrawing, CanvasElements) -> Void)?
    var onSelection: ((SelectedElement?) -> Void)?

    private(set) var selected: SelectedElement? {
        didSet { refreshSelectionLayer(); onSelection?(selected); updateGestureStates() }
    }

    // Logical page size — landscape swaps the axes (pages layout only; the
    // infinite sheet is always axis-neutral).
    private var page: CGSize {
        config.layout == .pages ? CanvasPage.size(for: config.orientation) : CanvasPage.size
    }
    private var pagesCount: Int { max(1, elements.pages ?? 1) }
    // Infinite layout: the sheet is a growing window, not a fixed size. It is
    // extended whenever the viewport or the ink nears an edge, so the canvas
    // never ends in any direction.
    private var infiniteSheet: CGSize = CanvasPage.infiniteSize
    private var sheetSize: CGSize {
        config.layout == .infinite ? infiniteSheet : page
    }
    private var totalSize: CGSize {
        config.layout == .infinite
            ? infiniteSheet
            : CanvasPage.totalSize(pages: pagesCount, orientation: config.orientation)
    }
    // Left/top growth must move the whole coordinate space — deferred while
    // ink or a drag is mid-flight, retried from the matching "did end" hooks.
    private var toolInUse = false
    private var pendingEdgeShift = false
    private var isAdjustingSheet = false
    private var fitScale: CGFloat = 1
    private var didInitialLayout = false
    // Compact tiles fit the whole page edge-to-edge (no inset) so the thumbnail
    // keeps the exact page proportions.
    private var horizontalInset: CGFloat { compact ? 0 : 16 }

    /// Live zoom factor (page points -> screen points).
    private var zoom: CGFloat { max(0.01, canvasView.zoomScale) }

    // Photo manipulation gestures — finger-only, so the Pencil always draws
    // (write on top of a photo) while a finger tap/drag selects and moves it.
    private var objectPan: UIPanGestureRecognizer!
    private var objectTap: UITapGestureRecognizer!
    private var holdPress: UILongPressGestureRecognizer!
    private var dragOriginalFrame: CGRect = .zero
    private var dragBaseDrawing = PKDrawing()
    private var dragBaseElements = CanvasElements()
    private var dragIsResize = false
    private var dragActive = false
    private var holdStartLocation: CGPoint = .zero

    // Native floating toolbar (Apple Notes-style). Created lazily; shown only
    // for the full editor and the day editor — never the compact tiles.
    private lazy var toolPicker = PKToolPicker()
    private var toolPickerVisible = false

    // Shape straightening ("draw and hold" → ideal shape); full editor only.
    private var shapeSnapper: ShapeSnapper?
    var shapeDetectionEnabled = true {
        didSet { shapeSnapper?.isEnabled = shapeDetectionEnabled && !compact }
    }
    // Stroke count when the current tool interaction began — tells a fresh ink
    // stroke (a snap candidate) apart from an erase or a lasso move.
    private var strokeCountAtToolBegin = 0

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
        canvasView.delegate = self
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.alwaysBounceVertical = !compact
        canvasView.contentInsetAdjustmentBehavior = .never
        // Compact tiles never scroll: the whole page is fit into the tile, and
        // one-finger drags belong to the surrounding month grid, not the tile.
        canvasView.isScrollEnabled = !compact
        // Pencil-only writing: only the Pencil draws (drawingPolicy = .pencilOnly).
        // Two fingers scroll, pinch zooms; a single finger never marks the page.
        canvasView.panGestureRecognizer.minimumNumberOfTouches = 2
        // Trackpad / mouse wheel pans too (touch pans still need two fingers).
        canvasView.panGestureRecognizer.allowedScrollTypesMask = .all
        addSubview(canvasView)

        objectsHost.frame = CGRect(origin: .zero, size: totalSize)
        objectsHost.layer.anchorPoint = .zero
        objectsHost.layer.position = .zero

        pagesHost.frame = CGRect(origin: .zero, size: totalSize)
        objectsHost.addSubview(pagesHost)

        overlayHost.frame = CGRect(origin: .zero, size: totalSize)
        overlayHost.layer.anchorPoint = .zero
        overlayHost.layer.position = .zero
        overlayHost.isUserInteractionEnabled = false

        selectionLayer.fillColor = nil
        selectionLayer.strokeColor = UIColor(Theme.navy).cgColor
        selectionLayer.lineWidth = 1.5
        selectionLayer.lineDashPattern = [6, 4]

        overlayHost.layer.addSublayer(selectionLayer)

        // objectsHost stays under PencilKit's own rendering; overlayHost
        // (added last) sits above the ink.
        canvasView.insertSubview(objectsHost, at: 0)
        canvasView.addSubview(overlayHost)

        // Photo gestures — all finger-only (the Pencil is reserved for ink and
        // shape-holding). They select / move / resize photos and coexist with
        // PencilKit's own drawing and two-finger scroll.
        let fingerOnly = [NSNumber(value: UITouch.TouchType.direct.rawValue)]

        objectTap = UITapGestureRecognizer(target: self, action: #selector(handleObjectTap(_:)))
        objectTap.delegate = self
        objectTap.allowedTouchTypes = fingerOnly
        canvasView.addGestureRecognizer(objectTap)

        objectPan = UIPanGestureRecognizer(target: self, action: #selector(handleObjectPan(_:)))
        objectPan.delegate = self
        objectPan.maximumNumberOfTouches = 1
        objectPan.allowedTouchTypes = fingerOnly
        canvasView.addGestureRecognizer(objectPan)

        // Hold & drag a photo (finger), even while an ink tool is active.
        holdPress = UILongPressGestureRecognizer(target: self, action: #selector(handleHoldPress(_:)))
        holdPress.minimumPressDuration = 0.4
        holdPress.delegate = self
        holdPress.allowedTouchTypes = fingerOnly
        canvasView.addGestureRecognizer(holdPress)

        // Shape straightening rides on top of PencilKit (Pencil-only); compact
        // tiles never snap.
        if !compact {
            let snapper = ShapeSnapper(canvasView: canvasView)
            snapper.isEnabled = shapeDetectionEnabled
            snapper.onSnap = { [weak self] before in
                guard let self else { return }
                self.commitElementChange(from: self.elements, fromDrawing: before)
                self.ensureRunwayForContent()
            }
            shapeSnapper = snapper
        }

        rebuildPages()
        rebuildElementViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Native tool picker (PKToolPicker — the Apple Notes floating toolbar)

    /// Show/hide the shared floating PencilKit toolbar for this canvas. The
    /// picker only appears once the canvas is in a window and first responder.
    func setToolPickerVisible(_ visible: Bool) {
        guard visible != toolPickerVisible else { return }
        toolPickerVisible = visible
        applyToolPickerVisibility()
    }

    private func applyToolPickerVisibility() {
        guard !compact, window != nil else { return }
        if toolPickerVisible {
            // Adding the canvas as an observer wires its active `tool` to the
            // picker's selection automatically (native behavior).
            toolPicker.addObserver(canvasView)
            toolPicker.setVisible(true, forFirstResponder: canvasView)
            canvasView.becomeFirstResponder()
        } else {
            toolPicker.setVisible(false, forFirstResponder: canvasView)
            toolPicker.removeObserver(canvasView)
            canvasView.resignFirstResponder()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // First responder + picker can only attach once we're in a window.
        if window != nil { applyToolPickerVisibility() }
    }

    // MARK: Pages

    private var paperUIColor: UIColor {
        config.paperColorHex.map { UIColor(hexString: $0) } ?? Theme.cardUI
    }

    private func rebuildPages() {
        for card in pageCards { card.removeFromSuperview() }
        pageCards.removeAll()
        patternLayers.removeAll()
        templateLayers.removeAll()

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
            // Decorative template sits above the ruling pattern, still under
            // the ink (all card layers are below PencilKit's rendering).
            let template = CALayer()
            template.frame = CGRect(origin: .zero, size: frame.size)
            template.contentsGravity = .resizeAspect
            template.masksToBounds = true
            template.cornerRadius = card.layer.cornerRadius
            card.layer.addSublayer(template)
            templateLayers.append(template)
            pagesHost.addSubview(card)
            pageCards.append(card)
        }
        redrawPattern()
        redrawTemplate()
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
            top: compact ? 0 : 16,
            left: horizontalInset,
            bottom: compact ? 0 : 140,
            right: horizontalInset
        )
        syncOverlay()
    }

    private func syncOverlay() {
        let z = zoom
        let transform = CGAffineTransform(scaleX: z, y: z)
        objectsHost.transform = transform
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
                canvasView.contentOffset = CGPoint(x: -horizontalInset, y: -(compact ? 0 : 16))
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

        // Compact tiles have no PKToolPicker, so they set their ink here from
        // the shared config. The full editor's tool is owned by the picker.
        if compact {
            switch config.compactTool {
            case .pen:
                canvasView.tool = PKInkingTool(.pen, color: config.inkColor, width: config.inkWidth)
            case .marker:
                canvasView.tool = PKInkingTool(.marker, color: config.inkColor, width: config.inkWidth * 5)
            case .eraser:
                canvasView.tool = PKEraserTool(.vector)
            }
        }

        updateGestureStates()
        canvasView.drawingPolicy = .pencilOnly

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
        } else if previousConfig.orientation != config.orientation {
            // Portrait <-> landscape: the page changes size, so rebuild cards
            // and refit. Content keeps its page coordinates.
            rebuildPages()
            updateGeometry(resetZoom: true)
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
        // Template redraw (a full rebuild above already refreshed it).
        let rebuilt = previousConfig.layout != config.layout || previousConfig.orientation != config.orientation
        if !rebuilt,
           previousConfig.template != config.template
            || previousConfig.customTemplateKey != config.customTemplateKey {
            redrawTemplate()
        }
    }

    // MARK: Infinite sheet — content placement & unbounded growth

    private func contentBounds() -> CGRect {
        var union: CGRect = .null
        if !canvasView.drawing.strokes.isEmpty { union = union.union(canvasView.drawing.bounds) }
        for image in elements.images { union = union.union(image.frame) }
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
           toolInUse || dragActive {
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

    // MARK: Template (decorative page background)

    private func redrawTemplate() {
        // Templates decorate real kartka pages only.
        let image: UIImage? = (config.layout == .pages && !compact)
            ? PageTemplateRenderer.image(for: config.template, pageSize: page, custom: customTemplateImage)
            : nil
        let contents = image?.cgImage
        for layer in templateLayers {
            layer.contents = contents
        }
    }

    // MARK: Element views

    private func rebuildElementViews() {
        for (_, v) in imageViews { v.removeFromSuperview() }
        imageViews.removeAll()

        for image in elements.images {
            let v = UIImageView(frame: image.frame)
            v.image = UIImage(data: image.imageData)
            v.contentMode = .scaleAspectFill
            v.clipsToBounds = true
            v.layer.cornerRadius = 6
            objectsHost.addSubview(v)
            imageViews[image.id] = v
        }
        refreshSelectionLayer()
    }

    private func refreshSelectionLayer() {
        guard let selected, let frame = frameOf(selected) else {
            selectionLayer.path = nil
            return
        }
        let path = UIBezierPath(roundedRect: frame.insetBy(dx: -6, dy: -6), cornerRadius: 10)
        // Resize handle (bottom-right).
        path.append(UIBezierPath(ovalIn: CGRect(x: frame.maxX - 9, y: frame.maxY - 9, width: 18, height: 18)))
        selectionLayer.path = path.cgPath
    }

    private func frameOf(_ element: SelectedElement) -> CGRect? {
        switch element {
        case .image(let id): return elements.images.first { $0.id == id }?.frame
        }
    }

    private func elementAt(_ point: CGPoint) -> SelectedElement? {
        for image in elements.images.reversed() where image.frame.contains(point) {
            return .image(image.id)
        }
        return nil
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

    // The Pencil started a stroke: remember the stroke count so we can tell a
    // fresh ink stroke (a shape-snap candidate) from an erase when it ends.
    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        toolInUse = true
        strokeCountAtToolBegin = canvasView.drawing.strokes.count
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        toolInUse = false
        // Straighten the just-finished stroke if the Pencil was held still at
        // its end and exactly one ink stroke was added (not an erase/lasso).
        if canvasView.tool is PKInkingTool,
           canvasView.drawing.strokes.count == strokeCountAtToolBegin + 1 {
            shapeSnapper?.inkStrokeDidEnd()
        }
        retryPendingEdgeShift()
        ensureRunwayForContent()
    }

    // MARK: Photo drag machinery

    private func beginDrag(of element: SelectedElement, resize: Bool) {
        guard let frame = frameOf(element) else { return }
        selected = element
        dragIsResize = resize
        dragActive = true
        dragOriginalFrame = frame
        dragBaseDrawing = canvasView.drawing
        dragBaseElements = elements
    }

    private func updateDrag(translation: CGPoint) {
        guard dragActive, let selected else { return }
        let dx = translation.x / zoom
        let dy = translation.y / zoom
        if dragIsResize {
            let aspect = dragOriginalFrame.height / max(1, dragOriginalFrame.width)
            let w = max(40, dragOriginalFrame.width + dx)
            let newFrame = CGRect(x: dragOriginalFrame.minX, y: dragOriginalFrame.minY, width: w, height: w * aspect)
            setFrame(newFrame, for: selected)
        } else {
            setFrame(dragOriginalFrame.offsetBy(dx: dx, dy: dy), for: selected)
        }
    }

    private func endDrag() {
        guard dragActive else { return }
        dragActive = false
        commitElementChange(from: dragBaseElements, fromDrawing: dragBaseDrawing)
        retryPendingEdgeShift()
        ensureRunwayForContent()
    }

    private func updateGestureStates() {
        // Photo gestures stay finger-only and always on; the Pencil owns ink
        // through PencilKit. Compact tiles set their own tool in apply().
        canvasView.drawingPolicy = .pencilOnly
        // Let PencilKit's native lasso selection show its edit menu.
        canvasView.allowEditMenu = true
    }

    // MARK: Photo gestures (finger-only)

    @objc private func handleObjectTap(_ gesture: UITapGestureRecognizer) {
        selected = elementAt(pagePoint(from: gesture))
    }

    @objc private func handleObjectPan(_ gesture: UIPanGestureRecognizer) {
        let pt = startPagePoint(of: gesture)
        switch gesture.state {
        case .began:
            // Grab the resize handle of a selected photo first.
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
            }
        case .changed:
            updateDrag(translation: gesture.translation(in: canvasView))
        case .ended, .cancelled, .failed:
            endDrag()
        default:
            break
        }
    }

    // Hold a photo with a finger to pick it up and move it — works even while
    // an ink tool is active, because the Pencil keeps drawing.
    @objc private func handleHoldPress(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            guard let hit = elementAt(pagePoint(from: gesture)) else { return }
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

    // holdPress and objectPan only engage when the touch starts on a photo, so
    // empty-space finger touches fall through to PencilKit / two-finger scroll.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if let pan = gestureRecognizer as? UIPanGestureRecognizer, pan === objectPan {
            return elementAt(startPagePoint(of: pan)) != nil
        }
        if gestureRecognizer === holdPress {
            let p = gestureRecognizer.location(in: canvasView)
            return elementAt(CGPoint(x: p.x / zoom, y: p.y / zoom)) != nil
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // The finger-only photo recognizers coexist with each other and with
        // PencilKit's own drawing / scroll / zoom gestures.
        true
    }

    private func setFrame(_ frame: CGRect, for element: SelectedElement) {
        switch element {
        case .image(let id):
            if let i = elements.images.firstIndex(where: { $0.id == id }) {
                elements.images[i].frame = frame
                imageViews[id]?.frame = frame
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
        }
        self.selected = nil
        rebuildElementViews()
        commitElementChange(from: before, fromDrawing: canvasView.drawing)
    }

    func clearAll() {
        let beforeElements = elements
        let beforeDrawing = canvasView.drawing
        elements.images = []
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
        // Mid-drag frames are transient — don't persist them; endDrag commits
        // the final state once.
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
                layout: config.layout,
                orientation: config.orientation,
                template: config.template,
                customImage: customTemplateImage
            )],
            title: title
        )
    }
}
