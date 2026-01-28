//
//  MacOSAlertTests.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

#if os(macOS)
  import AppKit
  import Testing

  @testable import FirezoneKit

  @Suite("MacOSAlert Tests")
  struct MacOSAlertTests {
    /// Waits for an alert's sheet to become visible before interacting with it.
    /// This is more reliable than arbitrary sleep delays as it polls for actual window state.
    @MainActor
    private static func waitForSheetPresentation(_ alert: NSAlert) async {
      while !alert.window.isVisible {
        await Task.yield()
      }
    }

    @Test("Alert presentation doesn't block main actor")
    @MainActor
    func alertPresentationIsNonBlocking() async {
      let alert = NSAlert()
      alert.messageText = "Test Alert"
      alert.addButton(withTitle: "OK")

      var concurrentTaskExecuted = false
      var alertWasVisibleWhenTaskRan = false

      // Start a concurrent @MainActor task that will:
      // 1. Wait for the alert to appear
      // 2. Record that it ran while alert was visible
      // 3. Dismiss the alert
      Task { @MainActor in
        while !alert.window.isVisible {
          await Task.yield()
        }
        alertWasVisibleWhenTaskRan = alert.window.isVisible
        concurrentTaskExecuted = true
        alert.buttons.first?.performClick(nil)
      }

      // Await show() directly (not async let).
      // For this to complete, the Task above must run and dismiss the alert.
      // This proves that other @MainActor work can execute during show().
      // If show() blocked the main actor, the Task couldn't run, the alert
      // wouldn't be dismissed, and this test would hang forever.
      let response = await MacOSAlert.show(alert)

      #expect(concurrentTaskExecuted, "Concurrent task must execute for alert to be dismissed")
      #expect(alertWasVisibleWhenTaskRan, "Alert should be visible when concurrent task runs")
      #expect(response == .alertFirstButtonReturn)
    }

    @Test("Returns correct response for each button")
    @MainActor
    func returnsCorrectButtonResponse() async {
      let alert = NSAlert()
      alert.messageText = "Test"
      alert.addButton(withTitle: "First")  // alertFirstButtonReturn
      alert.addButton(withTitle: "Second")  // alertSecondButtonReturn
      alert.addButton(withTitle: "Third")  // alertThirdButtonReturn

      async let response = MacOSAlert.show(alert)

      await Self.waitForSheetPresentation(alert)

      // Click the second button
      alert.buttons[1].performClick(nil)

      let result = await response
      #expect(result == .alertSecondButtonReturn)
    }

    @Test("Multiple sequential alerts work correctly")
    @MainActor
    func multipleSequentialAlerts() async {
      // First alert
      let alert1 = NSAlert()
      alert1.messageText = "First"
      alert1.addButton(withTitle: "OK")

      async let response1 = MacOSAlert.show(alert1)
      await Self.waitForSheetPresentation(alert1)
      alert1.buttons.first?.performClick(nil)
      let result1 = await response1

      // Second alert
      let alert2 = NSAlert()
      alert2.messageText = "Second"
      alert2.addButton(withTitle: "OK")
      alert2.addButton(withTitle: "Cancel")

      async let response2 = MacOSAlert.show(alert2)
      await Self.waitForSheetPresentation(alert2)
      alert2.buttons[1].performClick(nil)  // Click Cancel
      let result2 = await response2

      #expect(result1 == .alertFirstButtonReturn)
      #expect(result2 == .alertSecondButtonReturn)
    }

    @Test("Concurrent alerts are queued correctly")
    @MainActor
    func concurrentAlertsAreQueued() async {
      let alert1 = NSAlert()
      alert1.messageText = "First"
      alert1.addButton(withTitle: "OK")

      let alert2 = NSAlert()
      alert2.messageText = "Second"
      alert2.addButton(withTitle: "OK")

      // Start both alerts concurrently
      async let response1 = MacOSAlert.show(alert1)
      async let response2 = MacOSAlert.show(alert2)

      await Self.waitForSheetPresentation(alert1)

      // First alert should be showing, dismiss it
      alert1.buttons.first?.performClick(nil)

      await Self.waitForSheetPresentation(alert2)

      // Second alert should now be showing, dismiss it
      alert2.buttons.first?.performClick(nil)

      let (result1, result2) = await (response1, response2)

      #expect(result1 == .alertFirstButtonReturn)
      #expect(result2 == .alertFirstButtonReturn)
    }
  }
#endif
