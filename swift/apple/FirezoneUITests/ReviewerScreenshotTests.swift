//
//  ReviewerScreenshotTests.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import XCTest

@MainActor
final class ReviewerScreenshotTests: XCTestCase {
  func testAccountSlug() throws {
    continueAfterFailure = false
    guard #available(iOS 16.4, macOS 13.3, *) else {
      throw XCTSkip("Opening Safari by URL requires iOS 16.4 or macOS 13.3")
    }
    #if os(iOS)
      try XCTSkipIf(ProcessInfo.processInfo.environment["SCREENSHOT_APPEARANCE"] != "light")
      let browser = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
    #else
      let browser = XCUIApplication(bundleIdentifier: "com.apple.Safari")
    #endif
    defer { browser.terminate() }

    // Both clients open this web page. Stop before submitting the form or authenticating.
    let url = try XCTUnwrap(URL(string: "https://app.firezone.dev/?as=gui-client"))
    browser.open(url)
    let page = browser.webViews.firstMatch
    let field = page.textFields.firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 60), "The account-slug form did not appear")

    let heading = page.descendants(matching: .any).matching(
      NSPredicate(
        format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", "account slug", "account slug")
    ).firstMatch
    #if os(iOS)
      field.tap()
      field.typeText("firezoneqa")
      heading.tap()
    #else
      field.click()
      field.typeText("firezoneqa")
      heading.click()
    #endif
    XCTAssertEqual(field.value as? String, "firezoneqa")
    deliver(page, as: "reviewer-sign-in", in: .light)
  }
}
