//
//  IOSScreenshotTests.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

// Photographs the real iOS app against the mocked backend, one scenario per
// launch. Nothing is compared against a reference: the images are the output,
// and CI commits them to `swift/apple/screenshots/ios/<device>`.

#if os(iOS)
  import CoreGraphics
  import XCTest

  @MainActor
  final class IOSScreenshotTests: XCTestCase {
    /// Each tab, with a label only its own content carries: a tab that never
    /// opened leaves the one before it on screen, holding perfectly still, and
    /// the gallery takes that as a picture of the tab it asked for.
    private static let settingsTabs = [
      (label: "General", name: "general", showing: "Account Slug"),
      (label: "Advanced", name: "advanced", showing: "Auth Base URL"),
      (label: "Diagnostic Logs", name: "logs", showing: "Clear Log Directory"),
    ]

    /// A field every parsed certificate carries, so the Device Trust tab can be
    /// told from the one that was showing before it.
    private static let certificateAnchor = "Signing Algorithm"

    /// The scenarios describing the states of the certificate tab. Each image
    /// carries the name of the scenario it was taken from.
    private static let certificateScenarios = [
      "x509-filled",
      "x509-unknown-attribute",
      "x509-expired",
    ]

    func testGrantVPN() throws {
      let appearance = try currentAppearance()
      let app = launchApp(scenario: "grant-vpn")
      defer { app.terminate() }

      try waitFor(app.buttons["Grant VPN Permission"], on: "grant-vpn")
      deliver(app, as: "grant-vpn", in: appearance)
    }

    func testWelcome() throws {
      let appearance = try currentAppearance()
      let app = launchApp(scenario: "welcome")
      defer { app.terminate() }

      try waitFor(app.buttons["Sign in"], on: "welcome")
      deliver(app, as: "welcome", in: appearance)
    }

    func testSession() throws {
      let appearance = try currentAppearance()
      let app = launchApp(scenario: "connected")
      defer { app.terminate() }

      try waitFor(app.staticTexts["Office network"], on: "session")
      deliver(app, as: "session", in: appearance)
    }

    func testSessionScrolled() throws {
      let appearance = try currentAppearance()
      let app = launchApp(scenario: "connected")
      defer { app.terminate() }

      try waitFor(app.staticTexts["Office network"], on: "session-scrolled")
      scrollDown(in: app)
      deliver(app, as: "session-scrolled", in: appearance)
    }

    /// A running session, and the account menu that carries its heading and the
    /// control that ends it.
    func testSessionMenu() throws {
      let appearance = try currentAppearance()
      let app = launchApp(scenario: "connected")
      defer { app.terminate() }

      try waitFor(app.staticTexts["Office network"], on: "session-menu")
      try openAccountMenu(showing: "Sign out", in: app, on: "session-menu")
      deliver(app, as: "session-menu", in: appearance)
    }

    // Each detail screen takes its own launch: photographed one after another, a
    // screen carries what the ones before it left behind, and the glass the back
    // button is drawn on comes out a shade different for it.
    func testResourceDetails() throws {
      let appearance = try currentAppearance()
      let app = launchApp(scenario: "connected")
      defer { app.terminate() }

      try waitFor(app.staticTexts["Office network"], on: "session")
      try open(app.staticTexts["Engineering wiki"], in: app, name: "a DNS resource")
      try waitFor(app.staticTexts["ADDRESS"], on: "resource-details")
      deliver(app, as: "resource-details", in: appearance)
    }

    func testInternetResourceDetails() throws {
      let appearance = try currentAppearance()
      let app = launchApp(scenario: "connected")
      defer { app.terminate() }

      try waitFor(app.staticTexts["Office network"], on: "session")

      // The Internet resource's row carries the enabled/disabled marker in
      // front of its name, so the name alone has to match by containment.
      let internet = app.staticTexts.containing(
        NSPredicate(format: "label CONTAINS %@", "Internet Resource")
      ).firstMatch
      try open(internet, in: app, name: "the Internet resource")
      try waitFor(app.staticTexts["NAME"], on: "resource-details-internet")
      deliver(app, as: "resource-details-internet", in: appearance)
    }

    func testDeviceDetails() throws {
      let appearance = try currentAppearance()
      let app = launchApp(scenario: "connected")
      defer { app.terminate() }

      try waitFor(app.staticTexts["Office network"], on: "session")
      try open(app.staticTexts["bench-controller-01"], in: app, name: "a connected device")
      try waitFor(app.staticTexts["Tunnel IPs"], on: "device-details")
      deliver(app, as: "device-details", in: appearance)
    }

    func testSettings() throws {
      let appearance = try currentAppearance()
      let app = launchApp(scenario: "connected")
      defer { app.terminate() }

      try waitFor(app.buttons["Settings"], on: "settings")
      app.buttons["Settings"].tap()
      try waitFor(app.navigationBars["Settings"], on: "settings")

      for tab in Self.settingsTabs {
        try selectTab(tab.label, showing: tab.showing, in: app)
        deliver(app, as: "settings-\(tab.name)", in: appearance)
      }
    }

    /// The certificate tab, in each of the states a scenario describes.
    func testCertificate() throws {
      let appearance = try currentAppearance()

      for scenario in Self.certificateScenarios {
        let app = launchApp(scenario: scenario)
        defer { app.terminate() }

        try waitFor(app.buttons["Settings"], on: scenario)
        app.buttons["Settings"].tap()
        try waitFor(app.navigationBars["Settings"], on: scenario)
        try selectTab("Device Trust", showing: Self.certificateAnchor, in: app)
        deliver(app, as: scenario, in: appearance)
      }
    }

    private func launchApp(scenario: String) -> XCUIApplication {
      let app = XCUIApplication()
      app.launchArguments = ["--mock-tunnel", "--mock-scenario", scenario]
      app.launch()

      return app
    }

    private func open(_ row: XCUIElement, in app: XCUIApplication, name: String) throws {
      guard row.waitForExistence(timeout: 10) else {
        throw IOSScreenshotError.screenDidNotAppear(name)
      }

      for _ in 0..<3 where !row.isHittable {
        scrollDown(in: app)
      }

      row.tap()
    }

    /// Takes the list up by half the screen, and leaves it exactly there.
    ///
    /// `swipeUp()` is a flick: the list keeps travelling after the finger leaves
    /// it and comes to rest a little further along each time. Pressing before the
    /// drag makes it a scroll, but the drag still hands the list a velocity of its
    /// own, so the finger has to come to a stop before it lifts.
    private func scrollDown(in app: XCUIApplication) {
      let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
      let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))

      from.press(
        forDuration: 0.2,
        thenDragTo: to,
        withVelocity: .slow,
        thenHoldForDuration: 0.5
      )
    }

    /// Opens the tab named `label` and waits for `anchor`, which only its own
    /// content carries.
    ///
    /// SwiftUI has drawn the iOS tab bar as different controls across releases, so
    /// the first kind that answers to `label` wins. A press that lands while the
    /// sheet is still arriving is dropped without a word, so it is repeated until
    /// the content it asks for is on screen. The tab's own selected trait would be
    /// the cheaper signal, but these controls do not report it.
    private func selectTab(
      _ label: String, showing anchor: String, in app: XCUIApplication
    ) throws {
      let candidates = [
        app.tabBars.buttons[label],
        app.buttons[label],
      ]

      guard let tab = candidates.first(where: { $0.waitForExistence(timeout: 5) }) else {
        throw IOSScreenshotError.tabNotFound(label)
      }

      for _ in 0..<3 {
        tab.tap()

        if app.descendants(matching: .any)[anchor].waitForExistence(timeout: 10) { return }
      }

      throw IOSScreenshotError.tabDidNotOpen(label)
    }

    /// Opens the account menu and waits for `item`, one of the controls it holds.
    ///
    /// The menu itself is an icon carrying no text, so it is taken as the
    /// navigation bar button that is not Settings, and SwiftUI has drawn the items
    /// it holds as different controls across releases.
    private func openAccountMenu(
      showing item: String,
      in app: XCUIApplication,
      on screen: String
    ) throws {
      let account = app.navigationBars.buttons.matching(
        NSPredicate(format: "label != %@", "Settings")
      ).firstMatch

      try waitFor(account, on: screen)
      account.tap()
      try waitFor(app.descendants(matching: .any)[item], on: screen)
    }

    /// Blocks until `element` is on screen, so a capture cannot catch the spinner
    /// the app shows while it loads its state.
    private func waitFor(_ element: XCUIElement, on screen: String) throws {
      guard element.waitForExistence(timeout: 30) else {
        throw IOSScreenshotError.screenDidNotAppear(screen)
      }
    }

    /// The appearance the simulator was put in for this run.
    ///
    /// An appearance belongs to the device rather than to a launch, and
    /// `XCUIDevice.appearance` is ignored under `xcodebuild`, so CI sets it with
    /// `simctl ui` and runs the whole suite once per appearance.
    private func currentAppearance() throws -> Appearance {
      let name = try XCTUnwrap(
        ProcessInfo.processInfo.environment["SCREENSHOT_APPEARANCE"],
        "SCREENSHOT_APPEARANCE is not set"
      )

      return try XCTUnwrap(
        Appearance(rawValue: name),
        "SCREENSHOT_APPEARANCE names no appearance: \(name)"
      )
    }
  }

  private enum IOSScreenshotError: Error {
    case screenDidNotAppear(String)
    case tabNotFound(String)
    case tabDidNotOpen(String)
  }
#endif
