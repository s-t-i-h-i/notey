import XCTest

// Simulator driver for the shape-snap pipeline. The Simulator has no Pencil,
// so with the dev finger-drawing mode on (defaults key `devFingerDrawing`)
// these tests draw with synthesized direct touches — the one gesture a plain
// unit test cannot produce. Verification happens on two channels: the
// [ShapeSnap] NSLog trail (streamed by the runner) and the persisted drawing
// (screenshot after relaunch).
final class ShapeSnapUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testDrawAndHoldSnapsLine() throws {
        let app = XCUIApplication()
        // Command-line defaults are scoped to this launch and reliably enable
        // direct-touch drawing even on a freshly installed Simulator app.
        app.launchArguments += [
            "-devFingerDrawing", "YES",
            "-shapeDetectionEnabled", "YES"
        ]
        app.launch()

        // Fresh browser (runner clears notey.openTabs): create a note.
        let newNote = app.buttons["Nowa notatka"].firstMatch
        XCTAssertTrue(newNote.waitForExistence(timeout: 10), "missing 'Nowa notatka'")
        newNote.tap()

        // Every fresh note auto-opens its settings sheet — dismiss it.
        let done = app.buttons["Gotowe"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10), "missing 'Gotowe'")
        done.tap()

        // Let the canvas attach the tool picker and settle.
        sleep(2)

        let window = app.windows.firstMatch

        // Stroke 0 (warm-up, below the thumbnail crop): a plain committed
        // stroke, kept freehand — a control for the persisted drawing.
        // The editor uses a persistent split-view sidebar; keep every gesture
        // fully inside the page area on the trailing side of the window.
        let w1 = window.coordinate(withNormalizedOffset: CGVector(dx: 0.52, dy: 0.68))
        let w2 = window.coordinate(withNormalizedOffset: CGVector(dx: 0.76, dy: 0.70))
        w1.press(forDuration: 0.10, thenDragTo: w2, withVelocity: XCUIGestureVelocity(rawValue: 350), thenHoldForDuration: 0.05)

        sleep(1)

        // Stroke 1: ~4.5 deg tilted line, HELD still at the end. Expected:
        // the hold fires after ~0.65s and arms the snap; on pen-lift the ink
        // is replaced by a perfectly horizontal ideal line exactly as thick
        // as the stroke's own thickest point.
        let start1 = window.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.40))
        let end1 = window.coordinate(withNormalizedOffset: CGVector(dx: 0.80, dy: 0.42))
        start1.press(forDuration: 0.10, thenDragTo: end1, withVelocity: XCUIGestureVelocity(rawValue: 350), thenHoldForDuration: 1.6)

        sleep(1)

        // Stroke 2 (control): same tilt, NO hold. Must stay freehand/tilted.
        let start2 = window.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.55))
        let end2 = window.coordinate(withNormalizedOffset: CGVector(dx: 0.80, dy: 0.57))
        start2.press(forDuration: 0.10, thenDragTo: end2, withVelocity: XCUIGestureVelocity(rawValue: 350), thenHoldForDuration: 0.05)

        // Autosave debounce is 0.7s — give persistence time before teardown.
        sleep(3)

        let result = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        result.name = "shape-snap-live-result"
        result.lifetime = .keepAlways
        add(result)
    }
}
