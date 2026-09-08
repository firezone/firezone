//
//  ScreenshotDelivery.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

// How a captured screen leaves the UI-test runner.
//
// Xcode signs the UI-test runner with the App Sandbox whatever the target's
// settings say, so the runner cannot write the images itself. `testmanagerd`
// persists attachments into the result bundle regardless, and CI exports them
// from there into the committed gallery, so an attachment is the only delivery.

import XCTest

enum Appearance: String, CaseIterable {
  case light
  case dark
}

// Photographing is main-actor work in XCTest, and so is reading the image back.
@MainActor
extension XCTestCase {
  /// Photographs `element` once it holds still, delivers the image as
  /// `<name>-<appearance>.png`, and hands back its bytes.
  @discardableResult
  func deliver(
    _ element: XCUIElement,
    as name: String,
    in appearance: Appearance
  ) -> Data {
    deliver(as: name, in: appearance) { element.screenshot().pngRepresentation }
  }

  #if os(macOS)
    /// What the desktop is painted with: `screenshot-backdrop.png` is one pixel of
    /// it, and the store canvas is padded with the same value (`MAC_BACKGROUND` in
    /// prepare-store-screenshots.py), so a capture cropped by colour pads back out
    /// without a seam.
    private static let backdrop = 30
    /// A channel this far from the backdrop was drawn by the app. The step below it
    /// is the tail of a menu's shadow, which the margin keeps.
    private static let backdropTolerance = 2
    /// Kept around what the app drew, so the crop does not end wherever a shadow
    /// happens to fade past the tolerance.
    private static let desktopMargin: CGFloat = 32

    /// Photographs the desktop: what the app has drawn on it, cropped to the pixels
    /// that are not the backdrop, with the menu bar left out.
    ///
    /// A menu and the submenu it opens are two windows that no one element covers,
    /// and the accessibility frames describing them report a menu's window on some
    /// runs and its content rect on others, which moves a crop by the width of a
    /// shadow. What the app drew does not move.
    @discardableResult
    func deliverDesktop(as name: String, in appearance: Appearance) -> Data {
      deliver(as: name, in: appearance) {
        guard
          let screen = XCUIScreen.main.screenshot().image
            .cgImage(forProposedRect: nil, context: nil, hints: nil),
          let region = Self.drawnRegion(of: screen),
          let cropped = screen.cropping(to: region)
        else { return Data() }

        return NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:])
          ?? Data()
      }
    }

    /// The region of `screen` the app drew on, in the image's own coordinates.
    ///
    /// Only the desktop is searched: the menu bar carries a clock that no two
    /// captures agree on, and the Dock is not the app's either.
    private static func drawnRegion(of screen: CGImage) -> CGRect? {
      let width = screen.width
      let height = screen.height

      guard
        let desktop = NSScreen.main,
        let context = CGContext(
          data: nil, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )
      else { return nil }

      context.draw(screen, in: CGRect(x: 0, y: 0, width: width, height: height))

      guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }

      // Core Graphics drew the screen bottom up, which is how the screen measures
      // itself as well, so the searched rows and the visible frame need no flipping
      // between them. The bounds they produce are turned over further down.
      let scale = CGFloat(height) / desktop.frame.height
      let visible = desktop.visibleFrame
      let margin = Int((desktopMargin * scale).rounded())
      let firstRow = max(0, Int(visible.minY * scale))
      let lastRow = min(height, Int(visible.maxY * scale))
      let firstColumn = max(0, Int(visible.minX * scale))
      let lastColumn = min(width, Int(visible.maxX * scale))

      guard firstRow < lastRow, firstColumn < lastColumn else { return nil }

      var left = width
      var right = -1
      var top = height
      var bottom = -1

      for row in firstRow..<lastRow {
        for column in firstColumn..<lastColumn {
          let pixel = (row * width + column) * 4
          let furthest = max(
            abs(Int(pixels[pixel]) - backdrop),
            abs(Int(pixels[pixel + 1]) - backdrop),
            abs(Int(pixels[pixel + 2]) - backdrop)
          )

          guard furthest >= backdropTolerance else { continue }

          left = min(left, column)
          right = max(right, column)
          top = min(top, height - 1 - row)
          bottom = max(bottom, height - 1 - row)
        }
      }

      guard left <= right, top <= bottom else { return nil }

      let x = max(firstColumn, left - margin)
      let y = max(height - lastRow, top - margin)

      return CGRect(
        x: x,
        y: y,
        width: min(lastColumn - 1, right + margin) - x + 1,
        height: min(height - firstRow - 1, bottom + margin) - y + 1
      )
    }
  #endif

  /// Delivers what `capture` photographs once it holds still.
  private func deliver(
    as name: String,
    in appearance: Appearance,
    capture: () -> Data
  ) -> Data {
    let fileName = "\(name)-\(appearance.rawValue).png"
    let image = settledScreenshot(as: fileName, capture: capture)

    let attachment = XCTAttachment(data: image, uniformTypeIdentifier: "public.png")
    attachment.name = fileName
    attachment.lifetime = .keepAlways
    add(attachment)

    return image
  }

  /// The element as it looks once its captures agree.
  ///
  /// Freshly presented content is often still moving: the diagnostic logs tab
  /// spins while it adds up the log directory, and windows fade in. An image that
  /// catches a frame of that differs on every run, so a screen that will not hold
  /// still fails the test rather than being committed mid-motion.
  private func settledScreenshot(as fileName: String, capture: () -> Data) -> Data {
    let attempts = 20
    // Three in a row rather than two, a second apart rather than half: a control
    // drawn on a material can hold one appearance long enough to look settled and
    // then reach another, and a pair of captures close together cannot tell that
    // from a picture that has stopped moving.
    let required = 3
    var previous = capture()
    var sizes = [previous.count]
    var matches = 1

    for _ in 1...attempts {
      Thread.sleep(forTimeInterval: 1.0)

      // A dismissed banner leaves the next capture differing from the last,
      // which starts the count over.
      dismissBanner(before: fileName)

      let current = capture()
      sizes.append(current.count)

      if current == previous {
        matches += 1

        if matches >= required {
          report(fileName, heldStill: true, outOf: sizes)

          return current
        }
      } else {
        matches = 1
      }

      previous = current
    }

    report(fileName, heldStill: false, outOf: sizes)
    XCTFail("\(fileName) never held still, across \(attempts) captures")

    return previous
  }

  /// Swipes away a banner SpringBoard has laid over the app, and says so.
  ///
  /// The simulator posts its own: a "Ready for Apple Intelligence" notice once
  /// made it into a capture. A banner holds still for longer than the captures
  /// take to agree, so it has to be looked for rather than waited out.
  private func dismissBanner(before fileName: String) {
    #if os(iOS)
      let banner = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        .otherElements["Notification"]

      guard banner.exists else { return }

      print("banner: dismissing \"\(banner.label)\" before \(fileName)")
      banner.swipeUp()
      _ = banner.waitForNonExistence(timeout: 5)
    #endif
  }

  /// Says in the run's log how a capture came to rest: a screen that agreed at
  /// once differs from one that only just did, and the image shows neither.
  private func report(_ fileName: String, heldStill: Bool, outOf sizes: [Int]) {
    let outcome = heldStill ? "held still" : "never held still"
    let seen = Set(sizes).sorted()

    print("settle: \(fileName) \(outcome) across \(sizes.count) captures, sizes \(seen)")
  }
}
