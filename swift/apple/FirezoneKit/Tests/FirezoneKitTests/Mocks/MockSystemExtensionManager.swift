//
//  MockSystemExtensionManager.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

#if os(macOS)
  @testable import FirezoneKit

  /// Mock implementation of SystemExtensionManagerProtocol for testing.
  ///
  /// This mock allows tests to run without accessing the real system extension APIs,
  /// which require entitlements and system-level permissions.
  @MainActor
  final class MockSystemExtensionManager: SystemExtensionManagerProtocol {
    // MARK: - Tracking

    var checkStatusCallCount = 0
    var installCallCount = 0

    // MARK: - Configurable Responses

    var checkStatusResult: SystemExtensionStatus = .installed
    var installResult: SystemExtensionStatus = .installed
    var checkStatusError: Error?
    var installError: Error?

    // MARK: - SystemExtensionManagerProtocol

    func checkStatus() async throws -> SystemExtensionStatus {
      checkStatusCallCount += 1
      if let error = checkStatusError { throw error }
      return checkStatusResult
    }

    func install() async throws -> SystemExtensionStatus {
      installCallCount += 1
      if let error = installError { throw error }
      return installResult
    }
  }
#endif
