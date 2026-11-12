import XCTest

/// Drives the signed Mac app: SMB Add Storage → upload → file detail rename,
/// and the Backups tab reading the standalone companion's real status.
final class MacAppTests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testBackupsTabShowsCompanionProtection() {
        let app = XCUIApplication()
        app.launchArguments = ["-FBUITestIsolatedState", "-FBInitialTab", "backups"]
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20), "app window")
        // macOS exposes SwiftUI Text as `value`.
        let protected = app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH 'Protected' OR value BEGINSWITH 'Overdue'")).firstMatch
        XCTAssertTrue(protected.waitForExistence(timeout: 20), "companion status is readable from the sandboxed app")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value == 'This Mac — Workspace/Projects'")).firstMatch.exists)
        capture(app, "mac-backups")
    }

    func testSMBUploadAndRenameOnMac() throws {
        guard let host = env["FB_SMB_TEST_HOST"], let root = env["FB_SMB_TEST_ROOT"] else { throw XCTSkip("SMB fixture not provided") }
        let app = XCUIApplication()
        app.launchArguments = ["-FBUITestIsolatedState"]
        for (key, value) in ["FB_UITEST_PREFILL": "1", "FB_UITEST_NAME": "Samba on Mac", "FB_SMB_TEST_HOST": host,
                             "FB_SMB_TEST_PORT": env["FB_SMB_TEST_PORT"] ?? "", "FB_SMB_TEST_SHARE": env["FB_SMB_TEST_SHARE"] ?? "",
                             "FB_SMB_TEST_USER": env["FB_SMB_TEST_USER"] ?? "", "FB_SMB_TEST_PASSWORD": env["FB_SMB_TEST_PASSWORD"] ?? "",
                             "FB_SMB_TEST_ROOT": root, "FB_UITEST_FIXTURE_UPLOAD": "1", "FB_UITEST_FIXTURE_MB": "8"] {
            app.launchEnvironment[key] = value
        }
        app.launch()
        app.activate()
        XCTAssertTrue(app.buttons["addStorageEmpty"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["addStorageEmpty"].isEnabled, "app is frontmost and interactive")
        app.buttons["addStorage"].click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "Add Storage sheet opens")
        XCTAssertTrue(sheet.buttons["testConnection"].waitForExistence(timeout: 10))
        sheet.buttons["testConnection"].click()
        XCTAssertTrue(sheet.staticTexts.matching(NSPredicate(format: "value == 'Connected' OR label == 'Connected'")).firstMatch.waitForExistence(timeout: 30), "capability summary")
        capture(app, "mac-add-storage")
        sheet.buttons["saveConnection"].click()

        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Samba on Mac'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()
        if !app.descendants(matching: .any)["browserAdd"].waitForExistence(timeout: 5) { row.doubleClick() }
        // Toolbar menus are menu buttons on macOS.
        let add = app.descendants(matching: .any)["browserAdd"]
        XCTAssertTrue(add.waitForExistence(timeout: 30))
        add.click()
        app.menuItems["uploadFixture"].click()
        let folder = app.buttons["item-FB Acceptance"]
        XCTAssertTrue(folder.waitForExistence(timeout: 120), "upload completes and the browser refreshes")
        capture(app, "mac-browser")
        folder.click()
        let notes = app.buttons["item-notes.txt"]
        XCTAssertTrue(notes.waitForExistence(timeout: 20))
        notes.click()
        XCTAssertTrue(app.buttons["renameFile"].waitForExistence(timeout: 20), "file detail")
        app.buttons["renameFile"].click()
        let field = app.sheets.textFields.firstMatch.exists ? app.sheets.textFields.firstMatch : app.dialogs.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("renamed.txt")
        let confirm = app.sheets.buttons["Rename"].exists ? app.sheets.buttons["Rename"] : app.dialogs.buttons["Rename"]
        confirm.click()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value == 'renamed.txt' OR label == 'renamed.txt'")).firstMatch.waitForExistence(timeout: 20), "renamed")
        capture(app, "mac-file-detail")
    }
}
