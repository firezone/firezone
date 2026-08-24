//
//  AppScreenshotTests.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

// Launches the real app with `--mock-tunnel` and photographs its windows, one
// scenario per launch (see MockTunnel.swift for the scenarios). Nothing is
// compared against a reference; the images are the output.
//
// The PNGs land in `SCREENSHOT_DIR` when that variable is set (CI passes it as
// `TEST_RUNNER_SCREENSHOT_DIR`, which xcodebuild forwards with the prefix
// stripped), and in `swift/apple/app-screenshots` otherwise.

import AppKit
import XCTest

@MainActor
final class AppScreenshotTests: XCTestCase {
  /// `MAIN_APP_BUNDLE_ID` from `config.xcconfig`; the runner needs it to hand
  /// URLs to the app under test.
  private static let appBundleID = "dev.firezone.firezone"

  /// The title the app's main window scene declares in `FirezoneApp.swift`.
  private static let mainWindowTitle = "Welcome to Firezone"

  /// The title the app's settings window scene declares in `FirezoneApp.swift`.
  /// The titlebar shows the tab picker instead of drawing it, but it stays the
  /// window's accessibility title.
  private static let settingsWindowTitle = "Settings"

  func testGrantVPN() throws {
    let app = launchApp(scenario: "grant-vpn")
    defer { app.terminate() }

    let window = try openWindow(named: "main", title: Self.mainWindowTitle, in: app)
    try capture(window, as: "grant-vpn")
  }

  func testWelcome() throws {
    let app = launchApp(scenario: "welcome")
    defer { app.terminate() }

    let window = try openWindow(named: "main", title: Self.mainWindowTitle, in: app)
    try capture(window, as: "welcome")
  }

  func testSettings() throws {
    let app = launchApp(scenario: "connected")
    defer { app.terminate() }

    let window = try openWindow(named: "settings", title: Self.settingsWindowTitle, in: app)

    // The window opens on the General tab, so capture it before paging.
    try capture(window, as: "settings-general")

    try selectTab("Advanced", in: window)
    try capture(window, as: "settings-advanced")

    try selectTab("Diagnostic Logs", in: window)
    try capture(window, as: "settings-logs")
  }

  /// Launches the app against the mock backend, presenting `scenario`.
  ///
  /// `-launchedBefore NO` reaches `UserDefaults` through the argument domain, so
  /// the app treats every launch as the first and does not close the main window
  /// shortly after startup the way it does for returning users.
  private func launchApp(scenario: String) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["--mock-tunnel", "-launchedBefore", "NO"]
    app.launchEnvironment["MOCK_SCENARIO"] = scenario
    app.launch()

    return app
  }

  /// Opens the app's `name` window by sending it the matching `firezone://` URL
  /// and returns the window element once it exists.
  ///
  /// The URL goes to the app under test by its bundle URL rather than through
  /// LaunchServices' scheme resolution, which could reach another Firezone on the
  /// machine. Opening a window the app already shows just orders it front.
  private func openWindow(
    named name: String, title: String, in app: XCUIApplication
  ) throws -> XCUIElement {
    let url = try XCTUnwrap(URL(string: "firezone://\(name)"))
    let runningApp = try XCTUnwrap(
      NSRunningApplication.runningApplications(withBundleIdentifier: Self.appBundleID).first,
      "the app under test is not running"
    )
    let applicationURL = try XCTUnwrap(runningApp.bundleURL)

    // The identifier alternative covers a window whose title accessibility
    // attribute is empty; the app assigns its scene windows identifiers with
    // these prefixes (see `AppView.WindowDefinition`).
    let matcher = NSPredicate(
      format: "title == %@ OR identifier BEGINSWITH %@", title, "firezone-\(name)"
    )
    let window = app.windows.matching(matcher).firstMatch

    // The first open can race the app still wiring up its scenes, so ask again
    // rather than spending the whole timeout on one attempt.
    for _ in 0..<3 {
      NSWorkspace.shared.open(
        [url],
        withApplicationAt: applicationURL,
        configuration: NSWorkspace.OpenConfiguration(),
        completionHandler: nil
      )

      if window.waitForExistence(timeout: 10) {
        return window
      }
    }

    throw AppScreenshotError.windowDidNotAppear(name)
  }

  /// Clicks the settings tab labelled `label`.
  ///
  /// SwiftUI has drawn the macOS tab picker as different controls across
  /// releases, so the first control kind that answers to the label wins.
  private func selectTab(_ label: String, in window: XCUIElement) throws {
    let candidates = [
      window.tabGroups.buttons[label],
      window.toolbars.buttons[label],
      window.radioButtons[label],
      window.buttons[label],
    ]

    guard let tab = candidates.first(where: { $0.waitForExistence(timeout: 2) }) else {
      throw AppScreenshotError.tabNotFound(label)
    }

    tab.click()
  }

  /// Photographs the window, attaches the image to the test, and writes it out
  /// as a PNG.
  ///
  /// The attachment is kept unconditionally so the image also lands in the
  /// result bundle, which survives even when writing the file does not.
  private func capture(_ window: XCUIElement, as name: String) throws {
    // XCUITest waits for quiescence before events, but a capture is not an
    // event, so give freshly presented content a moment to settle.
    Thread.sleep(forTimeInterval: 0.5)

    let screenshot = window.screenshot()

    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)

    let file = try Self.outputDirectory().appendingPathComponent("\(name).png")
    try screenshot.pngRepresentation.write(to: file)

    print("Screenshot \(name).png written to \(file.path)")
  }

  /// `SCREENSHOT_DIR` when set, or `swift/apple/app-screenshots` resolved from
  /// this file so local runs need no configuration.
  private static func outputDirectory() throws -> URL {
    let directory: URL

    if let path = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"], !path.isEmpty {
      directory = URL(fileURLWithPath: path, isDirectory: true)
    } else {
      directory =
        URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // FirezoneUITests
        .deletingLastPathComponent()  // apple
        .appendingPathComponent("app-screenshots")
    }

    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    return directory
  }
}

private enum AppScreenshotError: Error {
  case windowDidNotAppear(String)
  case tabNotFound(String)
}
