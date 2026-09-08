//
//  ReviewerScreenshotTests.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

#if os(macOS)
  import CoreGraphics
  import XCTest

  @MainActor
  final class ReviewerScreenshotTests: XCTestCase {
    func testAccountSlug() throws {
      continueAfterFailure = false
      guard #available(macOS 26, *) else {
        throw XCTSkip("The shared reviewer screenshot is captured on macOS 26")
      }
      let display = CGMainDisplayID()
      let originalMode = CGDisplayCopyDisplayMode(display)
      defer { _ = CGDisplaySetDisplayMode(display, originalMode, nil) }
      let modes = try XCTUnwrap(CGDisplayCopyAllDisplayModes(display, nil) as? [CGDisplayMode])
      print("Available display modes: \(modes.map { "\($0.width)x\($0.height)" })")
      let desktopMode = try XCTUnwrap(
        modes.filter { $0.width >= 1440 && $0.height >= 900 }
          .min { $0.width * $0.height < $1.width * $1.height },
        "No desktop-sized display mode available")
      XCTAssertEqual(CGDisplaySetDisplayMode(display, desktopMode, nil), .success)

      let browser = XCUIApplication(bundleIdentifier: "com.apple.Safari")
      defer { browser.terminate() }

      // Both clients open this web page. Stop before submitting the form or authenticating.
      let url = try XCTUnwrap(URL(string: "https://app.firezone.dev/?as=gui-client"))
      browser.open(url)
      let page = browser.webViews.firstMatch
      let field = page.textFields.firstMatch
      XCTAssertTrue(field.waitForExistence(timeout: 60), "The account-slug form did not appear")

      // The portal shows its desktop sidebar at a viewport width of 1024 pixels.
      if page.frame.width < 1024 {
        browser.windows.firstMatch.buttons[XCUIIdentifierFullScreenWindow].click()
      }

      field.click()
      field.typeText("firezoneqa")
      let enteredSlug = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "value == %@", "firezoneqa"), object: field)
      XCTAssertEqual(XCTWaiter.wait(for: [enteredSlug], timeout: 10), .completed)
      field.typeKey(.tab, modifierFlags: [])
      XCTAssertEqual(field.value as? String, "firezoneqa")
      XCTAssertGreaterThanOrEqual(page.frame.width, 1024)
      deliver(page, as: "reviewer-sign-in", in: .light)
    }
  }
#endif
