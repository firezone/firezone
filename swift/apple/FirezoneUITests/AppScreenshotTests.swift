//
//  AppScreenshotTests.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

// Photographs the real macOS app against the mocked backend, one scenario,
// appearance and window per launch. Nothing is compared against a reference: the
// images are the output, and CI commits them to `swift/apple/screenshots/macos`.

#if os(macOS)
  import AppKit
  import XCTest

  @MainActor
  final class AppScreenshotTests: XCTestCase {
    private static let appBundleID = "dev.firezone.firezone"
    private static let pointerParkingSpot = CGVector(dx: 0.5, dy: 1.2)

    private static let settingsTabs = [
      (label: "General", name: "general"),
      (label: "Advanced", name: "advanced"),
      (label: "Diagnostic Logs", name: "logs"),
    ]

    /// The scenarios describing the states of the certificate tab.
    private static let certificateScenarios = [
      "x509-filled",
      "x509-empty",
      "x509-unknown-attribute",
      "x509-unusable",
    ]

    private var brightness: [String: Double] = [:]

    func testGrantVPN() throws {
      for appearance in Appearance.allCases {
        let app = launchApp(scenario: "grant-vpn", appearance: appearance, window: "main")
        defer { app.terminate() }

        capture(try onlyWindow(of: app), as: "grant-vpn", in: appearance)
      }
    }

    /// macOS draws the signed-out screen as `FirstTimeView`, so the images keep
    /// that name while the scenario keeps the state's.
    func testFirstTime() throws {
      for appearance in Appearance.allCases {
        let app = launchApp(scenario: "welcome", appearance: appearance, window: "main")
        defer { app.terminate() }

        capture(try onlyWindow(of: app), as: "first-time", in: appearance)
      }
    }

    func testSettings() throws {
      for appearance in Appearance.allCases {
        let app = launchApp(scenario: "connected", appearance: appearance, window: "settings")
        defer { app.terminate() }

        let window = try onlyWindow(of: app)

        // General is already selected, and is clicked anyway so that every tab
        // arrives the same way.
        for tab in Self.settingsTabs {
          try selectTab(tab.label, in: window)
          capture(window, as: "settings-\(tab.name)", in: appearance)
        }
      }
    }

    /// The certificate tab, in each of the states a scenario describes.
    func testCertificate() throws {
      for scenario in Self.certificateScenarios {
        for appearance in Appearance.allCases {
          let app = launchApp(scenario: scenario, appearance: appearance, window: "settings")
          defer { app.terminate() }

          let window = try onlyWindow(of: app)
          try selectTab("X.509", in: window)
          capture(window, as: scenario, in: appearance)
        }
      }
    }

    private func launchApp(
      scenario: String, appearance: Appearance, window: String
    ) -> XCUIApplication {
      let app = XCUIApplication()
      app.launchArguments = [
        "--mock-tunnel", "--mock-scenario", scenario,
        "--mock-appearance", appearance.rawValue,
        "--mock-window", window,
      ]
      app.launch()

      return app
    }

    /// Photographs the window and pins that its dark capture is actually dark.
    ///
    /// Brightness rather than equality: an appearance the app ignored puts a light
    /// picture in the gallery under both names, and those two still differ by the
    /// odd pixel, so comparing them tells nothing.
    private func capture(_ window: XCUIElement, as name: String, in appearance: Appearance) {
      window.coordinate(withNormalizedOffset: Self.pointerParkingSpot).hover()

      // A capture takes whatever is on the screen inside the window's frame, and
      // a foreign window over it is photographed too. That has already put a
      // Finder dialog in the gallery.
      guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.appBundleID else {
        XCTFail("\(name) was not photographed: something else was in front of it")

        return
      }

      let image = deliver(window, as: name, in: appearance)
      brightness["\(name)-\(appearance.rawValue)"] = meanBrightness(of: image)

      guard
        let light = brightness["\(name)-light"],
        let dark = brightness["\(name)-dark"]
      else { return }

      print("Brightness of \(name): light \(light), dark \(dark)")

      XCTAssertLessThan(dark, light - 50, "\(name) is no darker in the dark appearance")
    }

    /// The mean brightness of a PNG, from every eighth pixel, on a 0 to 255 scale.
    private func meanBrightness(of image: Data) -> Double {
      guard let bitmap = NSBitmapImageRep(data: image) else { return 0 }

      var total = 0.0
      var samples = 0.0

      for y in stride(from: 0, to: bitmap.pixelsHigh, by: 8) {
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 8) {
          guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
            continue
          }

          total += (pixel.redComponent + pixel.greenComponent + pixel.blueComponent) / 3
          samples += 1
        }
      }

      return samples > 0 ? total / samples * 255 : 0
    }

    private func onlyWindow(of app: XCUIApplication) throws -> XCUIElement {
      let window = app.windows.firstMatch

      guard window.waitForExistence(timeout: 30) else {
        // Tells a window that never came from one that came up as something else.
        print("No window appeared; the app presents:\n\(app.debugDescription)")

        throw AppScreenshotError.windowDidNotAppear
      }

      return window
    }

    /// SwiftUI has drawn the macOS tab picker as different controls across
    /// releases, so the first kind that answers to `label` wins.
    private func selectTab(_ label: String, in window: XCUIElement) throws {
      let candidates = [
        window.tabs[label],
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
  }

  private enum AppScreenshotError: Error {
    case windowDidNotAppear
    case tabNotFound(String)
  }
#endif
