//
//  ScreenshotTests.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

// Renders the macOS screens to PNGs under `swift/apple/screenshots` so their states can be
// reviewed without installing the client. Nothing is compared against a reference; the
// images are the output.
//
// The screens read their state from a `Store`, which is safe to build here because building
// one only wires it up: `Store.start()` is what talks to the system, and nothing calls it.
//
// iOS is not covered: `swift test` builds FirezoneKit for the host, so the views behind
// `#if os(iOS)` are not even compiled.

#if os(macOS) && DEBUG
  import AppKit
  import CoreGraphics
  import Foundation
  import ImageIO
  import SwiftUI
  import Testing
  import UniformTypeIdentifiers

  @testable import FirezoneKit

  private let colorSchemes: [ColorScheme] = [.light, .dark]

  @Suite("Screenshots", .requiresAppKit)
  struct ScreenshotTests {
    @Test("Grant VPN permission", arguments: colorSchemes)
    @MainActor
    func grantVPN(colorScheme: ColorScheme) throws {
      let window = try makeWindow(colorScheme) { _ in GrantVPNView() }
      try capture(window, as: "grant-vpn", colorScheme)
    }

    @Test("First run", arguments: colorSchemes)
    @MainActor
    func firstTime(colorScheme: ColorScheme) throws {
      let window = try makeWindow(colorScheme) { _ in FirstTimeView() }
      try capture(window, as: "first-time", colorScheme)
    }

    // One capture per tab, each of the whole window. SwiftUI draws the tab view itself
    // and offers no outside handle on its selection, so the test seeds the tab the
    // screen opens on instead of paging an existing window.
    @Test("Settings", arguments: colorSchemes)
    @MainActor
    func settings(colorScheme: ColorScheme) throws {
      let tabs: [(SettingsView.Tab, String)] = [
        (.general, "general"),
        (.advanced, "advanced"),
        (.logs, "logs"),
      ]

      for (tab, name) in tabs {
        let window = try makeWindow(colorScheme) { store in
          SettingsView(store: store, selectedTab: tab)
        }
        try capture(window, as: "settings-\(name)", colorScheme)
      }
    }

    /// Puts `content` in an off-screen window the size the app would use.
    ///
    /// The app's window scenes declare no size, so macOS opens them at the content's
    /// ideal size; the capture sizes its window the same way.
    ///
    /// `ImageRenderer` looks like the obvious tool and is not: a text field, a checkbox and
    /// a tab view are all AppKit underneath, and it draws each of them as the "not allowed"
    /// symbol. A real window hosting the view draws the controls the app actually shows.
    @MainActor
    private func makeWindow(
      _ colorScheme: ColorScheme,
      @ViewBuilder content: (Store) -> some View
    ) throws -> NSWindow {
      // Before any view exists: SwiftUI resolves its environment when the hosting view is
      // built, and the titlebar tab picker follows the application appearance, so setting
      // it later leaves a light capsule on the dark captures.
      let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
      NSApplication.shared.appearance = appearance

      let store = Store.mock()

      let view = NSHostingView(
        rootView:
          content(store)
          .environmentObject(store)
          .environmentObject(GlobalErrorHandler())
          .environment(\.colorScheme, colorScheme)
      )
      view.frame = CGRect(origin: .zero, size: view.fittingSize)

      let window = NSWindow(
        contentRect: view.frame,
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
      )
      window.appearance = appearance
      window.contentView = view
      view.layoutSubtreeIfNeeded()

      return window
    }

    /// Draws the window as it stands, titlebar included, and writes it out as a PNG.
    ///
    /// The frame view rather than the content view: current macOS shows the settings
    /// tabs in the titlebar, which a capture of the content alone cuts off.
    @MainActor
    private func capture(_ window: NSWindow, as name: String, _ colorScheme: ColorScheme) throws {
      // A window that never reaches the screen has no backing for the titlebar's
      // materials, which draw as a light block whatever the appearance says. Order it
      // front for the capture; the suite trait zeroes every window's alpha, so nothing
      // shows on the runner's screen.
      window.orderFrontRegardless()
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
      defer { window.orderOut(nil) }

      let view = try #require(
        window.contentView?.superview,
        "the window has no frame view"
      )

      guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
        throw ScreenshotError.cannotRender(name)
      }
      view.cacheDisplay(in: view.bounds, to: bitmap)

      let image = try #require(bitmap.cgImage, "\(name) rendered nothing")
      let url = try Self.outputDirectory()
        .appendingPathComponent("\(name)-\(colorScheme.suffix).png")

      guard
        let destination = CGImageDestinationCreateWithURL(
          url as CFURL,
          UTType.png.identifier as CFString,
          1,
          nil
        )
      else {
        throw ScreenshotError.cannotWrite(url)
      }

      CGImageDestinationAddImage(destination, image, nil)

      guard CGImageDestinationFinalize(destination) else {
        throw ScreenshotError.cannotWrite(url)
      }
    }

    /// `swift/apple/screenshots`, resolved from this file rather than the working directory
    /// so the images land in the same place however the tests are started.
    private static func outputDirectory() throws -> URL {
      let directory =
        URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // FirezoneKitTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // FirezoneKit
        .deletingLastPathComponent()  // apple
        .appendingPathComponent("screenshots")

      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

      return directory
    }
  }

  extension ColorScheme {
    fileprivate var suffix: String {
      self == .dark ? "dark" : "light"
    }
  }

  private enum ScreenshotError: Error {
    case cannotRender(String)
    case cannotWrite(URL)
  }
#endif
