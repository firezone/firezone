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
    /// Photographs `panels` as they stand to each other, and nothing between them.
    ///
    /// A menu and the submenu it opens are two windows that no one element covers, and
    /// what the screen holds around them is the shadow the OS draws, which is not the
    /// same twice. Each panel is photographed on its own and laid where it stands, so
    /// the picture is what the app drew; the ground it stands on, its border and its
    /// shadow are prepare-store-screenshots.py's. A panel drawn over another goes last.
    @discardableResult
    func deliver(_ panels: [XCUIElement], as name: String, in appearance: Appearance) -> Data {
      deliver(as: name, in: appearance) {
        let photographed = panels.compactMap { panel -> (image: CGImage, frame: CGRect)? in
          guard
            let image = panel.screenshot().image
              .cgImage(forProposedRect: nil, context: nil, hints: nil)
          else { return nil }

          return (image, panel.frame)
        }

        guard photographed.count == panels.count else { return Data() }

        return Self.composed(photographed)
      }
    }

    /// The panels on a transparent ground, as far apart as their frames are.
    private static func composed(_ panels: [(image: CGImage, frame: CGRect)]) -> Data {
      guard let first = panels.first else { return Data() }

      let bounds = panels.dropFirst().reduce(first.frame) { $0.union($1.frame) }
      // A screen can hold more pixels than it measures in points.
      let scale = CGFloat(first.image.width) / first.frame.width

      guard
        let context = CGContext(
          data: nil,
          width: Int(bounds.width * scale),
          height: Int(bounds.height * scale),
          bitsPerComponent: 8,
          bytesPerRow: 0,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
      else { return Data() }

      for panel in panels {
        // A context measures from the bottom of the picture and a frame from the top.
        context.draw(
          panel.image,
          in: CGRect(
            x: (panel.frame.minX - bounds.minX) * scale,
            y: (bounds.maxY - panel.frame.maxY) * scale,
            width: panel.frame.width * scale,
            height: panel.frame.height * scale
          )
        )
      }

      guard let composed = context.makeImage() else { return Data() }

      return NSBitmapImageRep(cgImage: composed).representation(using: .png, properties: [:])
        ?? Data()
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
