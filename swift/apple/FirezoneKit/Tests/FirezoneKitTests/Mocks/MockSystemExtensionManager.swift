//
//  MockSystemExtensionManager.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

#if os(macOS)
  @testable import FirezoneKit

  @MainActor
  final class MockSystemExtensionManager: SystemExtensionManagerProtocol {
    var checkResult: Result<SystemExtensionStatus, Error> = .success(.installed)
    var tryInstallResult: Result<SystemExtensionStatus, Error> = .success(.installed)

    private(set) var checkCallCount = 0
    private(set) var tryInstallCallCount = 0

    func check() async throws -> SystemExtensionStatus {
      checkCallCount += 1
      return try checkResult.get()
    }

    func tryInstall() async throws -> SystemExtensionStatus {
      tryInstallCallCount += 1
      return try tryInstallResult.get()
    }
  }
#endif
