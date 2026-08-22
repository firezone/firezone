//
//  ScreenshotTests.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

// Renders the macOS screens to PNGs under `swift/apple/screenshots` so their states can be
// reviewed without installing the client. Nothing is compared against a reference; the
// images are the output.
//
// iOS is not covered: `swift test` builds FirezoneKit for the host, so the views behind
// `#if os(iOS)` are not even compiled here.

#if os(macOS) && DEBUG
  import CoreGraphics
  import Foundation
  import ImageIO
  import SwiftUI
  import Testing
  import UniformTypeIdentifiers

  @testable import FirezoneKit

  @Suite("Screenshots", .requiresAppKit)
  struct ScreenshotTests {
    @Test("Menu bar")
    @MainActor
    func menuBar() throws {
      try render("menu-bar", width: 400, height: 600) { MenuBarView() }
    }

    @Test("Grant VPN permission")
    @MainActor
    func grantVPN() throws {
      try render("grant-vpn", width: 600, height: 400) { GrantVPNView() }
    }

    @Test("First run")
    @MainActor
    func firstTime() throws {
      try render("first-time", width: 600, height: 400) { FirstTimeView() }
    }

    @Test("Settings")
    @MainActor
    func settings() throws {
      let store = Store.mock()
      try render("settings", width: 800, height: 600) { SettingsView(store: store) }
    }

    /// Renders `content` against the mock tunnel and writes it out as a PNG.
    @MainActor
    private func render(
      _ name: String,
      width: CGFloat,
      height: CGFloat,
      @ViewBuilder content: () -> some View
    ) throws {
      let renderer = ImageRenderer(
        content:
          content()
          .environmentObject(Store.mock())
          .environmentObject(GlobalErrorHandler())
          .frame(width: width, height: height)
      )
      renderer.scale = 2

      let image = try #require(renderer.cgImage, "\(name) rendered nothing")
      let url = try Self.outputDirectory().appendingPathComponent("\(name).png")

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

  private enum ScreenshotError: Error {
    case cannotWrite(URL)
  }
#endif
