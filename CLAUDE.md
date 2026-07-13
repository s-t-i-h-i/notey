# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Language

The user communicates in Polish — respond in Polish. All user-facing UI strings are Polish. Code identifiers and comments are English.

## Build

iPad-only SwiftUI app (iOS 17+, `TARGETED_DEVICE_FAMILY = 2`). No unit tests, no linter; one UI-test target (`NoteyUITests`) that exists to drive the canvas with synthetic touches in the Simulator (see Shape straightening below).

```bash
# The Xcode project is GENERATED — after adding/removing source files:
xcodegen generate

# Build (explicit derivedDataPath avoids confusion with stale DerivedData dirs):
xcodebuild -project Notey.xcodeproj -scheme Notey \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -derivedDataPath /tmp/notey-dd build CODE_SIGNING_ALLOWED=NO

# Simulator driver for the shape-snap pipeline (draws with synthetic touches):
xcodebuild test -project Notey.xcodeproj -scheme Notey \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -derivedDataPath /tmp/notey-dd -only-testing:NoteyUITests CODE_SIGNING_ALLOWED=NO
```

Debug quirks:
- Xcode 26 debug builds put all code in `Notey.app/Notey.debug.dylib` (the `Notey` binary is a stub). Use `grep -a` on it — plain grep silently reports no match.
- When locating the built .app, exclude `Index.noindex` paths or simulator install fails with "Missing bundle ID".
- NSLog debugging: `xcrun simctl spawn <device> log stream --predicate 'processImagePath CONTAINS "Notey"'`.
- Canvas panning is untestable with synthetic mouse input (PKCanvasView pan needs 2 touches; alt-drags draw instead). Long-press/hold-to-drag and SwiftUI drag & drop do work.

`README.md` is partially stale (references an `ios/` root dir and an older annotation rule based on `creationDate`) — trust the code over the README.

## Architecture

SwiftUI shell + SwiftData persistence + a large UIKit/PencilKit canvas engine. Data flows one way: `CanvasContainer` fires `onChange(PKDrawing, CanvasElements)` → `CanvasEditorView` debounces (~0.5s Task) → writes into the `Note` SwiftData model.

### Data model (Models.swift)

- `Folder` / `Note` are `@Model` classes. A note's content is two opaque blobs with `.externalStorage`: `drawingData` (PKDrawing) and `elementsData` (JSON-encoded `CanvasElements`).
- `CanvasElements` = photos (`ImageElement`) and page count. It is a value type — canvas code mutates a copy and persists via `onChange`. (Old notes may still decode an `annotations` key left over from before the native-PencilKit rebuild; unknown JSON keys are ignored, and the handwriting itself was always ordinary `PKStroke`s, so it survives.)
- `NoteKind`: `.note` (folders/tabs), `.calendar` (exactly one per day, fetched by `dateKey` "yyyy-MM-dd" via `NoteStore.calendarNote`), `.quick` (floating scratch cards).

### Canvas engine (Canvas/DrawingCanvasView.swift + Canvas/ShapeRecognizer.swift)

`DrawingCanvas` (UIViewRepresentable) wraps `CanvasContainer: UIView`, which owns a `PKCanvasView` plus host views. Everything operates in **page coordinates** (logical page 1000×1400 pt, `CanvasPage`); gesture locations are divided by `zoom`.

Z-order — the hosts are **siblings** of the PKCanvasView, never subviews (PencilKit re-composites its internals during pinch zoom; anything living inside it flickers). Bottom to top:
1. `objectsHost` — page cards + background pattern + photos
2. `canvasView` — PencilKit ink (fully transparent background)
3. `overlayHost` — photo selection outline (`ImmediateShapeLayer` = CAShapeLayer without implicit animations, for 1:1 tracking; chrome sizes are divided by `zoom` to stay screen-constant)

`syncHosts()` glues the hosts to the ink on every `scrollViewDidScroll`/`DidZoom` tick (transform = translate −contentOffset, then scale zoom; both callbacks fire synchronously per frame, so nothing drifts). Page-card shadows have an explicit `shadowPath` — without it the per-frame offscreen shadow pass shimmers during zoom.

The page ruling (dots/lines/grid) is drawn by `PatternTilingView` — a CATiledLayer-backed view (the native zoomable-content mechanism behind PDF/map viewers): each zoom level re-renders the pattern vector-crisp on background threads, so it neither shimmers during pinch (a fixed-resolution layer strobes at subpixel sizes) nor blurs at rest, and it costs O(viewport) even on the 90k-pt infinite sheet. `NoFadeTiledLayer` zeroes the tile cross-fade (the default 0.25 s fade reads as flicker). Its `draw(_:)` runs on background threads — keep it to thread-safe drawing only.

Tools are **native**: writing / erasing / lasso-select / ruler / colors / undo all come from `PKToolPicker` (attached via `setToolPickerVisible`) — the same floating toolbar as Apple Notes. `CanvasToolConfig` no longer carries a tool; it holds page appearance (background/paper/layout/orientation/template) plus a minimal "compact ink" (pen/marker/eraser + color + width) used ONLY by the compact calendar tiles, which have no picker.

Key subsystems, each with invariants documented inline:
- **Infinite layout**: the sheet is a growing window, not a fixed size (`ensureInfiniteRunway`). Left/top growth shifts the *entire coordinate space* (`shiftContent`) by pattern-aligned (56 pt) deltas so nothing moves on screen; shifts are deferred while a stroke/drag is in flight (`pendingEdgeShift`). Reopening a note re-normalizes coordinates.
- **Shape straightening** (`ShapeRecognizer.swift`): PencilKit exposes NO public shape recognition (Apple Notes' "Smart Shapes" is private), so this is a custom pass on top. A pencil-only `HoldStillGestureRecognizer` (passive observer, never leaves `.possible`, re-armable; fingers/pointer too in the dev finger mode) fires when the Pencil is held still ~0.65 s (`stillDuration`). The snap runs ON PEN-LIFT, replacing the committed stroke with ideal strokes. The lift timing is deliberate: PencilKit never exposes a wet stroke's rendered point sizes — and the tool's NOMINAL width bears no relation to them (monoline: committed size 4.0 at tool width 2.0; not proportional across widths either) — so only a post-commit swap can style the ideal shape EXACTLY like the drag it replaces. (A mid-touch live morph was tried and removed: it had to guess thickness from previously committed strokes and kept mismatching the current drag's press.) Hold-time feedback is a light-gray GEOMETRY-ONLY preview of the ideal outlines instead — computed from the hold recognizer's own coalesced touch trace, drawn by the container (`onPreview` → `snapPreviewLayer`, an `ImmediateShapeLayer` on the overlay host) at a fixed screen-constant hairline; it clears when the pen draws on past the hold (`onHoldInvalidated`), lifts, or a new stroke begins. THICKNESS IS UNIFORM by design: one size for the whole shape — the stroke's single thickest rendered point, i.e. the firmest press of the drag (`fattestStyle`); undo restores the original freehand via the pre-snap drawing snapshot. TWO invariants keep the trigger alive: (1) the hold observer MUST have a delegate answering `shouldRecognizeSimultaneouslyWith → true` (belt-and-braces: `canBePrevented → false`), otherwise PencilKit's drawing recognizer prevents it (reset → its timer dies → it never fires); (2) the hold only ARMS while an inking-tool interaction is in flight (`toolStrokeActive` + `tool is PKInkingTool`), so holding the eraser/lasso still does nothing (not even haptics). PencilKit commits strokes ASYNCHRONOUSLY (at `canvasViewDidEndUsingTool` the fresh stroke is often not in `drawing.strokes` yet, so the snap check re-runs from the next `canvasViewDrawingDidChange` via `pendingSnapCheck`), gated to exactly one fresh ink stroke AND the hold happening at the stroke's END; `strokeDidBegin()` clears stale holds either way. `ShapeRecognizer.idealize` rebuilds committed strokes; `idealOutlines` normalizes ALL input by arc-length resampling (points pile up wherever the pen moved slowly) and collapses end dwells. Corner detection = turning angle over a size-adaptive window. Open strokes: arrow (straight OR Bézier-curved shaft; hook/V heads; symmetric ideal head) → 45°-snapped line → polyline → circular arc (Kåsa least-squares) → piecewise cubic Bézier (Schneider fit). Closed: circle/ellipse at any tilt (second-moment fit) → triangle / rectangle at any rotation (with axis snap) / quad / polygon (≤8 corners) → smoothed Catmull-Rom loop. A deliberate hold always produces SOMETHING (worst case: a cleaned curve). Ink params (size/opacity/force/angles) come from the stroke's single thickest point, applied uniformly. Undoable through `commitElementChange`. Editor toggle: `@AppStorage("shapeDetectionEnabled")`. TESTABLE without a Pencil two ways. (a) In the Simulator: DEBUG builds have a dev finger-drawing mode (`@AppStorage("devFingerDrawing")`, hand.draw toggle in the editor top bar, or `xcrun simctl spawn <device> defaults write com.adrian.notey devFingerDrawing -bool YES`) — drawingPolicy flips to `.anyInput`, ONE finger/mouse-drag draws (two fingers scroll) and the hold recognizer also observes direct/pointer touches, so draw-and-hold works with the mouse; `NoteyUITests/ShapeSnapUITests` drives it synthetically (press→drag→hold via XCUITest — the only public API for a one-touch drag-and-hold), and the whole trigger pipeline NSLogs a `[ShapeSnap]` trail in DEBUG (hold fired / deferring / snapped / rejected + reason) for `log stream`. (b) Host-side: the classifier is pure geometry: everything from `enum ShapeRecognizer {` to the `// MARK: - PencilKit bridge` line has zero UIKit/PencilKit deps and can be extracted (sed line range), compiled host-side with `swiftc` (add `import Foundation`/`CoreGraphics`), and exercised with synthetic jittered strokes via `ShapeRecognizer.idealOutlines(for:)`. Keep that section PencilKit-free.
- **Photos** (`beginDrag`/`updateDrag`/`endDrag`): finger-only — tap selects, drag/resize, 0.4 s hold picks up — all coexisting with the Pencil (which always draws). There is no object "tool".
- **Gestures** (one coherent model across editor canvas, both layouts, and the calendar grid): the Pencil draws and ONLY draws (`drawingPolicy = .pencilOnly` everywhere; the Pencil never pans anything). One or two fingers scroll, pinch zooms — the canvas scroll pan is fingers+trackpad (`allowedTouchTypes = [.direct, .indirectPointer]`, min 1 touch; PencilKit re-configures the pan when `drawingPolicy` is applied, so `updateGestureStates()` re-asserts this every apply). Photo recognizers are finger-only. A one-finger drag starting on a photo (or the selected photo's resize handle, which straddles the corner OUTSIDE the frame) belongs to the photo: the scroll pan has `require(toFail: objectPan)`, our `shouldRecognizeSimultaneouslyWith` only allows canvas-internal recognizer pairs, and `beginDrag` suspends ENCLOSING scroll views (month grid) until `endDrag` — so dragging/resizing a photo can never simultaneously pan any surface. Pan hit-testing uses the touch-down point (`startPagePoint`) because pans recognize ~10 pt late.
- **Undo**: PencilKit's own undo + `registerUndo` snapshots of (elements, drawing) via `commitElementChange`, merged through `undoManagerForCanvas`.
- `CanvasProxy` (ObservableObject) is the SwiftUI→UIKit command channel (add image/page, delete/clear, undo, export, paste quick-note ink).

### WYSIWYG renderers must match canvas z-order

`NoteExporter` (PDF) and `NoteThumbnail` (cached tile/card previews) re-draw notes from (drawing, elements) with the same ordering as the live canvas: photos → all ink on top. If canvas layering changes, change both.

### UI shell

- `ContentView` — NavigationSplitView; Chrome-like tabs of open notes (IDs persisted in `@AppStorage`), routing (`Route`: all notes / folder / calendar / quick notes), floating quick-note cards (`QuickNoteCard`, anchors + edge-docking persisted as JSON in AppStorage).
- `Browser/` — sidebar folder tree, note grid, tabs bar (drag & drop between them).
- `Calendar/CalendarScreen.swift` — year/month/day; month tiles are LIVE compact canvases (Pencil writes directly on them), hosted in `ZoomableGridView`: a UIScrollView wrapper giving the grid the same feel as the note canvas — one/two-finger pan, native pinch (fingers+trackpad only; the Pencil keeps writing on tiles), PURE transform zoom 0.35–2.5 with no re-layout anywhere (a re-layout fold-in was tried and hitches with 42 live canvases), content centered when zoomed out smaller than the viewport. Zoom/scroll survive month navigation and the day-editor modal: `tileRefresh` remounts only the tile canvases (`CalendarDayCanvas.id("\(dateKey)#\(refresh)")`), never the grid. The hosted content gets `\.modelContext` injected explicitly (UIHostingController does not inherit SwiftUI environment). Tile saves debounce 0.25 s (the enlarged day editor reads the note on open).
- `CanvasEditorView` — attaches the native `PKToolPicker` to `DrawingCanvas` and keeps a slim app-level top bar (note settings, pages ±, shape-detection toggle, photo import, PDF export); autosave into SwiftData.
- The whole app forces light mode (`preferredColorScheme(.light)`, canvas `overrideUserInterfaceStyle = .light`) so ink colors stay WYSIWYG on the beige theme (`Theme.swift`).
