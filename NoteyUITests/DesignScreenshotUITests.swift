import XCTest

// Design-review driver: rotates the Simulator to landscape and walks the main
// screens, pausing on each so the host can capture `simctl io screenshot`s.
// Not a test of behavior — a harness for visual QA of theming work.
final class DesignScreenshotUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLandscapeTour() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launch()
        sleep(6)   // grid (host screenshot #1)

        let calendar = app.buttons["Kalendarz"].firstMatch
        if calendar.waitForExistence(timeout: 5) {
            calendar.tap()
        }
        sleep(6)   // calendar month (host screenshot #2)
    }
}
