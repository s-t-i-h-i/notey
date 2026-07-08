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
- `CanvasElements` = photos (`ImageElement`), annotation cards (`AnnotationElement`), and page count. It is a value type — canvas code mutates a copy and persists via `onChange`.
- `NoteKind`: `.note` (folders/tabs), `.calendar` (exactly one per day, fetched by `dateKey` "yyyy-MM-dd" via `NoteStore.calendarNote`), `.quick` (floating scratch cards).
- Stroke↔annotation attachment uses `PKStroke.fingerprint` (`randomSeed-pathCount`) stored in `AnnotationElement.strokeKeys`. The ONLY attachment rule: a stroke belongs to an annotation iff it *first appeared* on top of it (`trackNewStrokes`). Fingerprints survive PKDrawing serialization.

### Canvas engine (Canvas/DrawingCanvasView.swift, ~1500 lines)

`DrawingCanvas` (UIViewRepresentable) wraps `CanvasContainer: UIView`, which owns a `PKCanvasView` plus host views. Everything operates in **page coordinates** (logical page 1000×1400 pt, `CanvasPage`); host views are scaled to screen via `transform = zoom` (`syncOverlay`), and gesture locations are divided by `zoom`.

Z-order (subviews of the PKCanvasView), bottom to top:
1. `objectsHost` — page cards + background pattern + photos (inserted at index 0, below PencilKit's internal ink rendering)
2. `annotationsHost` — annotation cards, **below the ink**: annotations are highlight patches under the writing, so wet strokes are always fully visible while writing
3. PencilKit ink (internal)
4. `overlayHost` — selection outline + draft shapes (`ImmediateShapeLayer` = CAShapeLayer without implicit animations, required for 1:1 finger tracking)

Key subsystems, each with invariants documented inline:
- **Infinite layout**: the sheet is a growing window, not a fixed size (`ensureInfiniteRunway`). Left/top growth shifts the *entire coordinate space* (`shiftContent`) by pattern-aligned (56 pt) deltas so nothing moves on screen; shifts are deferred while a stroke/drag is in flight (`pendingEdgeShift`). Reopening a note re-normalizes coordinates.
- **Drag machinery** (`beginDrag`/`updateDrag`/`endDrag`): moving an annotation moves its attached strokes. During the drag the attached strokes are removed from the canvas and baked as an image onto the card (`setInk`) so they can't lag; they're re-inserted shifted on release. Works from the objects tool, the annotation tool, and hold-to-drag (0.4 s long-press while pen/marker active).
- **Gestures**: the app is Pencil-only for writing (`drawingPolicy = .pencilOnly` everywhere — there is no finger-drawing mode). Only the Pencil draws; two fingers scroll (pan `minimumNumberOfTouches = 2`), pinch zooms, a single finger never marks the page. Custom recognizers coexist with PencilKit's; pan hit-testing must use the touch-down point (`startPagePoint`) because pans recognize ~10 pt late.
- **Undo**: PencilKit's own undo + `registerUndo` snapshots of (elements, drawing) via `commitElementChange`, merged through `undoManagerForCanvas`.
- `CanvasProxy` (ObservableObject) is the SwiftUI→UIKit command channel (add image/page, undo, export, paste quick-note ink).

### WYSIWYG renderers must match canvas z-order

`NoteExporter` (PDF) and `NoteThumbnail` (cached tile/card previews) re-draw notes from (drawing, elements) with the same ordering as the live canvas: photos → annotation cards → all ink on top. If canvas layering changes, change both.

### UI shell

- `ContentView` — NavigationSplitView; Chrome-like tabs of open notes (IDs persisted in `@AppStorage`), routing (`Route`: all notes / folder / calendar / quick notes), floating quick-note cards (`QuickNoteCard`, anchors + edge-docking persisted as JSON in AppStorage).
- `Browser/` — sidebar folder tree, note grid, tabs bar (drag & drop between them).
- `Calendar/CalendarScreen.swift` — year/month/week/day; month tiles are rendered thumbnails (42 live canvases would be too slow), direct writing happens in week/day views.
- `CanvasEditorView` — toolbars around `DrawingCanvas`, tool config (`CanvasToolConfig`), photo import, autosave.
- The whole app forces light mode (`preferredColorScheme(.light)`, canvas `overrideUserInterfaceStyle = .light`) so ink colors stay WYSIWYG on the beige theme (`Theme.swift`).
