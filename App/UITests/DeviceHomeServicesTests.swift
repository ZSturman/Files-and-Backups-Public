import XCTest

/// Physical-device flow against the live Home Services server, confined to a
/// disposable folder created by scripts/run-device-hs-tests.sh: add storage,
/// upload, browse, preview (download), rename, move, Trash and restore, and
/// the Backups tab's protection and snapshot browsing.
final class DeviceHomeServicesTests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func swipeAction(_ app: XCUIApplication, item: String, action: String) {
        let row = app.buttons["item-\(item)"].exists ? app.buttons["item-\(item)"] : app.cells.containing(.any, identifier: "item-\(item)").firstMatch
        XCTAssertTrue(waitRevealing(row, in: app, timeout: 20), "row \(item)")
        row.swipeLeft()
        let button = app.buttons[action]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "swipe action \(action)")
        button.tap()
    }

    func testHomeServicesFileManagementOnDevice() throws {
        guard let url = env["FB_HS_TEST_URL"], let token = env["FB_HS_TEST_TOKEN"], let root = env["FB_HS_TEST_ROOT"] else {
            throw XCTSkip("FB_HS_TEST_* not provided")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-FBUITestIsolatedState"]
        for (key, value) in ["FB_UITEST_PREFILL": "1", "FB_UITEST_PREFILL_KIND": "homeServices", "FB_UITEST_NAME": "Pi Home Services",
                             "FB_HS_TEST_URL": url, "FB_HS_TEST_TOKEN": token, "FB_HS_TEST_ROOT": root,
                             "FB_UITEST_FIXTURE_UPLOAD": "1", "FB_UITEST_FIXTURE_MB": env["FB_UITEST_FIXTURE_MB"] ?? "20"] {
            app.launchEnvironment[key] = value
        }
        app.launch()

        // Add Storage → Test Connection → capability summary → Save.
        XCTAssertTrue(app.buttons["addStorageEmpty"].waitForExistence(timeout: 10))
        app.buttons["addStorageEmpty"].tap()
        reveal(app.buttons["testConnection"], in: app).tap()
        XCTAssertTrue(waitRevealing(app.staticTexts["Connected"], in: app, timeout: 40), "connected")
        XCTAssertTrue(waitRevealing(app.staticTexts["Restorable Trash"], in: app, timeout: 10))
        capture(app, "hs-capabilities")
        app.buttons["saveConnection"].tap()

        // Upload the nested fixture (20 MB file included) through managed sessions.
        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Pi Home Services'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        // The Add Storage sheet may still be dismissing; retry the tap.
        for _ in 0..<5 where !app.buttons["browserAdd"].exists {
            if row.isHittable { row.tap() }
            _ = app.buttons["browserAdd"].waitForExistence(timeout: 6)
        }
        XCTAssertTrue(app.buttons["browserAdd"].waitForExistence(timeout: 30))
        app.buttons["browserAdd"].tap()
        app.buttons["uploadFixture"].tap()
        XCTAssertTrue(app.buttons["item-FB Acceptance"].waitForExistence(timeout: 180), "folder appears after upload completes")
        capture(app, "hs-browser-root")

        // Browse into the upload; open a file's detail screen and preview it.
        app.buttons["item-FB Acceptance"].tap()
        XCTAssertTrue(app.buttons["item-notes.txt"].waitForExistence(timeout: 20))
        app.buttons["item-notes.txt"].tap()
        XCTAssertTrue(app.buttons["openFile"].waitForExistence(timeout: 20), "file detail")
        app.buttons["openFile"].tap()
        let close = app.navigationBars.buttons["Done"]
        XCTAssertTrue(close.waitForExistence(timeout: 30), "preview of the downloaded file")
        sleep(1)
        capture(app, "hs-preview")
        close.tap()

        // Rename from the detail screen.
        XCTAssertTrue(app.buttons["renameFile"].waitForExistence(timeout: 10))
        app.buttons["renameFile"].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.clearAndType("renamed.txt")
        for _ in 0..<3 where app.alerts.firstMatch.exists {
            app.alerts.firstMatch.buttons["Rename"].tap()
            _ = app.alerts.firstMatch.waitForNonExistence(timeout: 3)
        }
        XCTAssertTrue(app.navigationBars["renamed.txt"].waitForExistence(timeout: 20), "renamed")
        capture(app, "hs-file-detail")

        // Move into "Day 1".
        app.buttons["moveFile"].tap()
        let acceptance = app.buttons["pick-FB Acceptance"]
        XCTAssertTrue(acceptance.waitForExistence(timeout: 20))
        acceptance.tap()
        let day1 = app.buttons["pick-Day 1"]
        XCTAssertTrue(day1.waitForExistence(timeout: 20))
        day1.tap()
        XCTAssertTrue(app.buttons["moveHere"].waitForExistence(timeout: 10))
        app.buttons["moveHere"].tap()
        XCTAssertTrue(app.buttons["item-Day 2"].waitForExistence(timeout: 20), "back in the folder")
        XCTAssertTrue(app.buttons["item-renamed.txt"].waitForNonExistence(timeout: 20), "moved out of this folder")
        app.buttons["item-Day 1"].tap()
        XCTAssertTrue(app.buttons["item-renamed.txt"].waitForExistence(timeout: 20), "moved into Day 1")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Move "Day 2" to the managed Trash, then restore it.
        swipeAction(app, item: "Day 2", action: "Trash")
        XCTAssertTrue(app.buttons["Move to Trash"].waitForExistence(timeout: 5))
        app.buttons["Move to Trash"].tap()
        XCTAssertTrue(app.buttons["item-Day 2"].waitForNonExistence(timeout: 20), "trashed")
        app.buttons["browserAdd"].tap()
        app.buttons["openTrash"].tap()
        let restore = app.buttons["restore-Day 2"]
        XCTAssertTrue(restore.waitForExistence(timeout: 20), "item listed in Trash")
        capture(app, "hs-trash")
        restore.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Restored'")).firstMatch.waitForExistence(timeout: 20))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["item-Day 2"].waitForExistence(timeout: 20), "restored")
        capture(app, "hs-after-restore")

        // Backups tab: server-side protection and snapshot browsing.
        tab(app, "Backups").tap()
        let browse = app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Browse snapshots'")).firstMatch
        XCTAssertTrue(waitRevealing(browse, in: app, timeout: 30), "snapshot browser link")
        capture(app, "hs-backups")
        browse.tap()
        XCTAssertTrue(app.navigationBars["Snapshots"].waitForExistence(timeout: 20))
        let firstSnapshot = app.cells.firstMatch
        XCTAssertTrue(firstSnapshot.waitForExistence(timeout: 30), "at least one snapshot")
        firstSnapshot.tap()
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 30), "snapshot contents listed")
        capture(app, "hs-snapshot-browser")
    }
}

extension XCUIElement {
    func clearAndType(_ text: String) {
        if let current = value as? String, !current.isEmpty {
            typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        typeText(text)
    }
}
