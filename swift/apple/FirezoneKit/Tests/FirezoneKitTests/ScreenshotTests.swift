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
      try render("grant-vpn", colorScheme, width: 600, height: 400) { _ in GrantVPNView() }
    }

    @Test("First run", arguments: colorSchemes)
    @MainActor
    func firstTime(colorScheme: ColorScheme) throws {
      try render("first-time", colorScheme, width: 600, height: 400) { _ in FirstTimeView() }
    }

    // A `TabView` is one of the views `ImageRenderer` cannot draw: it renders as the
    // "not allowed" symbol over the whole frame. Each tab is drawn on its own instead.
    @Test("General settings", arguments: colorSchemes)
    @MainActor
    func generalSettings(colorScheme: ColorScheme) throws {
      try render("settings-general", colorScheme, width: 800, height: 500) { store in
        SettingsView(store: store).generalTab
      }
    }

    @Test("Advanced settings", arguments: colorSchemes)
    @MainActor
    func advancedSettings(colorScheme: ColorScheme) throws {
      try render("settings-advanced", colorScheme, width: 800, height: 500) { store in
        SettingsView(store: store).advancedTab
      }
    }

    @Test("Diagnostic logs settings", arguments: colorSchemes)
    @MainActor
    func logsSettings(colorScheme: ColorScheme) throws {
      try render("settings-logs", colorScheme, width: 800, height: 500) { store in
        SettingsView(store: store).logsTab
      }
    }

    /// Renders `content` the way its window would and writes it out as a PNG.
    ///
    /// The renderer draws onto a transparent bitmap and a SwiftUI view brings no background
    /// of its own, so the window's has to be put back or the screenshot is controls floating
    /// on whatever the viewer happens to put behind them.
    @MainActor
    private func render(
      _ name: String,
      _ colorScheme: ColorScheme,
      width: CGFloat,
      height: CGFloat,
      @ViewBuilder content: (Store) -> some View
    ) throws {
      let store = Store.mock()

      let renderer = ImageRenderer(
        content:
          content(store)
          .environmentObject(store)
          .environmentObject(GlobalErrorHandler())
          .frame(width: width, height: height)
          .background(.background)
          .environment(\.colorScheme, colorScheme)
      )
      renderer.scale = 2
      renderer.isOpaque = true

      // SwiftUI reads the scheme from the environment, but anything drawing itself through
      // AppKit reads the appearance instead, and the two disagreeing shows up as light
      // controls on a dark window.
      var rendered: CGImage?
      appearance(for: colorScheme).performAsCurrentDrawingAppearance {
        rendered = renderer.cgImage
      }

      let image = try #require(rendered, "\(name) rendered nothing")
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

    @MainActor
    private func appearance(for colorScheme: ColorScheme) -> NSAppearance {
      let name: NSAppearance.Name = colorScheme == .dark ? .darkAqua : .aqua

      // Every macOS ships both of these.
      // swiftlint:disable:next force_unwrapping
      return NSAppearance(named: name)!
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
    case cannotWrite(URL)
  }
#endif
