//
//  AppScreenshotTests.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

// Launches the real macOS app with `--mock-tunnel` and photographs its windows,
// one scenario and appearance per launch (see MockTunnel.swift for the
// scenarios). Nothing is compared against a reference; the images are the
// output, and CI commits them to `swift/apple/screenshots/macos`.

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
        let app = launchApp(scenario: "grant-vpn", appearance: appearance)
        defer { endApp(app) }

        let window = try openWindow(named: "main", title: Self.mainWindowTitle, in: app)
        capture(window, as: "grant-vpn", in: appearance)
      }
    }

    /// The screen a signed-out user meets. macOS draws it as `FirstTimeView`, so
    /// the images keep that name while the scenario keeps the state's name.
    func testFirstTime() throws {
      for appearance in Appearance.allCases {
        let app = launchApp(scenario: "welcome", appearance: appearance)
        defer { endApp(app) }

        let window = try openWindow(named: "main", title: Self.mainWindowTitle, in: app)
        capture(window, as: "first-time", in: appearance)
      }
    }

    func testSettings() throws {
      for appearance in Appearance.allCases {
        let app = launchApp(scenario: "connected", appearance: appearance)
        defer { endApp(app) }

        let window = try openWindow(named: "settings", title: Self.settingsWindowTitle, in: app)

        // The window opens on the General tab, which is clicked anyway so that
        // every tab arrives the same way.
        for tab in Self.settingsTabs {
          try selectTab(tab.label, in: window)
          capture(window, as: "settings-\(tab.name)", in: appearance)
        }
      }
    }

    /// Launches the app against the mock backend, presenting `scenario` in `appearance`.
    ///
    /// The double-dashed arguments are the app's own flags. `-launchedBefore NO`
    /// is not: it reaches `UserDefaults` through the argument domain, which keeps
    /// the app treating every launch as the first, so it does not close the main
    /// window shortly after startup the way it does for returning users.
    private func launchApp(scenario: String, appearance: Appearance) -> XCUIApplication {
      waitForNoRunningInstance()

      let app = XCUIApplication()
      app.launchArguments = [
        "--mock-tunnel", "--mock-scenario", scenario,
        "--mock-appearance", appearance.rawValue,
        "-launchedBefore", "NO",
      ]
      app.launch()

      return app
    }

    /// Ends the app under test and blocks until its process is gone.
    ///
    /// `XCUIApplication.terminate()` returns before the process exits, and the app
    /// defers its own termination until it has stopped the session, so the next
    /// launch would otherwise overlap a copy still on its way out. Two processes
    /// under one bundle identifier put both their windows in the element tree, and
    /// the one behind shows through the corners of the one being photographed.
    private func endApp(_ app: XCUIApplication) {
      app.terminate()
      waitForNoRunningInstance()
    }

    /// Blocks until no process carrying the app's bundle identifier is left,
    /// ending any that outstay their test.
    ///
    /// `XCUIApplication.terminate()` returns before the process is gone, and it
    /// only reaches the instance the test itself launched: one that a URL open
    /// started answers to nothing the test holds. A launch overlapping either
    /// puts two processes under one bundle identifier, and the element tree then
    /// holds both their windows, so a query can match a window that is about to
    /// disappear or that belongs to the wrong process.
    private func waitForNoRunningInstance() {
      let deadline = Date().addingTimeInterval(30)
      // Short, because the caller has already asked the app to quit.
      let askUntil = Date().addingTimeInterval(3)

      while Date() < deadline {
        let running = runningInstances()
        if running.isEmpty {
          return
        }

        for instance in running {
          if Date() < askUntil {
            instance.terminate()
          } else {
            instance.forceTerminate()
          }
        }

        Thread.sleep(forTimeInterval: 0.1)
      }

      XCTFail(
        "An instance of \(Self.appBundleID) outlived its test and never exited. "
          + "Saw \(describe(runningInstances()))"
      )
    }

    /// The app under test, once it is the only instance and has finished launching.
    ///
    /// `NSWorkspace.open` starts a second copy when LaunchServices does not yet
    /// count the app as running, and two processes under one bundle identifier
    /// put both their windows into the same element tree.
    ///
    /// This runs before any window is asked for, so the instance the test just
    /// launched is the one that started last: `waitForNoRunningInstance` left
    /// none behind, and anything older than the launch is a straggler from the
    /// iteration before. Photographing a straggler would deliver its appearance
    /// rather than the one under test.
    ///
    /// A straggler is killed rather than asked to leave, because the app answers
    /// `applicationShouldTerminate` with `.terminateLater` and can sit on the
    /// reply for longer than the deadline.
    private func singleRunningInstance() -> NSRunningApplication? {
      let deadline = Date().addingTimeInterval(30)
      let askUntil = Date().addingTimeInterval(5)
      var seen = describe([])

      while Date() < deadline {
        let running = runningInstances()

        seen = describe(running)

        if running.count == 1, let instance = running.first, instance.isFinishedLaunching {
          return instance
        }

        for straggler in running.dropLast() {
          if Date() < askUntil {
            straggler.terminate()
          } else {
            straggler.forceTerminate()
          }
        }

        Thread.sleep(forTimeInterval: 0.1)
      }

      XCTFail("The app under test never settled to one finished instance. Saw \(seen)")

      return nil
    }

    /// Every instance of the app under test, the one running longest first.
    private func runningInstances() -> [NSRunningApplication] {
      let running = NSRunningApplication.runningApplications(
        withBundleIdentifier: Self.appBundleID
      )

      return running.sorted { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }
    }

    /// How the instances of the app under test read in a failure message.
    private func describe(_ instances: [NSRunningApplication]) -> String {
      if instances.isEmpty {
        return "no running instance"
      }

      let described = instances.map {
        "pid \($0.processIdentifier), finished launching \($0.isFinishedLaunching)"
      }

      return described.joined(separator: "; ")
    }

    /// Photographs the window and pins that its dark capture is actually dark.
    ///
    /// Brightness rather than equality: an appearance the app ignored puts a light
    /// picture in the gallery under both names, and those two still differ by the
    /// odd pixel, so comparing them tells nothing. The measurements are printed so
    /// a run says which appearance it drew rather than leaving it to be inferred.
    private func capture(_ window: XCUIElement, as name: String, in appearance: Appearance) {
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
        singleRunningInstance(), "the app under test is not the only instance running"
      )
      let applicationURL = try XCTUnwrap(runningApp.bundleURL)

      // The identifier alternative covers a window whose title accessibility
      // attribute is empty; the app assigns its scene windows identifiers with
      // these prefixes (see `AppView.WindowDefinition`).
      let matcher = NSPredicate(
        format: "title == %@ OR identifier BEGINSWITH %@", title, "firezone-\(name)"
      )
      let window = app.windows.matching(matcher).firstMatch

      // Reusing the instance already under test is the whole point: a second
      // copy would put its own windows in the same element tree.
      let configuration = NSWorkspace.OpenConfiguration()
      configuration.createsNewApplicationInstance = false

      // The first open can race the app still wiring up its scenes, so ask again
      // rather than spending the whole timeout on one attempt. Each open is
      // waited out, because one still in flight when the next arrives is how a
      // second instance gets started.
      for _ in 0..<3 {
        let opened = expectation(description: "opened \(url)")
        NSWorkspace.shared.open(
          [url],
          withApplicationAt: applicationURL,
          configuration: configuration
        ) { _, _ in
          opened.fulfill()
        }
        wait(for: [opened], timeout: 30)

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
  }

  private enum AppScreenshotError: Error {
    case windowDidNotAppear(String)
    case tabNotFound(String)
  }
#endif
