import XCTest

final class OngakuDesktopUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCriticalWindowsInSupportedLanguages() throws {
        for language in ["en", "ja", "zh-Hans"] {
            let app = XCUIApplication()
            app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", language]
            app.launch()

            XCTAssertTrue(
                app.descendants(matching: .any)["main.window"].waitForExistence(timeout: 10),
                "Main window did not become accessible in \(language)"
            )

            let syncButton = app.buttons["main.open-device-sync"]
            XCTAssertTrue(syncButton.waitForExistence(timeout: 5))
            XCTAssertTrue(syncButton.isHittable)
            XCTAssertFalse(syncButton.label.isEmpty)
            try app.performAccessibilityAudit(for: [
                .elementDetection, .hitRegion, .sufficientElementDescription,
            ])
            syncButton.click()
            XCTAssertTrue(
                app.descendants(matching: .any)["device-sync.window"].waitForExistence(timeout: 5),
                "Device sync window did not become accessible in \(language)"
            )
            let closeButton = app.buttons["device-sync.close"]
            XCTAssertTrue(closeButton.isHittable)
            XCTAssertFalse(closeButton.label.isEmpty)
            try app.performAccessibilityAudit(for: [
                .elementDetection, .hitRegion, .sufficientElementDescription,
            ])
            closeButton.click()

            let appleMusicButton = app.buttons["main.open-apple-music"]
            XCTAssertTrue(appleMusicButton.waitForExistence(timeout: 5))
            XCTAssertTrue(appleMusicButton.isHittable)
            appleMusicButton.click()
            XCTAssertTrue(
                app.descendants(matching: .any)["apple-music.window"].waitForExistence(timeout: 10),
                "Apple Music window did not become accessible in \(language)"
            )
            let appleMusicCloseButton = app.buttons["apple-music.close"]
            XCTAssertTrue(appleMusicCloseButton.isHittable)
            XCTAssertFalse(appleMusicCloseButton.label.isEmpty)
            try app.performAccessibilityAudit(for: [
                .elementDetection, .hitRegion, .sufficientElementDescription,
            ])
            appleMusicCloseButton.click()

            app.terminate()
        }
    }
}
