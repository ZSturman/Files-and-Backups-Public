import XCTest

/// Physical-device flow over Tailscale against the tailnet-only Samba
/// fixture (scripts/run-device-tests.sh). Covers navigation, Add Storage,
/// browse, folder upload, app backgrounding mid-transfer, termination and
/// relaunch mid-transfer, and keep-both on a repeat upload.
/// iPhone shows a bottom tab bar; iPadOS shows tabs as top-bar buttons.
func tab(_ app: XCUIApplication, _ name: String) -> XCUIElement {
    let bar = app.tabBars.buttons[name]
    return bar.exists ? bar : app.buttons[name].firstMatch
}

/// Swipes up until the element can be tapped (lazy Form rows on iPad).
@discardableResult
func reveal(_ element: XCUIElement, in app: XCUIApplication, attempts: Int = 8) -> XCUIElement {
    for _ in 0..<attempts where !(element.exists && element.isHittable) {
        app.swipeUp()
    }
    return element
}

/// Polls for an element that may appear in a lazy list below the fold,
/// swiping up between checks.
func waitRevealing(_ element: XCUIElement, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if element.exists { return true }
        app.swipeUp()
        sleep(1)
    }
    return element.exists
}

/// Taps a field until it has keyboard focus, then types.
func enter(_ field: XCUIElement, _ text: String) {
    for _ in 0..<3 {
        field.tap()
        if (field.value(forKey: "hasKeyboardFocus") as? Bool) == true { break }
        sleep(1)
    }
    field.typeText(text)
}

final class DeviceTransferTests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    private func makeApp(state: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-FBUITestState", state]
        app.launchEnvironment["FB_UITEST_FIXTURE_UPLOAD"] = "1"
        app.launchEnvironment["FB_UITEST_FIXTURE_MB"] = env["FB_UITEST_FIXTURE_MB"] ?? "48"
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func type(_ app: XCUIApplication, _ id: String, _ text: String) {
        let field = app.textFields[id].exists ? app.textFields[id] : app.secureTextFields[id]
        XCTAssertTrue(field.waitForExistence(timeout: 5), id)
        enter(field, text)
    }

    /// Waits for the first job row to reach Complete, resuming it if it
    /// paused because the connection was lost.
    private func waitForComplete(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.staticTexts["Complete"].exists { return true }
            let lost = app.staticTexts["Paused (connection lost)"]
            if lost.exists {
                lost.swipeLeft()
                if app.buttons["Resume"].waitForExistence(timeout: 3) { app.buttons["Resume"].tap() }
            }
            sleep(2)
        }
        return app.staticTexts["Complete"].exists
    }

    func testNavigationTabsAndEmptyStates() {
        let app = XCUIApplication()
        app.launchArguments = ["-FBUITestIsolatedState"]
        app.launch()
        XCTAssertTrue(app.buttons["addStorageEmpty"].waitForExistence(timeout: 10))
        tab(app, "Transfers").tap()
        XCTAssertTrue(app.staticTexts["No Transfers"].waitForExistence(timeout: 5))
        tab(app, "Backups").tap()
        XCTAssertTrue(app.staticTexts["What counts as protection"].waitForExistence(timeout: 5)
                      || app.staticTexts["WHAT COUNTS AS PROTECTION"].waitForExistence(timeout: 2))
        capture(app, "device-backups")
        tab(app, "Settings").tap()
        XCTAssertTrue(app.switches.firstMatch.waitForExistence(timeout: 5))
        capture(app, "device-settings")
        tab(app, "Files").tap()
        XCTAssertTrue(app.buttons["addStorageEmpty"].exists)
    }

    func testTailscaleUploadSurvivesBackgroundingAndRelaunch() throws {
        guard let host = env["FB_SMB_TEST_HOST"], let port = env["FB_SMB_TEST_PORT"], let share = env["FB_SMB_TEST_SHARE"],
              let user = env["FB_SMB_TEST_USER"], let password = env["FB_SMB_TEST_PASSWORD"], let root = env["FB_SMB_TEST_ROOT"] else {
            throw XCTSkip("device fixture variables not provided")
        }
        let state = "device-\(root)"
        var app = makeApp(state: state)
        // Prefill instead of typing (see AddStorageView.prefillForUITests).
        for (key, value) in ["FB_UITEST_PREFILL": "1", "FB_UITEST_NAME": "Mac via Tailscale", "FB_SMB_TEST_HOST": host,
                             "FB_SMB_TEST_PORT": port, "FB_SMB_TEST_SHARE": share, "FB_SMB_TEST_USER": user,
                             "FB_SMB_TEST_PASSWORD": password, "FB_SMB_TEST_ROOT": root] {
            app.launchEnvironment[key] = value
        }
        app.launch()

        // Add Storage over Tailscale.
        XCTAssertTrue(app.buttons["addStorageEmpty"].waitForExistence(timeout: 10))
        app.buttons["addStorageEmpty"].tap()
        reveal(app.buttons["testConnection"], in: app).tap()
        XCTAssertTrue(waitRevealing(app.staticTexts["Connected"], in: app, timeout: 40), "capability summary")
        capture(app, "device-capabilities")
        app.buttons["saveConnection"].tap()

        // Browse and upload (phase 1: background mid-transfer).
        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Mac via Tailscale'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.buttons["browserAdd"].waitForExistence(timeout: 20))
        app.buttons["browserAdd"].tap()
        app.buttons["uploadFixture"].tap()
        tab(app, "Transfers").tap()
        XCTAssertTrue(app.staticTexts["Transferring"].waitForExistence(timeout: 60), "upload started")
        sleep(3)
        capture(app, "device-transferring")

        XCUIDevice.shared.press(.home)
        sleep(20)
        app.activate()
        XCTAssertTrue(waitForComplete(app, timeout: 600), "upload completes after returning from background")
        capture(app, "device-complete-after-background")

        // Phase 2: repeat upload (keep-both) and terminate mid-transfer.
        tab(app, "Files").tap()
        if !app.buttons["browserAdd"].waitForExistence(timeout: 5) {
            app.buttons.containing(NSPredicate(format: "label CONTAINS 'Mac via Tailscale'")).firstMatch.tap()
        }
        XCTAssertTrue(app.buttons["browserAdd"].waitForExistence(timeout: 20))
        app.buttons["browserAdd"].tap()
        app.buttons["uploadFixture"].tap()
        tab(app, "Transfers").tap()
        XCTAssertTrue(app.staticTexts["Transferring"].waitForExistence(timeout: 60), "second upload started")
        sleep(4)
        app.terminate()

        app = makeApp(state: state)
        app.launch()
        _ = app.wait(for: .runningForeground, timeout: 10)
        tab(app, "Transfers").tap()
        XCTAssertTrue(waitForComplete(app, timeout: 600), "upload completes after relaunch")
        let completes = app.staticTexts.matching(identifier: "jobState").matching(NSPredicate(format: "label == 'Complete'"))
        let deadline = Date().addingTimeInterval(600)
        while completes.count < 2 && Date() < deadline { sleep(2) }
        XCTAssertEqual(completes.count, 2, "both jobs complete")
        capture(app, "device-both-complete")

        tab(app, "Files").tap()
        let destination = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Mac via Tailscale'")).firstMatch
        if destination.waitForExistence(timeout: 5) { destination.tap() }
        XCTAssertTrue(app.buttons["item-FB Acceptance (2)"].waitForExistence(timeout: 20)
                      || app.staticTexts["FB Acceptance (2)"].waitForExistence(timeout: 5), "keep-both folder")
        capture(app, "device-browser")
    }
}
