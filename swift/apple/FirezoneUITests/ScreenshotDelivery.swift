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
    /// Photographs the desktop: the screen without the menu bar, whose clock no two
    /// captures agree on, and without the Dock, which is not the app's either.
    ///
    /// The whole desktop rather than the menus standing on it. A menu and the submenu
    /// it opens are two windows that no one element covers, and the accessibility
    /// frames describing them report a menu's window on some runs and its content rect
    /// on others, which moves a crop by the width of a shadow. An area that is the
    /// same every time cannot come out covering another; what the picture is cropped
    /// to afterwards is prepare-store-screenshots.py's business.
    @discardableResult
    func deliverDesktop(as name: String, in appearance: Appearance) -> Data {
      deliver(as: name, in: appearance) {
        guard
          let display = NSScreen.main,
          let screen = XCUIScreen.main.screenshot().image
            .cgImage(forProposedRect: nil, context: nil, hints: nil),
          let cropped = screen.cropping(to: Self.desktop(of: screen, on: display))
        else { return Data() }

        return NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:])
          ?? Data()
      }
    }

    /// Where the desktop sits in the screenshot: the display measures its visible
    /// frame from the bottom of the screen and the image is measured from the top.
    private static func desktop(of screen: CGImage, on display: NSScreen) -> CGRect {
      let scale = CGFloat(screen.height) / display.frame.height
      let visible = display.visibleFrame

      return CGRect(
        x: visible.minX * scale,
        y: (display.frame.maxY - visible.maxY) * scale,
        width: visible.width * scale,
        height: visible.height * scale
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
