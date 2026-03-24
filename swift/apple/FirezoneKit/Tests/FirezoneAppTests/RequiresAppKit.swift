//
//  RequiresAppKit.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

#if os(macOS)
  @preconcurrency import AppKit
  import Testing

  /// Bootstraps AppKit's connection to the window server for GUI testing
  /// and makes all windows transparent so nothing appears on screen.
  ///
  /// `swift test` processes run without `NSApplication`, so GUI objects like
  /// `NSAlert` crash when loading nibs (CoreUI's system appearance renderer
  /// is uninitialised). This trait sets `.accessory` activation policy on
  /// `@MainActor` to bootstrap the connection before the suite runs.
  ///
  /// An observer on `NSWindow.didUpdateNotification` sets `alphaValue = 0`
  /// on every window as it appears, keeping tests invisible. This does not
  /// affect `NSWindow.isVisible` or programmatic `performClick(nil)` calls,
  /// so assertions and interactions still work normally. If a test crashes,
  /// only invisible windows remain — nothing to manually dismiss.
  ///
  /// Usage:
  ///
  ///     @Suite("My Tests", .requiresAppKit)
  ///     struct MyTests { ... }
  struct RequiresAppKitTrait: SuiteTrait, TestScoping {
    func provideScope(
      for test: Test,
      testCase: Test.Case?,
      performing function: @Sendable () async throws -> Void
    ) async throws {
      await MainActor.run {
        _ = NSApplication.shared.setActivationPolicy(.accessory)
      }

      nonisolated(unsafe) let observer = await MainActor.run {
        NotificationCenter.default.addObserver(
          forName: NSWindow.didUpdateNotification,
          object: nil,
          queue: .main
        ) { notification in
          let window = notification.object as? NSWindow
          MainActor.assumeIsolated {
            window?.alphaValue = 0
          }
        }
      }

      defer { NotificationCenter.default.removeObserver(observer) }
      try await function()
    }
  }

  extension Trait where Self == RequiresAppKitTrait {
    static var requiresAppKit: Self { Self() }
  }
#endif
