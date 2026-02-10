//
//  RequiresAppKit.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

#if os(macOS)
  import AppKit
  import Testing

  /// Bootstraps AppKit's connection to the window server for GUI testing.
  ///
  /// `swift test` processes run without `NSApplication`, so GUI objects like
  /// `NSAlert` crash when loading nibs (CoreUI's system appearance renderer
  /// is uninitialised). This trait sets `.accessory` activation policy on
  /// `@MainActor` to bootstrap the connection before the suite runs.
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
      try await function()
    }
  }

  extension Trait where Self == RequiresAppKitTrait {
    static var requiresAppKit: Self { Self() }
  }
#endif
