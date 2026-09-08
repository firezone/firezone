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

      // Read as the screenshot holds them, rather than drawn into a bitmap of our
      // own: that copy is colour managed, and the speckle it leaves across the flat
      // backdrop reads as something the app drew, which grew the crop to take in
      // noise from the far side of the screen.
      guard
        let desktop = NSScreen.main,
        screen.bitsPerPixel == 32,
        let provider = screen.dataProvider,
        let bytes = provider.data
      else { return nil }

      let pixels = bytes as Data
      // Which of the four bytes the colours start at: the alpha leads a `First`
      // layout, and a little-endian order turns the whole pixel around.
      let leadingAlpha: [CGImageAlphaInfo] = [.first, .premultipliedFirst, .noneSkipFirst]
      let alphaLeads = leadingAlpha.contains(screen.alphaInfo)
      let reversed = screen.bitmapInfo.contains(.byteOrder32Little)
      let colours = alphaLeads != reversed ? 1 : 0
      let rowBytes = screen.bytesPerRow

      let scale = CGFloat(height) / desktop.frame.height
      let visible = desktop.visibleFrame
      let margin = Int((desktopMargin * scale).rounded())
      // The screen measures from the bottom and the image from the top.
      let firstRow = max(0, height - Int(visible.maxY * scale))
      let lastRow = min(height, height - Int(visible.minY * scale))
      let firstColumn = max(0, Int(visible.minX * scale))
      let lastColumn = min(width, Int(visible.maxX * scale))

      guard firstRow < lastRow, firstColumn < lastColumn else { return nil }

      return pixels.withUnsafeBytes { bytes -> CGRect? in
        var left = width
        var right = -1
        var top = height
        var bottom = -1

        for row in firstRow..<lastRow {
          for column in firstColumn..<lastColumn {
            let pixel = row * rowBytes + column * 4 + colours
            let furthest = max(
              abs(Int(bytes[pixel]) - backdrop),
              abs(Int(bytes[pixel + 1]) - backdrop),
              abs(Int(bytes[pixel + 2]) - backdrop)
            )

            guard furthest >= backdropTolerance else { continue }

            left = min(left, column)
            right = max(right, column)
            top = min(top, row)
            bottom = max(bottom, row)
          }
        }

        guard left <= right, top <= bottom else { return nil }

        let x = max(firstColumn, left - margin)
        let y = max(firstRow, top - margin)

        return CGRect(
          x: x,
          y: y,
          width: min(lastColumn - 1, right + margin) - x + 1,
          height: min(lastRow - 1, bottom + margin) - y + 1
        )
      }
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
