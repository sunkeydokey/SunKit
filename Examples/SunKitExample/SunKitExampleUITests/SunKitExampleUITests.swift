import XCTest

final class SunKitExampleUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["SunKit"].waitForExistence(timeout: 10))
    }

    override func tearDownWithError() throws {
        app = nil
    }

    @MainActor
    func testLaunchSmoke() throws {
        XCTAssertTrue(app.buttons["Query"].exists)
        XCTAssertTrue(app.buttons["Infinite Query"].exists)
        XCTAssertTrue(app.buttons["Dynamic Query"].exists)
    }

    @MainActor
    func testRapidNavigationPushPopAcrossQueryScreens() throws {
        let screens = [
            ("Query", "screen.query"),
            ("Infinite Query", "screen.infinite"),
            ("Dynamic Query", "screen.dynamic"),
            ("Enabled", "screen.enabled"),
            ("Parallel Queries", "screen.parallel"),
        ]

        for _ in 0..<3 {
            for screen in screens {
                open(screen.0, expecting: screen.1)
                backToRoot()
            }
        }
    }

    @MainActor
    func testInfiniteQueryRepeatedLoadMoreAndBackNavigation() throws {
        for _ in 0..<3 {
            open("Infinite Query", expecting: "screen.infinite")
            let loadMore = app.buttons["infinite.loadMoreButton"]

            for _ in 0..<3 {
                app.swipeUp()
                if loadMore.waitForExistence(timeout: 2), loadMore.isEnabled {
                    loadMore.tap()
                }
            }

            backToRoot()
        }
    }

    @MainActor
    func testDynamicQueryRapidInputChanges() throws {
        open("Dynamic Query", expecting: "screen.dynamic")
        let field = app.textFields["dynamic.usernameField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))

        for value in ["apple", "swift", "google", "", "microsoft"] {
            replaceText(in: field, with: value)
            XCTAssertTrue(element("screen.dynamic").waitForExistence(timeout: 2))
        }

        backToRoot()
    }

    @MainActor
    func testEnabledQueryInputToggle() throws {
        open("Enabled", expecting: "screen.enabled")
        let field = app.textFields["enabled.usernameField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))

        for value in ["apple", "", "swiftlang", "", "github"] {
            replaceText(in: field, with: value)
            XCTAssertTrue(element("screen.enabled").waitForExistence(timeout: 2))
        }

        backToRoot()
    }

    private func open(_ navigationTitle: String, expecting screenIdentifier: String) {
        let navigationButton = app.buttons[navigationTitle]
        XCTAssertTrue(navigationButton.waitForExistence(timeout: 5), "Missing \(navigationTitle)")
        navigationButton.tap()

        let screen = element(screenIdentifier)
        XCTAssertTrue(screen.waitForExistence(timeout: 10), "Missing \(screenIdentifier)")
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func backToRoot() {
        let rootBackButton = app.navigationBars.buttons["SunKit"]
        if rootBackButton.waitForExistence(timeout: 3) {
            rootBackButton.tap()
        } else if app.navigationBars.buttons.element(boundBy: 0).exists {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }

        XCTAssertTrue(app.staticTexts["SunKit"].waitForExistence(timeout: 5))
    }

    private func replaceText(in field: XCUIElement, with value: String) {
        field.tap()
        if let currentValue = field.value as? String, !currentValue.isEmpty {
            let deleteText = String(repeating: XCUIKeyboardKey.delete.rawValue, count: currentValue.count)
            field.typeText(deleteText)
        }
        if !value.isEmpty {
            field.typeText(value)
        }
    }
}
