//
//  ReviewerScreenshotTests.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

#if os(macOS)
  import XCTest

  @MainActor
  final class ReviewerScreenshotTests: XCTestCase {
    func testAccountSlug() throws {
      continueAfterFailure = false
      guard #available(macOS 13.3, *) else {
        throw XCTSkip("Opening Safari by URL requires macOS 13.3")
      }
      let browser = XCUIApplication(bundleIdentifier: "com.apple.Safari")
      defer { browser.terminate() }

      // Both clients open this web page. Stop before submitting the form or authenticating.
      let url = try XCTUnwrap(URL(string: "https://app.firezone.dev/?as=gui-client"))
      browser.open(url)
      let page = browser.webViews.firstMatch
      let field = page.textFields.firstMatch
      XCTAssertTrue(field.waitForExistence(timeout: 60), "The account-slug form did not appear")

      field.click()
      field.typeText("firezoneqa")
      let enteredSlug = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "value == %@", "firezoneqa"), object: field)
      XCTAssertEqual(XCTWaiter.wait(for: [enteredSlug], timeout: 10), .completed)
      field.typeKey(.tab, modifierFlags: [])
      XCTAssertEqual(field.value as? String, "firezoneqa")
      deliver(page, as: "reviewer-sign-in", in: .light)
    }
  }
#endif
