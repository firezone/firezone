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

/// The appearances the gallery holds a capture of.
enum Appearance: String, CaseIterable {
  case light
  case dark
}

// Photographing is main-actor work in XCTest, and so is everything that reads
// the resulting image.
@MainActor
extension XCTestCase {
  /// Photographs `element` once it holds still, delivers the image as
  /// `<name>-<appearance>.png`, and hands back its bytes.
  @discardableResult
  func deliver(
    _ element: XCUIElement,
    as name: String,
    in appearance: Appearance,
    encode: (XCUIScreenshot) -> Data = { $0.pngRepresentation }
  ) -> Data {
    let fileName = "\(name)-\(appearance.rawValue).png"
    let image = encode(settledScreenshot(of: element, as: fileName))

    let attachment = XCTAttachment(data: image, uniformTypeIdentifier: "public.png")
    attachment.name = fileName
    attachment.lifetime = .keepAlways
    add(attachment)

    return image
  }

  /// The element as it looks once two captures in a row agree.
  ///
  /// Freshly presented content is often still moving: the diagnostic logs tab
  /// spins while it adds up the log directory, and windows fade in. An image
  /// that catches a frame of that differs on every run, which the gallery would
  /// carry as a diff on every commit. A capture that never agrees with itself
  /// fails the test, so a screen that will not hold still is reported rather
  /// than photographed mid-motion and committed.
  private func settledScreenshot(of element: XCUIElement, as fileName: String) -> XCUIScreenshot {
    let attempts = 12
    var previous = element.screenshot()

    for _ in 0..<attempts {
      Thread.sleep(forTimeInterval: 0.5)

      let current = element.screenshot()
      if current.pngRepresentation == previous.pngRepresentation {
        return current
      }

      previous = current
    }

    XCTFail("\(fileName) never held still, across \(attempts) captures")

    return previous
  }
}
