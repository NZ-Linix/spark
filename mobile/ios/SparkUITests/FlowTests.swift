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
  func testChatScrollAndDisclosure() throws {
    let relay = try XCTUnwrap(env["SPARK_SCROLL_FIXTURE"], "Run mobile/bridge/fixtures/scroll-relay.ts on a test simulator")
    let app = XCUIApplication()
    app.launchEnvironment["SPARK_SCROLL_FIXTURE"] = relay
    app.launch()
    let menu = app.buttons["Chats"]
    XCTAssertTrue(menu.waitForExistence(timeout: 10))
    menu.tap()
    let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Scroll regression")).firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    row.tap()

    let thought = app.buttons["Thought"]
    XCTAssertTrue(thought.waitForExistence(timeout: 10))
    let y = thought.frame.minY
    thought.tap()
    XCTAssertTrue(thought.isHittable)
    XCTAssertEqual(thought.frame.minY, y, accuracy: 24)
    shot(app, "scroll-expanded-thought")
    thought.tap()

    let tool = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "scroll-fixture.txt")).firstMatch
    XCTAssertTrue(tool.isHittable)
    let toolY = tool.frame.minY
    tool.tap()
    XCTAssertTrue(tool.isHittable)
    XCTAssertEqual(tool.frame.minY, toolY, accuracy: 24)
    shot(app, "scroll-expanded-tool")
    tool.tap()

    let composer = app.textFields["Message spark"]
    composer.tap()
    let keyboardTip = app.buttons["Continue"]
    if keyboardTip.waitForExistence(timeout: 2) { keyboardTip.tap() }
    let model = app.buttons["Model"]
    XCTAssertTrue(model.waitForExistence(timeout: 5))
    model.tap()
    let mcp = app.buttons["fixture-mcp"]
    XCTAssertTrue(mcp.waitForExistence(timeout: 6))
    XCTAssertEqual(mcp.value as? String, "On")
    mcp.tap()
    let off = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Off"), object: mcp)
    wait(for: [off], timeout: 5)
    shot(app, "scroll-mcp-off")
    app.buttons["Close"].firstMatch.tap()
    composer.tap()
    composer.typeText("A second message from the phone")
    app.buttons["Send"].tap()
    let reply = app.staticTexts["Visible follow-up reply."]
    XCTAssertTrue(reply.waitForExistence(timeout: 10))
    XCTAssertTrue(reply.isHittable)
    shot(app, "scroll-follow-up-visible")
  }

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
    // the chosen folder's files and terminal are there before the chat starts
    XCTAssertTrue(app.buttons["Files"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["Terminal"].exists)
    shot(app, "07b-folder-tools")
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
      // the effort slider sits at the top of the same sheet
      let effort = app.otherElements["Reasoning effort"]
      if effort.exists {
        effort.swipeRight()
        sleep(1)
        shot(app, "07e-effort")
      }
      app.buttons["Close"].firstMatch.tap()
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

    // the chat's folder: read a file, make one, save it, delete it
    app.buttons["Files"].tap()
    let readme = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'README.md'")).firstMatch
    XCTAssertTrue(readme.waitForExistence(timeout: 10))
    sleep(1)
    shot(app, "09b-files")
    readme.tap()
    XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 10))
    shot(app, "09c-file")
    app.navigationBars.firstMatch.buttons.firstMatch.tap()
    app.buttons["New"].tap()
    app.buttons["New File"].tap()
    let fileName = app.alerts.textFields.firstMatch
    XCTAssertTrue(fileName.waitForExistence(timeout: 5))
    fileName.typeText("notes.txt")
    app.alerts.buttons["Create"].tap()
    XCTAssertTrue(app.buttons["Save"].waitForExistence(timeout: 10))
    app.textViews.firstMatch.typeText("Written from the phone.\n")
    shot(app, "09d-editing")
    app.buttons["Save"].tap()
    XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Written from the phone."].exists)
    app.navigationBars.firstMatch.buttons.firstMatch.tap()
    let notes = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'notes.txt'")).firstMatch
    XCTAssertTrue(notes.waitForExistence(timeout: 10))
    notes.swipeLeft()
    app.buttons["Delete"].firstMatch.tap()
    app.alerts.buttons["Delete"].tap()
    XCTAssertTrue(notes.waitForNonExistence(timeout: 10))
    app.buttons["Close"].firstMatch.tap()
    sleep(1)

    // a terminal in the same folder: a command's output, and a cd that carries over
    app.buttons["Terminal"].tap()
    sleep(1)
    shot(app, "09e-terminal-open")
    let command = app.textFields["Command"]
    XCTAssertTrue(command.waitForExistence(timeout: 5))
    command.typeText("ls\n")
    XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'README.md'")).firstMatch.waitForExistence(timeout: 15))
    command.typeText("cd .. && pwd\n")
    XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label ENDSWITH '/root'")).firstMatch.waitForExistence(timeout: 15))
    sleep(1)
    shot(app, "09e-terminal")
    app.buttons["Close"].firstMatch.tap()
    sleep(1)

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

  /**
   * A chat sent without choosing a folder runs in one of its own: its files can be made and shared,
   * and deleting the chat from the sidebar takes the folder with it.
   */
  @MainActor
  func testChatWithoutFolder() throws {
    let relay = try XCTUnwrap(env["SPARK_RELAY"], "set TEST_RUNNER_SPARK_RELAY")
    let app = XCUIApplication()
    app.launchEnvironment["SPARK_RELAY"] = relay
    app.launch()
    XCTAssertTrue(app.buttons["Chats"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["Choose a folder"].waitForExistence(timeout: 10))

    let composer = app.textFields["Message spark"]
    composer.tap()
    composer.typeText("Reply with the single word: ready")
    app.buttons["Send"].tap()
    XCTAssertTrue(app.buttons["Files"].waitForExistence(timeout: 30))
    XCTAssertTrue(waitUntilIdle(app, timeout: 120))
    shot(app, "20-folderless-chat")

    app.buttons["Files"].tap()
    XCTAssertTrue(app.navigationBars.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'chat-'")).firstMatch.waitForExistence(timeout: 10))
    app.buttons["New"].tap()
    app.buttons["New File"].tap()
    let fileName = app.alerts.textFields.firstMatch
    XCTAssertTrue(fileName.waitForExistence(timeout: 5))
    fileName.typeText("hello.txt")
    app.alerts.buttons["Create"].tap()
    XCTAssertTrue(app.buttons["Save"].waitForExistence(timeout: 10))
    app.textViews.firstMatch.typeText("hi from the phone\n")
    app.buttons["Save"].tap()
    XCTAssertTrue(app.buttons["Share"].waitForExistence(timeout: 10))
    app.buttons["Share"].tap()
    // the system share sheet, with the file in it
    XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 15) || app.buttons["Copy"].waitForExistence(timeout: 5))
    sleep(1)
    shot(app, "21-share")
    app.swipeDown(velocity: .fast)
    sleep(1)
    app.navigationBars.firstMatch.buttons.firstMatch.tap()
    app.buttons["Close"].firstMatch.tap()
    sleep(1)

    app.buttons["Chats"].tap()
    let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'no folder'")).firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    shot(app, "22-sidebar-no-folder")
    row.press(forDuration: 1.0)
    app.buttons["Delete"].tap()
    XCTAssertTrue(row.waitForNonExistence(timeout: 10))
  }

  /**
   * A session open in spark in a terminal on the Mac opens read-only from the sidebar, with its saved
   * turns, and can be written once spark there closes. Needs spark running in a terminal on the Mac
   * with a session whose title starts with TEST_RUNNER_SPARK_HELD_TITLE; close it after the shot
   * named 30-terminal-session-read-only appears.
   */
  @MainActor
  func testTerminalSessionOpensReadOnly() throws {
    let relay = try XCTUnwrap(env["SPARK_RELAY"], "set TEST_RUNNER_SPARK_RELAY")
    let title = try XCTUnwrap(env["SPARK_HELD_TITLE"], "set TEST_RUNNER_SPARK_HELD_TITLE")
    let app = XCUIApplication()
    app.launchEnvironment["SPARK_RELAY"] = relay
    app.launch()
    let menu = app.buttons["Chats"]
    if !menu.waitForExistence(timeout: 8) {
      let code = try XCTUnwrap(env["SPARK_PAIR_CODE"], "set TEST_RUNNER_SPARK_PAIR_CODE")
      XCTAssertTrue(app.buttons["5"].waitForExistence(timeout: 5))
      for digit in code { app.buttons[String(digit)].tap() }
      XCTAssertTrue(menu.waitForExistence(timeout: 15))
    }
    menu.tap()
    let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 20))
    row.tap()

    let note = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Open in spark on'")).firstMatch
    XCTAssertTrue(note.waitForExistence(timeout: 10))
    XCTAssertFalse(app.textFields["Message spark"].isEnabled)
    sleep(1)
    shot(app, "30-terminal-session-read-only")

    // once spark in the terminal closes, the chat opens here
    XCTAssertTrue(note.waitForNonExistence(timeout: 120))
    let composer = app.textFields["Message spark"]
    XCTAssertTrue(composer.waitForExistence(timeout: 10))
    XCTAssertTrue(composer.isEnabled)
    sleep(1)
    shot(app, "31-terminal-session-taken-over")
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
