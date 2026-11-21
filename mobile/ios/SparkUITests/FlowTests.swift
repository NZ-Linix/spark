import XCTest

/**
 * Walks the whole app against a running relay and bridge: pair, open the sidebar, pick a folder
 * with search, send a message, read the reply. Run with:
 *
 *   TEST_RUNNER_SPARK_RELAY=http://127.0.0.1:8799 TEST_RUNNER_SPARK_PAIR_CODE=<from spark pair> \
 *   TEST_RUNNER_SPARK_SHOTS=/tmp/shots xcodebuild test -scheme Spark -destination ...
 *
 * The bridge's folders should include one named demo-app.
 */
final class FlowTests: XCTestCase {
  private var env: [String: String] { ProcessInfo.processInfo.environment }

  @MainActor
  func testPairStartAndChat() throws {
    let relay = try XCTUnwrap(env["SPARK_RELAY"], "set TEST_RUNNER_SPARK_RELAY")
    let app = XCUIApplication()
    app.launchEnvironment["SPARK_RELAY"] = relay
    app.launch()

    let menu = app.buttons["Chats"]
    if !menu.waitForExistence(timeout: 8) {
      let code = try XCTUnwrap(env["SPARK_PAIR_CODE"], "set TEST_RUNNER_SPARK_PAIR_CODE")
      XCTAssertTrue(app.buttons["5"].waitForExistence(timeout: 5))
      sleep(1)
      shot(app, "01-welcome")
      for digit in code { app.buttons[String(digit)].tap() }
      XCTAssertTrue(menu.waitForExistence(timeout: 15))
    }
    sleep(1)
    shot(app, "02-new-chat")

    menu.tap()
    sleep(1)
    shot(app, "03-sidebar")
    app.swipeLeft()
    sleep(1)
    app.swipeRight()
    sleep(1)
    shot(app, "04-sidebar-swiped")

    app.buttons["New chat"].firstMatch.tap()
    let search = app.textFields.matching(NSPredicate(format: "placeholderValue BEGINSWITH 'Search in'")).firstMatch
    XCTAssertTrue(search.waitForExistence(timeout: 10))
    sleep(1)
    shot(app, "05-picker")
    search.tap()
    search.typeText("demo")
    let hit = app.buttons.matching(NSPredicate(format: "label CONTAINS '~/demo-app'")).firstMatch
    XCTAssertTrue(hit.waitForExistence(timeout: 10))
    sleep(1)
    shot(app, "06-search")
    hit.tap()
    let use = app.buttons["Use demo-app"]
    XCTAssertTrue(use.waitForExistence(timeout: 10))
    sleep(1)
    shot(app, "07-folder")
    use.tap()

    let composer = app.textFields["Message spark"]
    XCTAssertTrue(composer.waitForExistence(timeout: 10))
    sleep(1)
    shot(app, "07b-composer-open")
    // a tap anywhere off the keyboard puts it away
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
    sleep(1)
    shot(app, "07c-composer-rest")

    let model = app.buttons["Model"]
    if model.waitForExistence(timeout: 5) {
      model.tap()
      sleep(1)
      shot(app, "07d-models")
      app.buttons["Close"].firstMatch.tap()
      sleep(1)
    }
    let effort = app.buttons["Reasoning effort"]
    if effort.exists {
      effort.tap()
      sleep(1)
      shot(app, "07e-effort")
      app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
      sleep(1)
    }

    composer.tap()
    composer.typeText("Read README.md and tell me in one short paragraph what this project is, with one **bold** word.")
    app.buttons["Send"].tap()
    shot(app, "08a-sent")
    sleep(1)
    shot(app, "08b-started")
    sleep(3)
    shot(app, "08-working")
    XCTAssertTrue(waitUntilIdle(app, timeout: 120))
    app.swipeDown()
    sleep(1)
    shot(app, "09-reply")

    app.buttons["Chats"].tap()
    sleep(1)
    shot(app, "10-sidebar-with-chat")

    // long press a chat to rename it
    let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'README'")).firstMatch
    if row.waitForExistence(timeout: 5) {
      row.press(forDuration: 0.8)
      XCTAssertTrue(app.buttons["Rename"].waitForExistence(timeout: 5))
      sleep(1)
      shot(app, "10b-chat-menu")
      app.buttons["Rename"].tap()
      let title = app.alerts.textFields.firstMatch
      XCTAssertTrue(title.waitForExistence(timeout: 5))
      title.clearAndType("Renamed from the phone")
      app.alerts.buttons["Rename"].tap()
      XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Renamed from the phone'")).firstMatch.waitForExistence(timeout: 10))
      sleep(1)
      shot(app, "10c-renamed")
    }

    app.buttons["Settings"].tap()
    sleep(1)
    shot(app, "11-settings")
    app.buttons["Done"].tap()
    sleep(1)
    app.buttons["New chat"].firstMatch.tap()
    sleep(2)
    shot(app, "12-picker-recent")

    // into a folder and back up with the row at the top
    let demo = app.buttons.matching(NSPredicate(format: "label CONTAINS 'demo-app'")).element(boundBy: 1)
    if demo.waitForExistence(timeout: 5) {
      demo.tap()
      let up = app.buttons["folderUp"]
      XCTAssertTrue(up.waitForExistence(timeout: 10))
      sleep(1)
      shot(app, "13-picker-inside")
      up.tap()
      XCTAssertFalse(up.waitForExistence(timeout: 3))
    }
  }

  /**
   * The sidebar's three layouts, the shared providers, and a prompt written, renamed, and deleted.
   * Needs a relay with cloud sessions and a paired Mac whose spark profile has a provider named
   * local, which reaches the library on the Mac's first sync. Pairs with TEST_RUNNER_SPARK_PAIR_CODE
   * when the app isn't paired yet.
   */
  @MainActor
  func testSidebarLayoutsAndLibrary() throws {
    let relay = try XCTUnwrap(env["SPARK_RELAY"], "set TEST_RUNNER_SPARK_RELAY")
    let app = XCUIApplication()
    app.launchEnvironment["SPARK_RELAY"] = relay
    app.launch()

    let menu = app.buttons["Chats"]
    if !menu.waitForExistence(timeout: 8) {
      let code = try XCTUnwrap(env["SPARK_PAIR_CODE"], "set TEST_RUNNER_SPARK_PAIR_CODE")
      for digit in code { app.buttons[String(digit)].tap() }
      XCTAssertTrue(menu.waitForExistence(timeout: 15))
    }

    // A: a heading for the cloud and one for the Mac
    menu.tap()
    XCTAssertTrue(app.otherElements["section-cloud"].waitForExistence(timeout: 10) || app.staticTexts["Cloud"].waitForExistence(timeout: 1))
    sleep(3)
    shot(app, "20-sidebar-sections")

    for (style, name) in [("Switch", "21-sidebar-switch"), ("Merged", "22-sidebar-merged")] {
      app.buttons["Settings"].tap()
      let picker = app.segmentedControls["sidebarStyle"]
      XCTAssertTrue(picker.waitForExistence(timeout: 5))
      picker.buttons[style].tap()
      app.buttons["Done"].tap()
      sleep(2)
      shot(app, name)
    }

    app.buttons["Settings"].tap()
    app.segmentedControls["sidebarStyle"].buttons["Sections"].tap()
    let providers = app.buttons["cloudProviders"]
    XCTAssertTrue(providers.waitForExistence(timeout: 5))
    providers.tap()
    XCTAssertTrue(app.buttons["provider-local"].waitForExistence(timeout: 30))
    sleep(1)
    shot(app, "23-providers")

    app.buttons["provider-local"].tap()
    XCTAssertTrue(app.buttons["saveProvider"].waitForExistence(timeout: 5))
    sleep(1)
    shot(app, "24-edit-provider")
    let model = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'model-'")).firstMatch
    XCTAssertTrue(model.waitForExistence(timeout: 5))
    model.tap()
    XCTAssertTrue(app.textFields["modelContext"].waitForExistence(timeout: 5))
    sleep(1)
    shot(app, "25-edit-model")
    // back from the model, close the provider, back to Settings
    app.buttons.matching(NSPredicate(format: "identifier == 'BackButton' AND label == 'Local Test'")).firstMatch.tap()
    let close = app.buttons["Cancel"]
    XCTAssertTrue(close.waitForExistence(timeout: 5))
    close.tap()
    sleep(1)
    app.buttons.matching(NSPredicate(format: "identifier == 'BackButton' AND label == 'Settings'")).firstMatch.tap()

    // a prompt: write it, rename it, delete it
    let prompts = app.buttons["prompts"]
    XCTAssertTrue(prompts.waitForExistence(timeout: 5))
    prompts.tap()
    let add = app.buttons["addPrompt"]
    XCTAssertTrue(add.waitForExistence(timeout: 10))
    add.tap()
    let name = app.textFields["promptName"]
    XCTAssertTrue(name.waitForExistence(timeout: 5))
    name.typeText("Reviewer")
    app.textViews["promptText"].tap()
    app.textViews["promptText"].typeText("You review code carefully and answer in short sentences.")
    sleep(1)
    shot(app, "26-prompt-editor")
    app.buttons["savePrompt"].tap()
    let saved = app.buttons["prompt-Reviewer"]
    XCTAssertTrue(saved.waitForExistence(timeout: 15))
    sleep(1)
    shot(app, "27-prompts")

    saved.press(forDuration: 0.8)
    app.buttons["Rename"].tap()
    let field = app.alerts.textFields.firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    field.clearAndType("Careful reviewer")
    app.alerts.buttons["Rename"].tap()
    let renamed = app.buttons["prompt-Careful reviewer"]
    XCTAssertTrue(renamed.waitForExistence(timeout: 15))

    renamed.press(forDuration: 0.8)
    app.buttons["Delete"].tap()
    app.buttons["Delete"].firstMatch.tap()
    XCTAssertFalse(renamed.waitForExistence(timeout: 5))
    sleep(1)
    shot(app, "28-prompt-deleted")
  }

  /** the stop button goes away once spark is done */
  private func waitUntilIdle(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
    let stop = app.buttons["Stop"]
    let end = Date().addingTimeInterval(timeout)
    sleep(2)
    while Date() < end {
      if !stop.exists { return true }
      sleep(1)
    }
    return false
  }

  private func shot(_ app: XCUIApplication, _ name: String) {
    let png = app.screenshot().pngRepresentation
    if let dir = env["SPARK_SHOTS"] {
      try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
      try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }
    let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
    a.name = name
    a.lifetime = .keepAlways
    add(a)
  }
}

extension XCUIElement {
  /** replaces whatever the field holds */
  func clearAndType(_ text: String) {
    tap()
    if let current = value as? String, !current.isEmpty {
      typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
    }
    typeText(text)
  }
}
