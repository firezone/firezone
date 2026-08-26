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
    in appearance: Appearance
  ) -> Data {
    let fileName = "\(name)-\(appearance.rawValue).png"
    let image = settledScreenshot(of: element, as: fileName).pngRepresentation

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
    let attempts = 20
    // Three in a row rather than two, a second apart rather than half: a control
    // drawn on a material can hold one appearance long enough to look settled and
    // then reach another, and a pair of captures close together cannot tell that
    // from a picture that has stopped moving.
    let required = 3
    waitForNoBanner()
    var previous = element.screenshot()
    var previousPNG = previous.pngRepresentation
    var sizes = [previousPNG.count]
    var matches = 1

    for _ in 1...attempts {
      Thread.sleep(forTimeInterval: 1.0)
      waitForNoBanner()

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

  /// Blocks while something SpringBoard drew is across the top of the screen.
  ///
  /// A notification banner belongs to SpringBoard rather than to the app, so it is
  /// not in the app's element tree and the app cannot be asked to wait for it. It
  /// is drawn over whatever is being photographed all the same: the gallery
  /// carried a "Ready for Apple Intelligence" notice across a navigation bar.
  ///
  /// A banner outlives a run of captures taken a second apart, so a screen can
  /// hold still with one on it. Matching on where it is drawn rather than on what
  /// it is called keeps this working when the name changes between releases.
  private func waitForNoBanner() {
    #if os(iOS)
      let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
      // SpringBoard fills the display, so its own frame is the screen's.
      let screen = springboard.frame
      let deadline = Date().addingTimeInterval(20)

      while Date() < deadline {
        let banner = springboard.otherElements.allElementsBoundByIndex.contains { element in
          let frame = element.frame

          // Wider than half the screen and taller than the status bar, in the top
          // third of it: a banner, and nothing else SpringBoard leaves up there.
          return frame.width > screen.width / 2
            && frame.height > 60
            && frame.maxY < screen.height / 3
        }

        if !banner {
          return
        }

        Thread.sleep(forTimeInterval: 0.5)
      }
    #endif
  }

  /// Says in the run's log how a capture came to rest.
  ///
  /// A screen that holds still here and still differs from the last run is
  /// telling us the difference was fixed before the first capture, which no
  /// amount of watching can settle. One that only just reaches agreement is a
  /// screen the next run may well catch mid-motion. Neither is visible in the
  /// image itself, and the sizes separate the two.
  private func report(_ fileName: String, heldStill: Bool, outOf sizes: [Int]) {
    let outcome = heldStill ? "held still" : "never held still"
    let seen = Set(sizes).sorted()

    print("settle: \(fileName) \(outcome) across \(sizes.count) captures, sizes \(seen)")
  }
}
