//
//  IOSScreenshotTests.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

// Launches the real iOS app with `--mock-tunnel` and photographs its screens,
// one scenario per launch (see MockTunnel.swift for the scenarios). Nothing is
// compared against a reference; the images are the output, and CI commits them
// to `swift/apple/screenshots/ios`.
//
// A run covers one appearance. macOS can ask for an appearance per launch, but
// a simulator's belongs to the device, so CI sets it with `simctl ui` and runs
// the suite once per appearance.

#if os(iOS)
  import CoreGraphics
  import XCTest

  @MainActor
  final class IOSScreenshotTests: XCTestCase {
    /// The settings tabs, by the label the app gives each and the name its
    /// images carry in the gallery.
    private static let settingsTabs = [
      (label: "General", name: "general"),
      (label: "Advanced", name: "advanced"),
      (label: "Diagnostic Logs", name: "logs"),
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

      // A resource from the mock's canned list, so the capture waits for the
      // list rather than for the spinner it replaces.
      try waitFor(app.staticTexts["Office network"], on: "session")
      deliver(app, as: "session", in: appearance)
    }

    // The three pushed detail screens, mirroring the Android gallery. Each takes
    // its own launch: photographed one after another, a screen carries whatever
    // the screens before it left behind, and the glass the bar's back button is
    // drawn on comes out a shade different for it.

    /// A DNS resource's detail screen.
    func testResourceDetails() throws {
      let appearance = try currentAppearance()
      let app = launchApp(scenario: "connected")
      defer { app.terminate() }

      try waitFor(app.staticTexts["Office network"], on: "session")
      try open(app.staticTexts["Demo GitLab"], in: app, name: "a DNS resource")
      try waitFor(app.staticTexts["ADDRESS"], on: "resource-details")
      deliver(app, as: "resource-details", in: appearance)
    }

    /// The Internet resource's detail screen.
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

    /// A connected device's detail screen.
    func testDeviceDetails() throws {
      let appearance = try currentAppearance()
      let app = launchApp(scenario: "connected")
      defer { app.terminate() }

      try waitFor(app.staticTexts["Office network"], on: "session")
      try open(app.staticTexts["Demo Device 1"], in: app, name: "a connected device")
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
        try selectTab(tab.label, in: app)
        deliver(app, as: "settings-\(tab.name)", in: appearance)
      }
    }

    /// Launches the app against the mock backend, presenting `scenario`.
    private func launchApp(scenario: String) -> XCUIApplication {
      let app = XCUIApplication()
      app.launchArguments = ["--mock-tunnel", "--mock-scenario", scenario]
      app.launch()

      return app
    }

    /// Taps `row` to push its detail screen, scrolling it into reach first.
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
    /// `swipeUp()` is a flick, so the list keeps travelling after the finger
    /// leaves it and comes to rest a little further along each time. Holding
    /// before the drag makes it a scroll rather than a flick, which stops where
    /// it is let go, so the screen underneath is the same on every run.
    private func scrollDown(in app: XCUIApplication) {
      let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
      let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))

      from.press(forDuration: 0.2, thenDragTo: to)
    }

    /// Taps the settings tab labelled `label`.
    ///
    /// SwiftUI has drawn the tab bar as different controls across releases, so
    /// the first control kind that answers to the label wins.
    private func selectTab(_ label: String, in app: XCUIApplication) throws {
      let candidates = [
        app.tabBars.buttons[label],
        app.buttons[label],
      ]

      guard let tab = candidates.first(where: { $0.waitForExistence(timeout: 5) }) else {
        throw IOSScreenshotError.tabNotFound(label)
      }

      tab.tap()
    }

    /// Pins that the app fills the simulated device.
    ///
    /// Without a launch screen iOS runs an app in compatibility mode, which is
    /// 320 points wide whatever the device, and photographs every screen at the
    /// wrong metrics.
    /// Blocks until `element` is on screen, so a capture cannot catch the
    /// spinner the app shows while it loads its state.
    private func waitFor(_ element: XCUIElement, on screen: String) throws {
      guard element.waitForExistence(timeout: 30) else {
        throw IOSScreenshotError.screenDidNotAppear(screen)
      }
    }

    /// The appearance the simulator was put in for this run.
    ///
    /// `XCUIDevice.appearance` is ignored when the tests run under `xcodebuild`,
    /// so CI sets the simulator's appearance itself and names it here.
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
  }
#endif
