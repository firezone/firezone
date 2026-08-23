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
  import CoreGraphics
  import Foundation
  import ImageIO
  import SwiftUI
  import Testing
  import UniformTypeIdentifiers

  @testable import FirezoneKit

  @Suite("Screenshots", .requiresAppKit)
  struct ScreenshotTests {
    @Test("Grant VPN permission")
    @MainActor
    func grantVPN() throws {
      try render("grant-vpn", width: 600, height: 400) { _ in GrantVPNView() }
    }

    @Test("First run")
    @MainActor
    func firstTime() throws {
      try render("first-time", width: 600, height: 400) { _ in FirstTimeView() }
    }

    @Test("Settings")
    @MainActor
    func settings() throws {
      try render("settings", width: 800, height: 600) { store in SettingsView(store: store) }
    }

    // A menu bar view is the *content* of a menu, so these render its items stacked rather
    // than the macOS menu that normally frames them. A submenu is a row here, not a list:
    // the resources and the connected devices appear as the rows that open them.
    @Test("Menu bar before sign in")
    @MainActor
    func menuBarContents() throws {
      try render("menu-bar-contents", width: 400, height: 350) { _ in
        VStack(alignment: .leading) { MenuBarView() }
      }
    }

    @Test("Menu bar when signed in")
    @MainActor
    func menuBarSignedIn() throws {
      try render("menu-bar-signed-in", width: 400, height: 600, store: .mockConnected()) { _ in
        VStack(alignment: .leading) { MenuBarView() }
      }
    }

    /// Renders `content` against the mock tunnel and writes it out as a PNG.
    @MainActor
    private func render(
      _ name: String,
      width: CGFloat,
      height: CGFloat,
      store: Store = .mock(),
      @ViewBuilder content: (Store) -> some View
    ) throws {
      let renderer = ImageRenderer(
        content:
          content(store)
          .environmentObject(store)
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
