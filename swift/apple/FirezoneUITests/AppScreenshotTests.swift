//
//  AppScreenshotTests.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

// Photographs the real macOS app against the mocked backend, one scenario,
// appearance and window per launch. Nothing is compared against a reference: the
// images are the output, and CI commits them to `swift/apple/screenshots/macos/<release>`.

#if os(macOS)
  import AppKit
  import XCTest

  @MainActor
  final class AppScreenshotTests: XCTestCase {
    private static let appBundleID = "dev.firezone.firezone"
    private static let pointerParkingSpot = CGVector(dx: 0.5, dy: 1.2)

    /// Each tab, with a label only its own content carries: a tab that never
    /// opened leaves the one before it on screen, holding perfectly still, and
    /// the gallery takes that as a picture of the tab it asked for.
    private static let settingsTabs = [
      (label: "General", name: "general", showing: "Account Slug"),
      (label: "Advanced", name: "advanced", showing: "Auth Base URL"),
      (label: "Diagnostic Logs", name: "logs", showing: "Clear Log Directory"),
    ]

    /// The scenarios describing the states of the certificate tab.
    private static let certificateScenarios = [
      "x509-filled",
      "x509-unknown-attribute",
      "x509-expired",
    ]

    private var brightness: [String: Double] = [:]

    /// What each capture came out as, so a test can tell two of its own screens apart.
    private var captured: [String: Data] = [:]

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
          try waitFor(
            window.descendants(matching: .any)[tab.showing], on: "settings-\(tab.name)")
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
          try selectTab("Device Trust", in: window)
          capture(window, as: scenario, in: appearance)
        }
      }

      // Each scenario describes its own screen, so each should photograph as its
      // own picture. They collapse into one the moment the tab cannot read the
      // certificate it was handed, and every such screen says the same thing,
      // so the gallery looks plausible while carrying nothing.
      for appearance in Appearance.allCases {
        let images = Self.certificateScenarios.compactMap {
          captured["\($0)-\(appearance.rawValue)"]
        }

        XCTAssertEqual(
          Set(images).count,
          images.count,
          "two \(appearance.rawValue) certificate scenarios drew the same screen"
        )
      }
    }

    /// The menu bar menu with a resource hovered, so its submenu is open beside it.
    ///
    /// macOS 26 only: before it, the menu redraws its whole background a few steps
    /// differently on every run once the submenu is open, so there is no picture to keep.
    func testMenuWithResource() throws {
      try XCTSkipIf(
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 26,
        "the menu does not render repeatably before macOS 26"
      )

      for appearance in Appearance.allCases {
        let app = launchApp(scenario: "connected", appearance: appearance, window: "none")
        defer { app.terminate() }

        let menu = try openMenu(of: app)
        // The row and the submenu it opens share the title.
        let row = menu.menuItems["Engineering wiki"].firstMatch
        let menuFrame = menu.frame
        let rowFrame = row.frame

        // The pointer arrives from the side, because a row it highlights on its way
        // is redrawn a shade differently from its first draw, and it leaves through
        // the menu's padding rather than along the menu bar, where it would hand the
        // menu to whichever status item it passed. Offsets are taken from the menu:
        // an app with no window has no frame for a coordinate to be relative to.
        let corner = menu.coordinate(withNormalizedOffset: .zero)
        let rowY = rowFrame.midY - menuFrame.minY
        corner.withOffset(CGVector(dx: 4, dy: 4)).hover()
        corner.withOffset(CGVector(dx: -20, dy: 4)).hover()
        corner.withOffset(CGVector(dx: -20, dy: rowY)).hover()
        corner.withOffset(CGVector(dx: rowFrame.midX - menuFrame.minX, dy: rowY)).hover()

        let submenu = try openedSubmenu(of: row)

        capture([menuFrame, submenu.frame], as: "menu", in: appearance)
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

    /// Clicks the status item and hands back its open menu.
    ///
    /// The rows reach the accessibility tree before the menu is ever shown, so the
    /// store's resources are waited for first: a title set on a menu that is
    /// already showing is drawn a shade differently from one drawn as it opens.
    private func openMenu(of app: XCUIApplication) throws -> XCUIElement {
      let item = app.statusItems.firstMatch

      guard item.waitForExistence(timeout: 30) else {
        print("No status item appeared; the app presents:\n\(app.debugDescription)")

        throw AppScreenshotError.statusItemNotFound
      }

      let row = app.menuItems["Office network"]

      guard row.waitForExistence(timeout: 30) else {
        print("The menu never listed the resources; the app presents:\n\(app.debugDescription)")

        throw AppScreenshotError.menuDidNotOpen
      }

      item.click()

      // The menu is reported as the status item's child on some releases and as
      // the app's on others.
      let candidates = [item.menus.firstMatch, app.menus.firstMatch]

      guard let menu = candidates.first(where: { $0.waitForExistence(timeout: 10) }) else {
        print("The menu did not open; the app presents:\n\(app.debugDescription)")

        throw AppScreenshotError.menuDidNotOpen
      }

      return menu
    }

    /// Waits for the submenu the hovered `row` opens, and hands it back.
    ///
    /// The row's own, rather than the tallest menu that is not the menu: every resource
    /// carries a submenu and they are all in the tree before any of them is shown, so
    /// that handed back menus that were never on screen, whose frame the capture was
    /// then cropped to. Hittable rather than present, for the same reason.
    private func openedSubmenu(of row: XCUIElement) throws -> XCUIElement {
      let item = row.menuItems["Copy address"].firstMatch
      let deadline = Date().addingTimeInterval(10)

      while Date() < deadline {
        if item.exists, item.isHittable { return row.menus.firstMatch }

        Thread.sleep(forTimeInterval: 0.5)
      }

      print("The submenu did not open; the row presents:\n\(row.debugDescription)")

      throw AppScreenshotError.menuDidNotOpen
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

      record(deliver(window, as: name, in: appearance), as: name, in: appearance)
    }

    /// Photographs the region a screen covers when it is more than one element:
    /// a menu together with the submenu it has open.
    private func capture(_ frames: [CGRect], as name: String, in appearance: Appearance) {
      record(deliver(frames, as: name, in: appearance), as: name, in: appearance)
    }

    private func record(_ image: Data, as name: String, in appearance: Appearance) {
      brightness["\(name)-\(appearance.rawValue)"] = meanBrightness(of: image)
      captured["\(name)-\(appearance.rawValue)"] = image

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

      for _ in 0..<3 {
        tab.click()

        if tab.waitToBeSelected(timeout: 5) { return }
      }

      throw AppScreenshotError.tabNotSelected(label)
    }

    /// Blocks until `element` is on screen, so a capture cannot catch a tab that
    /// has not drawn its own content yet.
    private func waitFor(_ element: XCUIElement, on screen: String) throws {
      guard element.waitForExistence(timeout: 30) else {
        throw AppScreenshotError.screenDidNotAppear(screen)
      }
    }
  }

  private enum AppScreenshotError: Error {
    case windowDidNotAppear
    case statusItemNotFound
    case menuDidNotOpen
    case screenDidNotAppear(String)
    case tabNotFound(String)
    case tabNotSelected(String)
  }
#endif
