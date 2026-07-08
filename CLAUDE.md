# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Language

The user communicates in Polish — respond in Polish. All user-facing UI strings are Polish. Code identifiers and comments are English.

## Build

iPad-only SwiftUI app (iOS 17+, `TARGETED_DEVICE_FAMILY = 2`). No tests, no linter.

```bash
# The Xcode project is GENERATED — after adding/removing source files:
xcodegen generate

# Build (explicit derivedDataPath avoids confusion with stale DerivedData dirs):
xcodebuild -project Notey.xcodeproj -scheme Notey \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -derivedDataPath /tmp/notey-dd build CODE_SIGNING_ALLOWED=NO
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

`DrawingCanvas` (UIViewRepresentable) wraps `CanvasContainer: UIView`, which owns a `PKCanvasView` plus host views. Everything operates in **page coordinates** (logical page 1000×1400 pt, `CanvasPage`); host views are scaled to screen via `transform = zoom` (`syncOverlay`), and gesture locations are divided by `zoom`.

Z-order (subviews of the PKCanvasView), bottom to top:
1. `objectsHost` — page cards + background pattern + photos (inserted at index 0, below PencilKit's internal ink rendering)
2. PencilKit ink (internal)
3. `overlayHost` — photo selection outline (`ImmediateShapeLayer` = CAShapeLayer without implicit animations, for 1:1 tracking)

Tools are **native**: writing / erasing / lasso-select / ruler / colors / undo all come from `PKToolPicker` (attached via `setToolPickerVisible`) — the same floating toolbar as Apple Notes. `CanvasToolConfig` no longer carries a tool; it holds page appearance (background/paper/layout/orientation/template) plus a minimal "compact ink" (pen/marker/eraser + color + width) used ONLY by the compact calendar tiles, which have no picker.

Key subsystems, each with invariants documented inline:
- **Infinite layout**: the sheet is a growing window, not a fixed size (`ensureInfiniteRunway`). Left/top growth shifts the *entire coordinate space* (`shiftContent`) by pattern-aligned (56 pt) deltas so nothing moves on screen; shifts are deferred while a stroke/drag is in flight (`pendingEdgeShift`). Reopening a note re-normalizes coordinates.
- **Shape straightening** (`ShapeRecognizer.swift`): PencilKit exposes NO public shape recognition (Apple Notes' "Smart Shapes" is private), so this is a custom pass on top. A pencil-only `HoldStillGestureRecognizer` fires when the Pencil is held still ~0.4 s at a stroke's end; on lift (`canvasViewDidEndUsingTool`, gated to exactly one fresh ink stroke) `ShapeRecognizer.idealize` classifies it (line / arrow / triangle / rectangle / ellipse via RDP + an ellipse-fit test) and swaps it for an idealized `PKStroke` that keeps the original ink. Undoable through `commitElementChange`. Editor toggle: `@AppStorage("shapeDetectionEnabled")`. Not testable in the Simulator (pencil-only + no synthetic Pencil).
- **Photos** (`beginDrag`/`updateDrag`/`endDrag`): finger-only — tap selects, drag/resize, 0.4 s hold picks up — all coexisting with the Pencil (which always draws). There is no object "tool".
- **Gestures**: Pencil-only for writing (`drawingPolicy = .pencilOnly` everywhere). Only the Pencil draws; two fingers scroll (pan `minimumNumberOfTouches = 2`), pinch zooms. Photo recognizers are finger-only (`allowedTouchTypes = [.direct]`) so the Pencil never moves a photo and a finger never marks the page. Pan hit-testing uses the touch-down point (`startPagePoint`) because pans recognize ~10 pt late.
- **Undo**: PencilKit's own undo + `registerUndo` snapshots of (elements, drawing) via `commitElementChange`, merged through `undoManagerForCanvas`.
- `CanvasProxy` (ObservableObject) is the SwiftUI→UIKit command channel (add image/page, delete/clear, undo, export, paste quick-note ink).

### WYSIWYG renderers must match canvas z-order

`NoteExporter` (PDF) and `NoteThumbnail` (cached tile/card previews) re-draw notes from (drawing, elements) with the same ordering as the live canvas: photos → all ink on top. If canvas layering changes, change both.

### UI shell

- `ContentView` — NavigationSplitView; Chrome-like tabs of open notes (IDs persisted in `@AppStorage`), routing (`Route`: all notes / folder / calendar / quick notes), floating quick-note cards (`QuickNoteCard`, anchors + edge-docking persisted as JSON in AppStorage).
- `Browser/` — sidebar folder tree, note grid, tabs bar (drag & drop between them).
- `Calendar/CalendarScreen.swift` — year/month/week/day; month tiles are rendered thumbnails (42 live canvases would be too slow), direct writing happens in week/day views.
- `CanvasEditorView` — attaches the native `PKToolPicker` to `DrawingCanvas` and keeps a slim app-level top bar (note settings, pages ±, shape-detection toggle, photo import, PDF export); autosave into SwiftData.
- The whole app forces light mode (`preferredColorScheme(.light)`, canvas `overrideUserInterfaceStyle = .light`) so ink colors stay WYSIWYG on the beige theme (`Theme.swift`).
