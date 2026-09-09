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

@MainActor
extension XCUIElement {
  /// Whether the control reports itself selected within `timeout`.
  ///
  /// A press that lands while a screen is still arriving is dropped in silence,
  /// and the tab that stays put then holds still enough to photograph, so the
  /// caller presses again until this holds.
  func waitToBeSelected(timeout: TimeInterval) -> Bool {
    let selected = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "isSelected == true"),
      object: self
    )

    return XCTWaiter.wait(for: [selected], timeout: timeout) == .completed
  }
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
    /// The canvas the store preparation centres the screens on, so what shows
    /// between the menus is already the right colour (`MAC_BACKGROUND` there).
    private static let canvasColour = CGColor(
      colorSpace: CGColorSpaceCreateDeviceRGB(),
      components: [30.0 / 255.0, 30.0 / 255.0, 30.0 / 255.0, 1]
    )!  // swiftlint:disable:this force_unwrapping

    /// Photographs what spans more than one element, a menu together with the
    /// submenu it has open, as the screen region covering `frames`, with
    /// everything outside them painted in the canvas colour.
    @discardableResult
    func deliver(
      _ frames: [CGRect],
      as name: String,
      in appearance: Appearance
    ) -> Data {
      deliver(as: name, in: appearance) {
        let region = frames.reduce(CGRect.null) { $0.union($1) }
        let scale = NSScreen.main?.backingScaleFactor ?? 1
        let scaled = { (rect: CGRect) in
          CGRect(
            x: (rect.minX - region.minX) * scale, y: (rect.minY - region.minY) * scale,
            width: rect.width * scale, height: rect.height * scale
          )
        }
        let size = scaled(region).size

        guard
          let screen = XCUIScreen.main.screenshot().image
            .cgImage(forProposedRect: nil, context: nil, hints: nil),
          let cropped = screen.cropping(
            to: CGRect(
              x: region.minX * scale, y: region.minY * scale,
              width: size.width, height: size.height
            )),
          let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
          )
        else { return Data() }

        let whole = CGRect(origin: .zero, size: size)
        context.setFillColor(Self.canvasColour)
        context.fill(whole)

        // Core Graphics measures from the bottom, the accessibility frames from the top.
        context.clip(
          to: frames.map(scaled).map {
            CGRect(x: $0.minX, y: size.height - $0.maxY, width: $0.width, height: $0.height)
          })
        context.draw(cropped, in: whole)

        guard let image = context.makeImage() else { return Data() }

        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
          ?? Data()
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
