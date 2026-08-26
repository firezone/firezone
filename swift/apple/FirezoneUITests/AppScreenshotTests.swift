//
//  AppScreenshotTests.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

// Launches the real macOS app with `--mock-tunnel` and photographs one of its
// windows, one scenario, appearance and window per launch (see MockTunnel.swift
// for the flags). Nothing is compared against a reference; the images are the
// output, and CI commits them to `swift/apple/screenshots/macos`.

#if os(macOS)
  import AppKit
  import XCTest

  @MainActor
  final class AppScreenshotTests: XCTestCase {
    /// `MAIN_APP_BUNDLE_ID` from `config.xcconfig`; it says which of the
    /// applications on the screen is the one under test.
    private static let appBundleID = "dev.firezone.firezone"

    /// A window the app can be launched showing, by the name `--mock-window`
    /// takes for it.
    private enum Window: String {
      case main
      case settings

      /// The title the window's scene declares in `FirezoneApp.swift`.
      var title: String {
        switch self {
        case .main:
          return "Welcome to Firezone"
        case .settings:
          // The titlebar shows the tab picker instead of drawing this, but it
          // stays the window's accessibility title.
          return "Settings"
        }
      }

      /// The prefix the app gives the window's identifier (see
      /// `AppView.WindowDefinition`).
      var identifierPrefix: String { "firezone-\(rawValue)" }
    }

    /// The radius of the arc a window's corner is drawn with.
    ///
    /// Measured off a capture: the outline meets the picture's edge eleven pixels
    /// in from either side, in both appearances.
    private static let windowCornerRadius = 12

    /// How far inside its own outline the window is taken, so that no edge pixel
    /// it shares with the desktop is left behind.
    ///
    /// Three is past the widest fringe measured on a capture, and what it costs is
    /// the outermost three pixels of a picture that is nine hundred wide.
    private static let windowEdgeBleed = 3

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
        let app = launchApp(scenario: "grant-vpn", appearance: appearance, showing: .main)
        defer { endApp(app) }

        let window = try launchedWindow(.main, in: app)
        capture(window, as: "grant-vpn", in: appearance)
      }
    }

    /// The screen a signed-out user meets. macOS draws it as `FirstTimeView`, so
    /// the images keep that name while the scenario keeps the state's name.
    func testFirstTime() throws {
      for appearance in Appearance.allCases {
        let app = launchApp(scenario: "welcome", appearance: appearance, showing: .main)
        defer { endApp(app) }

        let window = try launchedWindow(.main, in: app)
        capture(window, as: "first-time", in: appearance)
      }
    }

    func testSettings() throws {
      for appearance in Appearance.allCases {
        let app = launchApp(scenario: "connected", appearance: appearance, showing: .settings)
        defer { endApp(app) }

        let window = try launchedWindow(.settings, in: app)

        // The window opens on the General tab, which is clicked anyway so that
        // every tab arrives the same way.
        for tab in Self.settingsTabs {
          try selectTab(tab.label, in: window)
          capture(window, as: "settings-\(tab.name)", in: appearance)
        }
      }
    }

    /// Launches the app against the mock backend, presenting `scenario` in
    /// `appearance` with `window` open and in front.
    ///
    /// The double-dashed arguments are the app's own flags. `-launchedBefore NO`
    /// is not: it reaches `UserDefaults` through the argument domain, which keeps
    /// the app treating every launch as the first, so it does not close the main
    /// window shortly after startup the way it does for returning users.
    private func launchApp(
      scenario: String, appearance: Appearance, showing window: Window
    ) -> XCUIApplication {
      let app = XCUIApplication()
      app.launchArguments = [
        "--mock-tunnel", "--mock-scenario", scenario,
        "--mock-appearance", appearance.rawValue,
        "--mock-window", window.rawValue,
        "-launchedBefore", "NO",
      ]
      app.launch()

      return app
    }

    /// The window the app was launched showing, once it is on the screen.
    ///
    /// The identifier alternative covers a window whose title accessibility
    /// attribute is empty.
    private func launchedWindow(_ window: Window, in app: XCUIApplication) throws -> XCUIElement {
      let matcher = NSPredicate(
        format: "title == %@ OR identifier BEGINSWITH %@", window.title, window.identifierPrefix
      )
      let element = app.windows.matching(matcher).firstMatch

      guard element.waitForExistence(timeout: 30) else {
        throw AppScreenshotError.windowDidNotAppear(window.rawValue)
      }

      return element
    }

    /// Ends the app under test and blocks until its process is gone.
    ///
    /// `XCUIApplication.terminate()` returns before the process exits, so the
    /// next launch would otherwise overlap a copy still on its way out. Two
    /// processes under one bundle identifier put both their windows in the
    /// element tree, and the one behind shows through the corners of the one
    /// being photographed.
    private func endApp(_ app: XCUIApplication) {
      app.terminate()

      XCTAssertTrue(
        app.wait(for: .notRunning, timeout: 30),
        "The app under test outlived its test and never exited"
      )
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

      let image = deliver(window, as: name, in: appearance, encode: withoutDesktopAtCorners)
      brightness["\(name)-\(appearance.rawValue)"] = meanBrightness(of: image)

      guard
        let light = brightness["\(name)-light"],
        let dark = brightness["\(name)-dark"]
      else { return }

      print("Brightness of \(name): light \(light), dark \(dark)")

      XCTAssertLessThan(dark, light - 50, "\(name) is no darker in the dark appearance")
    }

    /// The capture with the desktop taken out from behind the window's corners.
    ///
    /// A window is drawn with rounded corners, so the pixels around each one hold
    /// a blend of the window and whatever the desktop shows behind it, and that
    /// blend is not always the same twice. Clearing them leaves the window whole:
    /// the picture keeps its full width and height, and only what was never the
    /// window becomes nothing.
    private func withoutDesktopAtCorners(_ screenshot: XCUIScreenshot) -> Data {
      let png = screenshot.pngRepresentation

      // The capture carries the display's own colour profile, and drawing it into a
      // context of a different one would convert every pixel in the picture. Its own
      // space is kept so that the only thing this changes is the corners.
      guard let source = NSBitmapImageRep(data: png),
        let full = source.cgImage,
        let context = CGContext(
          data: nil,
          width: full.width,
          height: full.height,
          bitsPerComponent: 8,
          bytesPerRow: 0,
          space: full.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
      else {
        return png
      }

      let bounds = CGRect(x: 0, y: 0, width: full.width, height: full.height)
      context.draw(full, in: bounds)

      // Insetting the outline while taking the same amount off its radius keeps
      // the arc centred where the window draws it, so the outline shrinks onto
      // itself rather than squaring off. What is left once that is taken out of
      // the picture's rectangle is the four corners plus a hairline along the
      // sides, which is the rest of the edge the window shares with the desktop.
      let bleed = CGFloat(Self.windowEdgeBleed)
      let radius = CGFloat(Self.windowCornerRadius) - bleed
      let outline = CGPath(
        roundedRect: bounds.insetBy(dx: bleed, dy: bleed),
        cornerWidth: radius,
        cornerHeight: radius,
        transform: nil
      )

      // Filling without antialiasing leaves every pixel either untouched or gone,
      // so none is left half cleared and still carrying a trace of the desktop.
      let corners = CGMutablePath()
      corners.addRect(bounds)
      corners.addPath(outline)

      context.setShouldAntialias(false)
      context.setBlendMode(.clear)
      context.addPath(corners)
      context.fillPath(using: .evenOdd)

      guard let cleared = context.makeImage(),
        let data = NSBitmapImageRep(cgImage: cleared)
          .representation(using: .png, properties: [:])
      else {
        return png
      }

      return data
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
  }

  private enum AppScreenshotError: Error {
    case windowDidNotAppear(String)
    case tabNotFound(String)
  }
#endif
