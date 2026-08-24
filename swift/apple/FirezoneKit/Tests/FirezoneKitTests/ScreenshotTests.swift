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

  /// The title the app's main window scene declares in `FirezoneApp.swift`. The
  /// settings captures stay untitled: that window's titlebar shows the tab picker
  /// and no title text, in the app as in the captures.
  private let mainWindowTitle = "Welcome to Firezone"

  /// The window size, measured from the app. Neither scene declares a size and
  /// both hold greedy content, so AppKit derives the same default for each on
  /// every open; captures pin the measured result so the renders match what the
  /// app shows.
  private let windowSize = CGSize(width: 900, height: 450)

  @Suite("Screenshots", .requiresAppKit)
  struct ScreenshotTests {
    @Test("Grant VPN permission", arguments: colorSchemes)
    @MainActor
    func grantVPN(colorScheme: ColorScheme) throws {
      let window = try makeWindow(
        colorScheme,
        title: mainWindowTitle,
        size: windowSize
      ) { _ in GrantVPNView() }
      try capture(window, as: "grant-vpn", colorScheme)
    }

    @Test("First run", arguments: colorSchemes)
    @MainActor
    func firstTime(colorScheme: ColorScheme) throws {
      let window = try makeWindow(
        colorScheme,
        title: mainWindowTitle,
        size: windowSize
      ) { _ in FirstTimeView() }
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
        let window = try makeWindow(colorScheme, size: windowSize) { store in
          SettingsView(store: store, selectedTab: tab)
        }
        try capture(window, as: "settings-\(name)", colorScheme)
      }
    }

    /// Puts `content` in an off-screen window of exactly `size`, the window size
    /// measured from the app. The app's scenes declare no size and AppKit derives
    /// one at runtime; deriving it here collapses the Spacer-heavy screens to
    /// their minimum instead, so the captures pin the measured result.
    ///
    /// `ImageRenderer` looks like the obvious tool and is not: a text field, a checkbox and
    /// a tab view are all AppKit underneath, and it draws each of them as the "not allowed"
    /// symbol. A real window hosting the view draws the controls the app actually shows.
    @MainActor
    private func makeWindow(
      _ colorScheme: ColorScheme,
      title: String? = nil,
      size: CGSize,
      @ViewBuilder content: (Store) -> some View
    ) throws -> NSWindow {
      // Before any view exists: SwiftUI resolves its environment when the hosting view is
      // built, and the titlebar tab picker follows the application appearance, so setting
      // it later leaves a light capsule on the dark captures.
      let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
      NSApplication.shared.appearance = appearance

      let store = Store.mock()

      let controller = NSHostingController(
        rootView:
          content(store)
          .environmentObject(store)
          .environmentObject(GlobalErrorHandler())
          .environment(\.colorScheme, colorScheme)
          .environment(\.logoTextImage, Self.wordmark(colorScheme))
      )
      // Nothing may derive the window size from the content: the Spacer-heavy
      // screens have no meaningful ideal size, and a derived window collapses
      // toward the content's minimum.
      controller.sizingOptions = []

      let window = ScreenshotWindow(contentViewController: controller)
      window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
      window.appearance = appearance
      window.identifier = .screenshotCapture
      if let title {
        window.title = title
      }
      // The measured sizes include the titlebar, so the frame is set rather than
      // the content size.
      window.setFrame(NSRect(origin: .zero, size: size), display: false)
      controller.view.layoutSubtreeIfNeeded()

      return window
    }

    /// The wordmark for the captures, from the SVG originals this test target
    /// ships: the views' own catalogue lookup resolves nothing under `swift test`,
    /// where the catalogue is copied verbatim instead of compiled.
    private static func wordmark(_ colorScheme: ColorScheme) -> Image? {
      let name = colorScheme == .dark ? "LogoTextDark" : "LogoText"

      guard
        let url = Bundle.module.url(forResource: name, withExtension: "svg"),
        let nsImage = NSImage(contentsOf: url)
      else {
        return nil
      }

      return Image(nsImage: nsImage)
    }

    /// Photographs the window, titlebar included, and writes it out as a PNG.
    ///
    /// The picture is taken by `screencapture` where possible: the titlebar's glass
    /// materials are composited by the window server alone, so this process's own
    /// `cacheDisplay` draws them as a flat block, visibly so in dark mode. When the
    /// window server's picture cannot be had (screen recording may be denied on a CI
    /// runner), `cacheDisplay` serves as the fallback so the suite still produces
    /// images. A log line per image says which path produced it.
    @MainActor
    private func capture(_ window: NSWindow, as name: String, _ colorScheme: ColorScheme) throws {
      // A window that never reaches the screen has no backing for the titlebar's
      // materials, which draw as a light block whatever the appearance says. Order it
      // front for the capture; its identifier exempts it from the suite trait's
      // alpha-zeroing, because the server does not composite a transparent window and
      // the titlebar's glass needs that compositing to render in the right appearance.
      window.orderFrontRegardless()

      // The glass also blends in whatever lies behind the window, so a solid backdrop
      // in the appearance's own tone keeps the runner's desktop out of the captures.
      let backdrop = makeBackdropWindow(behind: window, colorScheme)
      defer {
        backdrop.orderOut(nil)
        window.orderOut(nil)
      }

      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

      // After the runloop turn: SwiftUI's focus engine claims the first field while
      // the window settles, so clearing focus any earlier does not stick.
      _ = window.makeFirstResponder(nil)
      window.display()

      let fileName = "\(name)-\(colorScheme.suffix).png"
      let url = try Self.outputDirectory().appendingPathComponent(fileName)

      if let image = windowServerImage(of: window) {
        print("Screenshot \(fileName): captured by screencapture")
        try write(image, to: url)
        return
      }

      print("Screenshot \(fileName): falling back to cacheDisplay")
      try write(cacheDisplayImage(of: window, name: name), to: url)
    }

    /// A solid, borderless window covering the screen behind `window`, black in dark
    /// mode and white in light mode, so the glass blends against something stable.
    @MainActor
    private func makeBackdropWindow(
      behind window: NSWindow,
      _ colorScheme: ColorScheme
    ) -> NSWindow {
      let backdrop = NSWindow(
        contentRect: window.screen?.frame ?? window.frame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
      )
      backdrop.backgroundColor = colorScheme == .dark ? .black : .white
      // The identifier keeps the suite trait from zeroing the backdrop's alpha;
      // a transparent backdrop would hide nothing.
      backdrop.identifier = .screenshotCapture
      backdrop.order(.below, relativeTo: window.windowNumber)

      return backdrop
    }

    /// The window as the window server composited it, or `nil` when `screencapture`
    /// cannot deliver that, with the reason on standard output either way.
    ///
    /// The image covers exactly the window (`-l`) without its shadow (`-o`), at
    /// physical pixels; the caller saves it as returned, without resampling.
    @MainActor
    private func windowServerImage(of window: NSWindow) -> CGImage? {
      let file = FileManager.default.temporaryDirectory
        .appendingPathComponent("screenshot-\(UUID().uuidString).png")
      defer { try? FileManager.default.removeItem(at: file) }

      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
      process.arguments = ["-x", "-o", "-l", String(window.windowNumber), file.path]

      do {
        try process.run()
      } catch {
        print("screencapture did not start: \(error)")
        return nil
      }

      // A bounded wait: stuck on a permission prompt, the tool would otherwise
      // hang the suite.
      let deadline = Date(timeIntervalSinceNow: 10)
      while process.isRunning && Date() < deadline {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
      }

      guard !process.isRunning else {
        process.terminate()
        print("screencapture did not finish in time")
        return nil
      }

      guard process.terminationStatus == 0 else {
        print("screencapture exited with \(process.terminationStatus)")
        return nil
      }

      guard FileManager.default.fileExists(atPath: file.path) else {
        print("screencapture produced no file")
        return nil
      }

      // Decoded from memory: an image source reading the file decodes lazily, and
      // the file is gone by the time the caller writes the pixels out.
      guard
        let data = try? Data(contentsOf: file),
        let source = CGImageSourceCreateWithData(data as CFData, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
      else {
        print("screencapture produced an unreadable image")
        return nil
      }

      return image
    }

    /// The window as this process draws it, which renders the titlebar's materials
    /// as flat fills. The frame view rather than the content view: current macOS
    /// shows the settings tabs in the titlebar, which a capture of the content alone
    /// cuts off.
    @MainActor
    private func cacheDisplayImage(of window: NSWindow, name: String) throws -> CGImage {
      let view = try #require(
        window.contentView?.superview,
        "the window has no frame view"
      )

      guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
        throw ScreenshotError.cannotRender(name)
      }
      view.cacheDisplay(in: view.bounds, to: bitmap)

      return try #require(bitmap.cgImage, "\(name) rendered nothing")
    }

    /// Writes the image out as a PNG at `url`.
    private func write(_ image: CGImage, to url: URL) throws {
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

  /// Reports itself as key and main so AppKit draws active chrome: colored traffic
  /// lights and undimmed titlebar controls. The test process is a background app
  /// whose windows never really gain key status, so every capture would otherwise
  /// show the grayed-out chrome of an inactive window.
  private final class ScreenshotWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
  }

  private enum ScreenshotError: Error {
    case cannotRender(String)
    case cannotWrite(URL)
  }
#endif
