//
//  IOSExportLogsTests.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

#if os(iOS)
  import XCTest

  @MainActor
  final class IOSExportLogsTests: XCTestCase {
    func testExportLogsPresentsTheShareSheet() throws {
      let app = launchApp(scenario: "connected-large-logs")
      defer { app.terminate() }

      try openSettings(in: app, on: "settings")
      try selectTab("Diagnostic Logs", showing: "Clear Log Directory", in: app)

      let export = app.buttons["Export Logs"]
      try waitFor(export, on: "settings-logs")

      let ready = NSPredicate(format: "enabled == true AND hittable == true")

      for attempt in 1...2 {
        export.tap()

        guard shareSheetContent(in: app).waitForExistence(timeout: 120) else {
          return XCTFail("The share sheet never showed its activities on export \(attempt)")
        }

        dismissShareSheet(in: app)

        let available = XCTNSPredicateExpectation(predicate: ready, object: export)
        guard XCTWaiter.wait(for: [available], timeout: 10) == .completed else {
          return XCTFail("Export Logs did not become available again after export \(attempt)")
        }
      }
    }

    /// Any of the things the share sheet draws once it has the archive: the activity list,
    /// an activity every file offers, or the header naming the archive.
    private func shareSheetContent(in app: XCUIApplication) -> XCUIElement {
      app.descendants(matching: .any).matching(
        NSPredicate(
          format: "identifier == %@ OR label IN %@ OR label BEGINSWITH %@",
          argumentArray: ["ActivityListView", ["Copy", "Save to Files"], "firezone_logs_"]
        )
      ).firstMatch
    }

    private func dismissShareSheet(in app: XCUIApplication) {
      let close = app.buttons["Close"]

      if close.waitForExistence(timeout: 5) {
        close.tap()
      } else {
        app.swipeDown(velocity: .fast)
      }
    }
  }
#endif
