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
      capture(app, as: "grant-vpn", in: appearance)
    }

    func testWelcome() throws {
      let appearance = try currentAppearance()
      let app = launchApp(scenario: "welcome")
      defer { app.terminate() }

      try waitFor(app.buttons["Sign in"], on: "welcome")
      capture(app, as: "welcome", in: appearance)
    }

    func testSession() throws {
      let appearance = try currentAppearance()
      let app = launchApp(scenario: "connected")
      defer { app.terminate() }

      // A resource from the mock's canned list, so the capture waits for the
      // list rather than for the spinner it replaces.
      try waitFor(app.staticTexts["Office network"], on: "session")
      capture(app, as: "session", in: appearance)
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
        capture(app, as: "settings-\(tab.name)", in: appearance)
      }
    }

    /// Launches the app against the mock backend, presenting `scenario`.
    private func launchApp(scenario: String) -> XCUIApplication {
      let app = XCUIApplication()
      app.launchArguments = ["--mock-tunnel", "--mock-scenario", scenario]
      app.launch()

      return app
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
      let name = ProcessInfo.processInfo.environment["SCREENSHOT_APPEARANCE"]

      return try XCTUnwrap(
        name.flatMap(Appearance.init(rawValue:)),
        "SCREENSHOT_APPEARANCE names no appearance: \(name ?? "unset")"
      )
    }
  }

  private enum IOSScreenshotError: Error {
    case screenDidNotAppear(String)
    case tabNotFound(String)
  }
#endif
