import XCTest

/// Simulator flow against the disposable Samba fixture (the simulator shares
/// the Mac's network, so 127.0.0.1:4445 reaches the container). Credentials
/// come from FB_SMB_TEST_* passed as TEST_RUNNER_ env vars; skipped otherwise.
final class AddStorageFlowTests: XCTestCase {
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testEmptyStateOffersAddStorageAndSaveNeedsRequiredFields() {
        let app = XCUIApplication()
        app.launchArguments = ["-FBUITestIsolatedState"]
        app.launch()
        XCTAssertTrue(app.buttons["addStorageEmpty"].waitForExistence(timeout: 10))
        capture(app, "01-first-launch")
        app.buttons["addStorageEmpty"].tap()
        XCTAssertTrue(app.textFields["connectionName"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["saveConnection"].isEnabled, "save stays disabled until required fields are filled")
    }

    func testAddSMBShareBrowseAndUploadFixture() throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["FB_SMB_TEST_HOST"], let port = env["FB_SMB_TEST_PORT"], let share = env["FB_SMB_TEST_SHARE"],
              let user = env["FB_SMB_TEST_USER"], let password = env["FB_SMB_TEST_PASSWORD"], let root = env["FB_SMB_TEST_ROOT"] else {
            throw XCTSkip("SMB fixture variables not provided")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-FBUITestIsolatedState"]
        app.launchEnvironment["FB_UITEST_FIXTURE_UPLOAD"] = "1"
        app.launch()
        app.buttons["addStorageEmpty"].tap()

        func type(_ id: String, _ text: String) {
            let field = app.textFields[id].exists ? app.textFields[id] : app.secureTextFields[id]
            XCTAssertTrue(field.waitForExistence(timeout: 5), id)
            field.tap()
            field.typeText(text)
        }
        type("connectionName", "Samba Fixture")
        type("smbHost", host)
        type("smbPort", port)
        type("smbUser", user)
        type("smbPassword", password)
        type("smbShare", share)
        type("smbRoot", root)

        reveal(app.buttons["testConnection"], in: app).tap()
        XCTAssertTrue(waitRevealing(app.staticTexts["Connected"], in: app, timeout: 30), "capability summary after Test Connection")
        capture(app, "02-add-storage-capabilities")
        app.buttons["saveConnection"].tap()

        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Samba Fixture'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()

        app.buttons["browserAdd"].tap()
        app.buttons["uploadFixture"].tap()

        tab(app, "Transfers").tap()
        let complete = app.staticTexts["Complete"]
        XCTAssertTrue(complete.waitForExistence(timeout: 60), "upload completes")
        capture(app, "04-transfers")

        tab(app, "Files").tap()
        XCTAssertTrue(app.buttons["item-FB Acceptance"].waitForExistence(timeout: 10) || app.staticTexts["FB Acceptance"].waitForExistence(timeout: 10))
        capture(app, "03-browser")

        // Rename inside the uploaded folder (regression: dialog state race).
        let folder = app.buttons["item-FB Acceptance"]
        XCTAssertTrue(folder.waitForExistence(timeout: 10))
        folder.tap()
        let notes = app.buttons["item-notes.txt"]
        XCTAssertTrue(notes.waitForExistence(timeout: 20))
        notes.swipeLeft()
        XCTAssertTrue(app.buttons["Rename"].waitForExistence(timeout: 5))
        app.buttons["Rename"].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.clearAndType("renamed.txt")
        app.alerts.buttons["Rename"].tap()
        XCTAssertTrue(app.buttons["item-renamed.txt"].waitForExistence(timeout: 20), "rename applied")
    }
}
