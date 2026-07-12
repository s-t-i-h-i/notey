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
    // Developer mode: fingers/pointer draw (Simulator testing). Editor only.
    var devFingerDrawing: Bool = false
    // Decoded custom template image (kept out of `config` so its bytes don't
    // enter the per-update Equatable check — change is tracked via config.customTemplateKey).
    var customTemplateImage: UIImage? = nil
    var toolbarSettings = ToolbarSettings()
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
        container.devFingerDrawing = devFingerDrawing
        container.toolbarSettings = toolbarSettings
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
        container.devFingerDrawing = devFingerDrawing
        container.toolbarSettings = toolbarSettings
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

// MARK: - Page ruling (dots / lines / grid) on a tiled layer

// A fixed-resolution pattern layer shimmers and aliases while the canvas is
// pinch-zoomed (subpixel dots strobe) and blurs at rest when zoomed in. A
// CATiledLayer — the native mechanism behind PDF/map zooming — re-renders the
// ruling vector-crisp per zoom level on background threads, for the fixed
// page cards and the enormous infinite sheet alike.
private final class NoFadeTiledLayer: CATiledLayer {
    // Fresh tiles must appear instantly — the default 0.25s cross-fade reads
    // as background flicker.
    override class func fadeDuration() -> CFTimeInterval { 0 }
}

private final class PatternTilingView: UIView {
    // Read from CATiledLayer's background drawing threads; written on main
    // before setNeedsDisplay. UIColor is immutable, so this is safe.
    var kind: CanvasBackground = .blank

    override class var layerClass: AnyClass { NoFadeTiledLayer.self }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
        if let tiled = layer as? CATiledLayer {
            tiled.tileSize = CGSize(width: 768, height: 768)
            tiled.levelsOfDetail = 5       // crisp down to 1/16× zoom-out
            tiled.levelsOfDetailBias = 5   // crisp up to 32× zoom-in
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard kind != .blank else { return }
        let spacing: CGFloat = 56
        switch kind {
        case .blank:
            break
        case .dots:
            let r: CGFloat = 1.5
            Theme.patternUI.setFill()
            guard let ctx = UIGraphicsGetCurrentContext() else { return }
            let x0 = max(1, Int(floor((rect.minX - r) / spacing)))
            let x1 = Int(ceil((rect.maxX + r) / spacing))
            let y0 = max(1, Int(floor((rect.minY - r) / spacing)))
            let y1 = Int(ceil((rect.maxY + r) / spacing))
            guard x1 >= x0, y1 >= y0 else { return }
            for yi in y0...y1 {
                for xi in x0...x1 {
                    ctx.fillEllipse(in: CGRect(
                        x: CGFloat(xi) * spacing - r,
                        y: CGFloat(yi) * spacing - r,
                        width: r * 2,
                        height: r * 2
                    ))
                }
            }
        case .lines, .grid:
            Theme.patternUI.withAlphaComponent(0.55).setFill()
            guard let ctx = UIGraphicsGetCurrentContext() else { return }
            let y0 = max(1, Int(floor((rect.minY - 1) / spacing)))
            let y1 = Int(ceil((rect.maxY + 1) / spacing))
            if y1 >= y0 {
                for yi in y0...y1 {
                    ctx.fill(CGRect(x: rect.minX, y: CGFloat(yi) * spacing - 0.5, width: rect.width, height: 1))
                }
            }
            if kind == .grid {
                let x0 = max(1, Int(floor((rect.minX - 1) / spacing)))
                let x1 = Int(ceil((rect.maxX + 1) / spacing))
                if x1 >= x0 {
                    for xi in x0...x1 {
                        ctx.fill(CGRect(x: CGFloat(xi) * spacing - 0.5, y: rect.minY, width: 1, height: rect.height))
                    }
                }
            }
        }
    }
}

// MARK: - Container view (pages + pattern + photos + PencilKit ink)

// Z-order, bottom to top (all SIBLINGS of the PKCanvasView, not subviews —
// PencilKit re-composites its own internals during pinch zoom, and anything
// living inside it flickers when that happens):
//   1. objectsHost — page cards + background pattern + photos
//   2. canvasView  — PencilKit ink (fully transparent background)
//   3. overlayHost — selection outline (photos only)
// The hosts live in page coordinates and are glued to the scroll position by
// syncHosts() on every scroll/zoom tick (translate by -contentOffset, scale
// by zoomScale) — both delegate callbacks fire synchronously within the same
// frame, so ink and paper never drift apart.

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

    // Fingers and trackpad pointer; never the Pencil.
    static let fingerAndPointerTouchTypes: [NSNumber] = [
        NSNumber(value: UITouch.TouchType.direct.rawValue),
        NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
    ]

    let canvasView = NoteyCanvasView()
    private let objectsHost = UIView()      // below the ink: pages + photos
    private let overlayHost = UIView()      // above the ink: selection outline
    private let pagesHost = UIView()
    private var pageCards: [UIView] = []
    private var patternViews: [PatternTilingView] = []
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
    private var toolPicker: PKToolPicker? = nil
    private var toolPickerVisible = false

    var toolbarSettings = ToolbarSettings() {
        didSet {
            guard toolbarSettings != oldValue else { return }
            rebuildToolPickerIfNeeded()
        }
    }

    // Shape straightening ("draw and hold" → ideal shape); full editor only.
    private var shapeSnapper: ShapeSnapper?
    var shapeDetectionEnabled = true {
        didSet { shapeSnapper?.isEnabled = shapeDetectionEnabled && !compact }
    }
    // Developer mode (Simulator has no Pencil): fingers/pointer draw ink and
    // trigger the hold-to-snap, two fingers scroll. Never on for compact tiles.
    var devFingerDrawing = false {
        didSet {
            guard devFingerDrawing != oldValue else { return }
            shapeSnapper?.acceptsFingerTouches = devFingerDrawing
            updateGestureStates()
        }
    }
    // Stroke count when the current tool interaction began — tells a fresh ink
    // stroke (a snap candidate) apart from an erase or a lasso move.
    private var strokeCountAtToolBegin = 0
    // PencilKit commits strokes ASYNCHRONOUSLY: when canvasViewDidEndUsingTool
    // fires, the fresh stroke is often not in drawing.strokes yet. This flag
    // defers the shape-snap check to the next canvasViewDrawingDidChange.
    private var pendingSnapCheck = false

    var undoManagerForCanvas: UndoManager? { canvasView.undoManager ?? undoManager }

    // MARK: Init

    init(drawing: PKDrawing, elements: CanvasElements, compact: Bool = false) {
        self.elements = elements
        self.compact = compact
        super.init(frame: .zero)
        backgroundColor = compact ? Theme.cardUI : UIColor(Theme.bg)
        // The hosts extend far beyond the visible frame (they cover the whole
        // page space) — without clipping they would paint over neighbors.
        clipsToBounds = true

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
        // Coherent touch model everywhere (canvas, calendar grid): the Pencil
        // draws, one OR two fingers scroll, pinch zooms, and a finger never
        // marks the page (drawingPolicy = .pencilOnly). Fingers and trackpad
        // only — the Pencil must never pan.
        canvasView.panGestureRecognizer.minimumNumberOfTouches = 1
        canvasView.panGestureRecognizer.allowedTouchTypes = Self.fingerAndPointerTouchTypes
        // Trackpad / mouse wheel pans too.
        canvasView.panGestureRecognizer.allowedScrollTypesMask = .all

        objectsHost.layer.anchorPoint = .zero
        objectsHost.layer.position = .zero
        objectsHost.isUserInteractionEnabled = false

        pagesHost.frame = CGRect(origin: .zero, size: totalSize)
        objectsHost.addSubview(pagesHost)

        overlayHost.layer.anchorPoint = .zero
        overlayHost.layer.position = .zero
        overlayHost.isUserInteractionEnabled = false

        selectionLayer.fillColor = nil
        selectionLayer.strokeColor = UIColor(Theme.navy).cgColor
        selectionLayer.lineWidth = 1.5
        selectionLayer.lineDashPattern = [6, 4]

        overlayHost.layer.addSublayer(selectionLayer)

        // Siblings of the canvas — paper below the (transparent) ink layer,
        // selection above it. See the z-order note at the top of the class.
        addSubview(objectsHost)
        addSubview(canvasView)
        addSubview(overlayHost)
        syncHostSizes()

        // Photo gestures — all finger-only (the Pencil is reserved for ink and
        // shape-holding). They select / move / resize photos and coexist with
        // PencilKit's own drawing and two-finger scroll.
        let fingerOnly = [NSNumber(value: UITouch.TouchType.direct.rawValue)]

        objectTap = UITapGestureRecognizer(target: self, action: #selector(handleObjectTap(_:)))
        objectTap.delegate = self
        objectTap.allowedTouchTypes = fingerOnly
        objectTap.isEnabled = !compact
        canvasView.addGestureRecognizer(objectTap)

        objectPan = UIPanGestureRecognizer(target: self, action: #selector(handleObjectPan(_:)))
        objectPan.delegate = self
        objectPan.maximumNumberOfTouches = 1
        objectPan.allowedTouchTypes = fingerOnly
        objectPan.isEnabled = !compact
        canvasView.addGestureRecognizer(objectPan)
        // A one-finger drag that starts on a photo (or its resize handle)
        // belongs to the photo — the canvas scroll must wait for that verdict,
        // otherwise resizing a photo also pans the canvas. Off-photo drags
        // fail objectPan instantly (gestureRecognizerShouldBegin), so normal
        // scrolling is unaffected.
        canvasView.panGestureRecognizer.require(toFail: objectPan)

        // Hold & drag a photo (finger), even while an ink tool is active.
        holdPress = UILongPressGestureRecognizer(target: self, action: #selector(handleHoldPress(_:)))
        holdPress.minimumPressDuration = 0.4
        holdPress.delegate = self
        holdPress.allowedTouchTypes = fingerOnly
        holdPress.isEnabled = !compact
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
        if toolPickerVisible && toolPicker == nil {
            rebuildToolPickerIfNeeded()
        } else {
            applyToolPickerVisibility()
        }
    }

    private func rebuildToolPickerIfNeeded() {
        guard !compact, window != nil else { return }
        let isVisible = toolPickerVisible
        if let oldPicker = toolPicker {
            oldPicker.setVisible(false, forFirstResponder: canvasView)
            oldPicker.removeObserver(canvasView)
        }
        
        let newPicker: PKToolPicker
        if #available(iOS 18.0, *) {
            var items: [PKToolPickerItem] = []
            if toolbarSettings.showPen { items.append(PKToolPickerInkingItem(type: .pen)) }
            if toolbarSettings.showPencil { items.append(PKToolPickerInkingItem(type: .pencil)) }
            if toolbarSettings.showHighlighter { items.append(PKToolPickerInkingItem(type: .marker)) }
            if toolbarSettings.showEraser { items.append(PKToolPickerEraserItem(type: .bitmap)) }
            if toolbarSettings.showLasso { items.append(PKToolPickerLassoItem()) }
            if toolbarSettings.showRuler { items.append(PKToolPickerRulerItem()) }
            // If empty, supply a default so it doesn't crash or look totally broken
            if items.isEmpty { items.append(PKToolPickerInkingItem(type: .pen)) }
            newPicker = PKToolPicker(toolItems: items)
        } else {
            newPicker = PKToolPicker()
        }
        
        newPicker.colorUserInterfaceStyle = .light
        newPicker.overrideUserInterfaceStyle = .light
        
        toolPicker = newPicker
        if isVisible {
            applyToolPickerVisibility()
        }
    }

    private func applyToolPickerVisibility() {
        guard !compact, window != nil, let picker = toolPicker else { return }
        if toolPickerVisible {
            // Adding the canvas as an observer wires its active `tool` to the
            // picker's selection automatically (native behavior).
            picker.addObserver(canvasView)
            picker.setVisible(true, forFirstResponder: canvasView)
            canvasView.becomeFirstResponder()
        } else {
            picker.setVisible(false, forFirstResponder: canvasView)
            picker.removeObserver(canvasView)
            canvasView.resignFirstResponder()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // First responder + picker can only attach once we're in a window.
        if window != nil {
            if toolPickerVisible && toolPicker == nil {
                rebuildToolPickerIfNeeded()
            } else {
                applyToolPickerVisibility()
            }
        }
    }

    // MARK: Pages

    private var paperUIColor: UIColor {
        config.paperColorHex.map { UIColor(hexString: $0) } ?? Theme.cardUI
    }

    private func rebuildPages() {
        for card in pageCards { card.removeFromSuperview() }
        pageCards.removeAll()
        patternViews.removeAll()
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
                // Without an explicit path the shadow is re-derived from the
                // layer's alpha every frame — an offscreen pass that visibly
                // shimmers during pinch zoom.
                card.layer.shadowPath = UIBezierPath(
                    roundedRect: CGRect(origin: .zero, size: frame.size),
                    cornerRadius: card.layer.cornerRadius
                ).cgPath
            }
            let pattern = PatternTilingView(frame: CGRect(origin: .zero, size: frame.size))
            pattern.layer.cornerRadius = card.layer.cornerRadius
            pattern.layer.masksToBounds = true
            card.addSubview(pattern)
            patternViews.append(pattern)
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
        syncHostSizes()
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
        syncHosts()
    }

    /// Glue the sibling hosts to the canvas content: page point p renders at
    /// p·zoom − contentOffset, exactly where PencilKit puts the ink.
    private func syncHosts() {
        let z = zoom
        let offset = canvasView.contentOffset
        let transform = CGAffineTransform(translationX: -offset.x, y: -offset.y)
            .scaledBy(x: z, y: z)
        objectsHost.transform = transform
        overlayHost.transform = transform
        if selected != nil { refreshSelectionLayer() }
    }

    /// The hosts' bounds only need to cover the page space (nothing clips or
    /// lays out against them, but stale sizes invite subtle bugs).
    private func syncHostSizes() {
        let size = totalSize
        objectsHost.bounds = CGRect(origin: .zero, size: size)
        overlayHost.bounds = CGRect(origin: .zero, size: size)
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
        syncHosts()
    }

    // PKCanvasViewDelegate (UIScrollViewDelegate) — keep paper and overlays
    // glued to the ink on every zoom/scroll tick.
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        syncHosts()
    }

    // Scrolling drives the infinite growth; deferred edge shifts are retried
    // once the gesture settles.
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        syncHosts()
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

        // Drawing policy + pan reconfig live in updateGestureStates — setting
        // the policy again here would re-trigger PencilKit's pan reset AFTER
        // the re-assert and undo it.
        updateGestureStates()

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
            for card in pageCards { card.backgroundColor = paperUIColor }
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
        syncHostSizes()
        if let card = pageCards.first {
            card.frame = CGRect(origin: .zero, size: infiniteSheet)
            patternViews.first?.frame = card.bounds
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
        // The ruling is drawn by CATiledLayer-backed views: only visible tiles
        // render (O(viewport) even on the 90k-pt infinite sheet), each zoom
        // level re-renders crisp, and nothing shimmers during pinch.
        for card in pageCards { card.backgroundColor = paperUIColor }
        for pattern in patternViews {
            pattern.kind = config.background
            pattern.layer.setNeedsDisplay()
        }
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
        // The overlay layer lives in page space (scaled by zoom), so all the
        // chrome sizes are divided back by the zoom to stay screen-constant.
        let z = zoom
        let pad = 6 / z
        let handleR = 11 / z
        selectionLayer.lineWidth = 1.6 / z
        selectionLayer.lineDashPattern = [NSNumber(value: Double(6 / z)), NSNumber(value: Double(4 / z))]
        let path = UIBezierPath(roundedRect: frame.insetBy(dx: -pad, dy: -pad), cornerRadius: 10 / z)
        // Resize handle (bottom-right).
        path.append(UIBezierPath(ovalIn: CGRect(
            x: frame.maxX - handleR, y: frame.maxY - handleR,
            width: handleR * 2, height: handleR * 2
        )))
        selectionLayer.path = path.cgPath
    }

    /// Hit test for the resize handle of the selected photo. The grab radius
    /// is screen-constant (the handle is drawn screen-constant too) and the
    /// handle straddles the photo's corner, so this must run BEFORE any
    /// "inside the frame" checks — most of the handle lies outside the frame.
    private func resizeHandleTarget(at point: CGPoint) -> SelectedElement? {
        guard case .image(let id)? = selected, let frame = frameOf(.image(id)) else { return nil }
        let grab = max(16, 26 / zoom)
        return hypot(point.x - frame.maxX, point.y - frame.maxY) <= grab ? .image(id) : nil
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
        pendingSnapCheck = false
        strokeCountAtToolBegin = canvasView.drawing.strokes.count
        // A hold left armed by the previous interaction (e.g. holding the
        // eraser still) must never straighten this fresh stroke.
        shapeSnapper?.strokeDidBegin()
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        toolInUse = false
        // The live snap replaces the ink mid-touch by cancelling the drawing
        // gesture — the tool end that cancellation produces is bookkeeping,
        // not a stroke end, and must not arm the on-lift snap.
        let liveSnapped = shapeSnapper?.toolInteractionDidEnd() ?? false
        // Fallback: straighten the just-finished stroke if the Pencil was
        // held still at its end and exactly one ink stroke was added (not an
        // erase/lasso). PencilKit often commits the stroke AFTER this
        // callback — when the count hasn't ticked up yet, defer the check to
        // drawingDidChange.
        if !liveSnapped, canvasView.tool is PKInkingTool {
            if canvasView.drawing.strokes.count == strokeCountAtToolBegin + 1 {
                shapeSnapper?.inkStrokeDidEnd()
            } else {
                snapLog("stroke not committed yet — deferring snap check")
                pendingSnapCheck = true
            }
        }
        retryPendingEdgeShift()
        ensureRunwayForContent()
    }

    // MARK: Photo drag machinery

    // Scroll views ABOVE this canvas (the month grid) suspended for the length
    // of a photo drag — a drag/resize must never simultaneously pan them.
    private var suspendedScrollViews: [UIScrollView] = []

    private func suspendEnclosingScrollViews() {
        var view: UIView? = superview
        while let current = view {
            if let scrollView = current as? UIScrollView, scrollView.isScrollEnabled {
                scrollView.isScrollEnabled = false   // cancels any pan in flight
                suspendedScrollViews.append(scrollView)
            }
            view = current.superview
        }
    }

    private func resumeEnclosingScrollViews() {
        for scrollView in suspendedScrollViews { scrollView.isScrollEnabled = true }
        suspendedScrollViews.removeAll()
    }

    private func beginDrag(of element: SelectedElement, resize: Bool) {
        guard let frame = frameOf(element) else { return }
        selected = element
        dragIsResize = resize
        dragActive = true
        dragOriginalFrame = frame
        dragBaseDrawing = canvasView.drawing
        dragBaseElements = elements
        suspendEnclosingScrollViews()
    }

    private func updateDrag(translation: CGPoint) {
        guard dragActive, let selected else { return }
        let dx = translation.x / zoom
        let dy = translation.y / zoom
        if dragIsResize {
            // Corner handle: follow whichever axis moved further, so dragging
            // straight down grows the photo just like dragging right.
            let aspect = dragOriginalFrame.height / max(1, dragOriginalFrame.width)
            let growth = max(dx, aspect > 0 ? dy / aspect : dx)
            let w = max(40, dragOriginalFrame.width + growth)
            let newFrame = CGRect(x: dragOriginalFrame.minX, y: dragOriginalFrame.minY, width: w, height: w * aspect)
            setFrame(newFrame, for: selected)
        } else {
            setFrame(dragOriginalFrame.offsetBy(dx: dx, dy: dy), for: selected)
        }
    }

    private func endDrag() {
        guard dragActive else { return }
        dragActive = false
        resumeEnclosingScrollViews()
        commitElementChange(from: dragBaseElements, fromDrawing: dragBaseDrawing)
        retryPendingEdgeShift()
        ensureRunwayForContent()
    }

    private func updateGestureStates() {
        // Photo gestures stay finger-only and always on; the Pencil owns ink
        // through PencilKit. Compact tiles set their own tool in apply().
        // Developer mode flips fingers from scrolling to drawing so the whole
        // ink pipeline (including hold-to-snap) can be exercised on the
        // Simulator, which has no Pencil.
        canvasView.drawingPolicy = devFingerDrawing ? .anyInput : .pencilOnly
        // PencilKit re-configures the scroll pan when the drawing policy is
        // applied — re-assert the coherent touch model (one-finger finger/
        // pointer pan, never the Pencil) every time. With finger drawing on,
        // one finger draws and TWO fingers scroll.
        canvasView.panGestureRecognizer.minimumNumberOfTouches = devFingerDrawing ? 2 : 1
        canvasView.panGestureRecognizer.allowedTouchTypes = Self.fingerAndPointerTouchTypes
        if compact {
            canvasView.panGestureRecognizer.isEnabled = false
            canvasView.pinchGestureRecognizer?.isEnabled = false
        } else {
            canvasView.panGestureRecognizer.isEnabled = true
            canvasView.pinchGestureRecognizer?.isEnabled = true
        }
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
            if let handle = resizeHandleTarget(at: pt) {
                beginDrag(of: handle, resize: true)
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

    // holdPress and objectPan only engage when the touch starts on a photo (or
    // on the selected photo's resize handle, which straddles the frame corner
    // and mostly lies OUTSIDE the frame), so empty-space finger touches fall
    // through to PencilKit / two-finger scroll.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if let pan = gestureRecognizer as? UIPanGestureRecognizer, pan === objectPan {
            let pt = startPagePoint(of: pan)
            return resizeHandleTarget(at: pt) != nil || elementAt(pt) != nil
        }
        if gestureRecognizer === holdPress {
            let p = gestureRecognizer.location(in: canvasView)
            return elementAt(CGPoint(x: p.x / zoom, y: p.y / zoom)) != nil
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // The finger-only photo recognizers coexist with each other and with
        // PencilKit's own drawing / scroll / zoom gestures — but NOT with
        // gestures of enclosing views (e.g. the month grid's scroll view):
        // dragging or resizing a photo must never also pan the container.
        guard let otherView = otherGestureRecognizer.view else { return false }
        return otherView === canvasView || otherView.isDescendant(of: canvasView)
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
        // The stroke that ended a moment ago has now been committed — run the
        // deferred shape-snap check (see canvasViewDidEndUsingTool). Clear the
        // flag FIRST: the snap itself swaps the drawing and re-enters here.
        if pendingSnapCheck {
            pendingSnapCheck = false
            if canvasView.drawing.strokes.count == strokeCountAtToolBegin + 1 {
                shapeSnapper?.inkStrokeDidEnd()
            }
        }
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
