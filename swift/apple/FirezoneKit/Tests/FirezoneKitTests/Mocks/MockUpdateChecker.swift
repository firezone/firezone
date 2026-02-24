//
//  MockUpdateChecker.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

#if os(macOS)
  import Combine

  @testable import FirezoneKit

  /// Mock implementation of UpdateCheckerProtocol for testing.
  @MainActor
  final class MockUpdateChecker: UpdateCheckerProtocol {
    @Published var updateAvailable = false
  }
#endif
