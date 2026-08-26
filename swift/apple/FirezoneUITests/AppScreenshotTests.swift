//
//  AppScreenshotTests.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

// Launches the real macOS app with `--mock-tunnel` and photographs its windows,
// one scenario, appearance and window per launch (see MockTunnel.swift for the
// flags). Nothing is compared against a reference; the images are the output,
// and CI commits them to `swift/apple/screenshots/macos`.

#if os(macOS)
  import AppKit
  import XCTest

  @MainActor
  final class AppScreenshotTests: XCTestCase {
    /// `MAIN_APP_BUNDLE_ID` from `config.xcconfig`; the runner needs it to tell
    /// the app under test from everything else that is running.
    private static let appBundleID = "dev.firezone.firezone"

    /// Where the pointer waits while a window is photographed.
    ///
    /// A control under the pointer draws itself hovered, and whether that has
    /// arrived by the time the shutter falls is a race: the settings tab that was
    /// clicked to reach a screen is left under the pointer, and its background is
    /// a shade darker in the runs where the hover landed first. Below the window
    /// there is nothing to hover, and what the pointer does outside the window
    /// never reaches a picture of the window.
    private static let pointerParkingSpot = CGVector(dx: 0.5, dy: 1.2)

    /// How bright each capture came out, by file name.
    private var brightness: [String: Double] = [:]

    /// The settings tabs, by the label the app gives each and the name its
    /// images carry in the gallery.
    private static let settingsTabs = [
      (label: "General", name: "general"),
      (label: "Advanced", name: "advanced"),
      (label: "Diagnostic Logs", name: "logs"),
    ]

    func testGrantVPN() throws {
      for appearance in Appearance.allCases {
        let app = launchApp(scenario: "grant-vpn", appearance: appearance, window: "main")
        defer { app.terminate() }

        let window = try onlyWindow(of: app)
        capture(window, as: "grant-vpn", in: appearance)
      }
    }

    /// The screen a signed-out user meets. macOS draws it as `FirstTimeView`, so
    /// the images keep that name while the scenario keeps the state's name.
    func testFirstTime() throws {
      for appearance in Appearance.allCases {
        let app = launchApp(scenario: "welcome", appearance: appearance, window: "main")
        defer { app.terminate() }

        let window = try onlyWindow(of: app)
        capture(window, as: "first-time", in: appearance)
      }
    }

    func testSettings() throws {
      for appearance in Appearance.allCases {
        let app = launchApp(scenario: "connected", appearance: appearance, window: "settings")
        defer { app.terminate() }

        let window = try onlyWindow(of: app)

        // The window opens on the General tab, which is clicked anyway so that
        // every tab arrives the same way.
        for tab in Self.settingsTabs {
          try selectTab(tab.label, in: window)
          capture(window, as: "settings-\(tab.name)", in: appearance)
        }
      }
    }

    /// Launches the app against the mock backend, presenting `scenario` in
    /// `appearance` with `window` on the screen.
    ///
    /// `--mock-window` picks which app starts: each presents one window scene and
    /// nothing else (see `main.swift`), so a launch has no other window to close,
    /// and none of the lifecycle a menu bar app carries runs here.
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

    /// Whether the app under test is the application in front.
    ///
    /// A capture takes whatever is on the screen inside the window's frame, so a
    /// window belonging to someone else that happens to sit over it is
    /// photographed along with it. That has already put a Finder dialog in the
    /// gallery. Nothing on screen says which process drew what, so the check is
    /// on who holds the front instead.
    private func inFront() -> Bool {
      NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.appBundleID
    }

    /// Who holds the front, for a failure message.
    private func describeFrontmost() -> String {
      guard let front = NSWorkspace.shared.frontmostApplication else {
        return "no application"
      }

      return front.bundleIdentifier ?? front.localizedName ?? "an unnamed application"
    }

    /// Photographs the window and pins that its dark capture is actually dark.
    ///
    /// Brightness rather than equality: an appearance the app ignored puts a light
    /// picture in the gallery under both names, and those two still differ by the
    /// odd pixel, so comparing them tells nothing. The measurements are printed so
    /// a run says which appearance it drew rather than leaving it to be inferred.
    private func capture(_ window: XCUIElement, as name: String, in appearance: Appearance) {
      window.coordinate(withNormalizedOffset: Self.pointerParkingSpot).hover()

      guard inFront() else {
        XCTFail("\(name) was not photographed: \(describeFrontmost()) was in front of it")

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

    /// The one window the app presents, once it is on the screen.
    private func onlyWindow(of app: XCUIApplication) throws -> XCUIElement {
      let window = app.windows.firstMatch

      guard window.waitForExistence(timeout: 30) else {
        // What the app does have on screen, which is the difference between a
        // window that never came and one that came up as something else.
        print("No window appeared; the app presents:\n\(app.debugDescription)")

        throw AppScreenshotError.windowDidNotAppear
      }

      return window
    }

    /// Clicks the settings tab labelled `label`.
    ///
    /// SwiftUI has drawn the macOS tab picker as different controls across
    /// releases, so the first control kind that answers to the label wins.
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
