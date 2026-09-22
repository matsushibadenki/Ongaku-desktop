import AppKit
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

    /// Opt-in because this creates and renders the full 100,000-track qualification catalog.
    /// Run from a Release test action with ONGAKU_RUN_UI_PERFORMANCE=1.
    @MainActor
    func testReleaseLargeLibraryQualification() throws {
        guard ProcessInfo.processInfo.environment["ONGAKU_RUN_UI_PERFORMANCE"] == "1" else {
            throw XCTSkip("Set ONGAKU_RUN_UI_PERFORMANCE=1 for the Release UI qualification.")
        }

        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("OngakuUIQualification-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let preparationApp = qualificationApplication(rootURL: fixtureRoot, prepare: true)
        preparationApp.launch()
        XCTAssertTrue(
            waitForVisibleCount("100000", in: preparationApp, timeout: 180),
            "The 100,000-track qualification fixture did not finish preparing."
        )
        preparationApp.terminate()

        let app = qualificationApplication(rootURL: fixtureRoot, prepare: false)
        let launchStarted = ContinuousClock.now
        app.launch()
        XCTAssertTrue(waitForVisibleCount("100000", in: app, timeout: 20))
        XCTAssertTrue(
            renderedTrack(named: "Track 000000", in: app).waitForExistence(timeout: 20),
            "The initial song table did not render its first track."
        )
        let initialDisplaySeconds = launchStarted.duration(to: .now).seconds
        XCTAssertLessThan(initialDisplaySeconds, 2.0)

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        var searchDurations: [Double] = []
        let launchedProcessID = newestOngakuProcessID()
        var observedPeakRSSMiB = launchedProcessID.flatMap(residentMemoryMiB) ?? 0
        for index in 0..<10 {
            searchField.click()
            searchField.typeKey("a", modifierFlags: .command)
            searchField.typeKey(.delete, modifierFlags: [])
            let query = String(format: "Track %06d", index * 3)
            searchField.typeText(String(query.dropLast()))
            let searchStarted = ContinuousClock.now
            searchField.typeText(String(query.suffix(1)))
            XCTAssertTrue(
                waitForSearchResult(
                    title: query,
                    in: app,
                    timeout: 5
                ),
                "Search did not render the requested track: \(query)"
            )
            searchDurations.append(searchStarted.duration(to: .now).seconds)
            observedPeakRSSMiB = max(
                observedPeakRSSMiB,
                launchedProcessID.flatMap(residentMemoryMiB) ?? 0
            )
        }

        let sortedDurations = searchDurations.sorted()
        let p95 = sortedDurations[Int(ceil(Double(sortedDurations.count) * 0.95)) - 1]
        print(
            "ONGAKU_A3_UI initialDisplay=\(initialDisplaySeconds)s "
                + "searchP95=\(p95)s observedRSS=\(observedPeakRSSMiB)MiB"
        )
        XCTAssertLessThan(p95, 0.3, "Release UI search p95 was \(p95) seconds.")
        XCTAssertGreaterThan(observedPeakRSSMiB, 0, "Could not sample resident memory.")
        XCTAssertLessThan(observedPeakRSSMiB, 512)
        app.terminate()
    }

    @MainActor
    private func qualificationApplication(rootURL: URL, prepare: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "--ongaku-qualification-root", rootURL.path,
        ]
        if prepare {
            app.launchArguments += ["--ongaku-qualification-prepare", "100000"]
        }
        return app
    }

    @MainActor
    private func waitForVisibleCount(
        _ expectedDigits: String,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        let count = app.staticTexts["library.visible-count"]
        guard count.waitForExistence(timeout: timeout) else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if count.label.filter(\.isNumber) == expectedDigits { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return false
    }

    @MainActor
    private func waitForSearchResult(
        title: String,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        let result = renderedTrack(named: title, in: app)
        let count = app.staticTexts["library.visible-count"]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if result.exists, count.exists, count.label.filter(\.isNumber) == "1" {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return false
    }

    @MainActor
    private func renderedTrack(named title: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .tableRow)
            .matching(NSPredicate(format: "value CONTAINS %@", title))
            .firstMatch
    }

    private func residentMemoryMiB(processID: Int32) -> Double? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "rss=", "-p", String(processID)]
        process.standardOutput = output
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let text = String(
                    data: output.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                  ),
                  let kibibytes = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return nil
            }
            return kibibytes / 1_024
        } catch {
            return nil
        }
    }

    private func newestOngakuProcessID() -> Int32? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.ongaku.desktop")
            .max { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }?
            .processIdentifier
    }
}

private extension Duration {
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
