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

#if os(iOS)
  import UIKit
#endif

enum Appearance: String, CaseIterable {
  case light
  case dark
}

/// What drew the screen. On macOS the release: SwiftUI lays a window out with
/// the release it runs on rather than the SDK it was built with. On iOS the
/// device family, since the same suite photographs an iPhone and an iPad.
@MainActor private let deviceTag: String = {
  #if os(macOS)
    "-macos-\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)"
  #else
    UIDevice.current.userInterfaceIdiom == .pad ? "-ipad" : "-iphone"
  #endif
}()

// Photographing is main-actor work in XCTest, and so is reading the image back.
@MainActor
extension XCTestCase {
  /// Photographs `element` once it holds still, delivers the image as
  /// `<name>-<device>-<appearance>.png`, and hands back its bytes.
  @discardableResult
  func deliver(
    _ element: XCUIElement,
    as name: String,
    in appearance: Appearance
  ) -> Data {
    let fileName = "\(name)\(deviceTag)-\(appearance.rawValue).png"
    let image = settledScreenshot(of: element, as: fileName).pngRepresentation

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
  private func settledScreenshot(of element: XCUIElement, as fileName: String) -> XCUIScreenshot {
    let attempts = 20
    // Three in a row rather than two, a second apart rather than half: a control
    // drawn on a material can hold one appearance long enough to look settled and
    // then reach another, and a pair of captures close together cannot tell that
    // from a picture that has stopped moving.
    let required = 3
    var previous = element.screenshot()
    var previousPNG = previous.pngRepresentation
    var sizes = [previousPNG.count]
    var matches = 1

    for _ in 1...attempts {
      Thread.sleep(forTimeInterval: 1.0)

      let current = element.screenshot()
      let currentPNG = current.pngRepresentation
      sizes.append(currentPNG.count)

      if currentPNG == previousPNG {
        matches += 1

        if matches >= required {
          report(fileName, heldStill: true, outOf: sizes)

          return current
        }
      } else {
        matches = 1
      }

      previous = current
      previousPNG = currentPNG
    }

    report(fileName, heldStill: false, outOf: sizes)
    XCTFail("\(fileName) never held still, across \(attempts) captures")

    return previous
  }

  /// Says in the run's log how a capture came to rest: a screen that agreed at
  /// once differs from one that only just did, and the image shows neither.
  private func report(_ fileName: String, heldStill: Bool, outOf sizes: [Int]) {
    let outcome = heldStill ? "held still" : "never held still"
    let seen = Set(sizes).sorted()

    print("settle: \(fileName) \(outcome) across \(sizes.count) captures, sizes \(seen)")
  }
}
