//
//  AppScreenshotTests.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

// Launches the real macOS app with `--mock-tunnel` and photographs its windows,
// one scenario and appearance per launch (see MockTunnel.swift for the
// scenarios). Nothing is compared against a reference; the images are the
// output, and CI commits them to `swift/apple/screenshots`.

#if os(macOS)
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

    /// The settings tabs, by the label the app gives each and the name its
    /// images carry in the gallery.
    private static let settingsTabs = [
      (label: "General", name: "general"),
      (label: "Advanced", name: "advanced"),
      (label: "Diagnostic Logs", name: "logs"),
    ]

    func testGrantVPN() throws {
      for appearance in Appearance.allCases {
        let app = launchApp(scenario: "grant-vpn", appearance: appearance)
        defer { app.terminate() }

        let window = try openWindow(named: "main", title: Self.mainWindowTitle, in: app)
        capture(window, as: "grant-vpn", in: appearance)
      }
    }

    /// The screen a signed-out user meets. macOS draws it as `FirstTimeView`, so
    /// the images keep that name while the scenario keeps the state's name.
    func testFirstTime() throws {
      for appearance in Appearance.allCases {
        let app = launchApp(scenario: "welcome", appearance: appearance)
        defer { app.terminate() }

        let window = try openWindow(named: "main", title: Self.mainWindowTitle, in: app)
        capture(window, as: "first-time", in: appearance)
      }
    }

    func testSettings() throws {
      for appearance in Appearance.allCases {
        let app = launchApp(scenario: "connected", appearance: appearance)
        defer { app.terminate() }

        let window = try openWindow(named: "settings", title: Self.settingsWindowTitle, in: app)

        // The window opens on the General tab, which is clicked anyway: the click
        // is what ends the editing session below.
        for tab in Self.settingsTabs {
          try selectTab(tab.label, in: window)
          endEditing(in: window)
          capture(window, as: "settings-\(tab.name)", in: appearance)
        }
      }
    }

    /// Launches the app against the mock backend, presenting `scenario` in `appearance`.
    ///
    /// The double-dashed arguments are the app's own flags; the single-dashed ones
    /// reach it through `UserDefaults`' argument domain instead, which overrides
    /// both settings for this process alone.
    ///
    /// `launchedBefore` keeps the app treating every launch as the first, so it
    /// does not close the main window shortly after startup the way it does for
    /// returning users. `AppleInterfaceStyle` is where AppKit reads the appearance
    /// from, so setting it draws the whole app dark, window chrome included. Light
    /// is the absence of the key, so nothing is passed for it.
    private func launchApp(scenario: String, appearance: Appearance) -> XCUIApplication {
      let app = XCUIApplication()
      app.launchArguments = [
        "--mock-tunnel", "--mock-scenario", scenario,
        "-launchedBefore", "NO",
      ]

      if appearance == .dark {
        app.launchArguments += ["-AppleInterfaceStyle", "Dark"]
      }

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

      guard let tab = candidates.first(where: { $0.waitForExistence(timeout: 5) }) else {
        throw AppScreenshotError.tabNotFound(label)
      }

      tab.click()
    }

    /// Ends the editing session AppKit opens in a window's first text field, so
    /// no insertion point blinks through a capture and the image is the same on
    /// every run.
    ///
    /// Nothing outside the app can reach its first responder, but Escape reaches
    /// the field editor, which is what holds the blinking caret.
    private func endEditing(in window: XCUIElement) {
      window.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    }
  }

  private enum AppScreenshotError: Error {
    case windowDidNotAppear(String)
    case tabNotFound(String)
  }
#endif
