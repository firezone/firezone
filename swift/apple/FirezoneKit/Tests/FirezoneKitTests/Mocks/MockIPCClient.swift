//
//  MockIPCClient.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation
@testable import FirezoneKit

/// Mock IPC client for testing Store's resource fetching logic.
@MainActor
final class MockIPCClient: IPCClientProtocol {
  // Configure responses
  var fetchResourcesResponse: Data? = nil
  var fetchResourcesError: Error? = nil
  var fetchResourcesCallCount = 0

  // Track calls
  var setConfigurationCallCount = 0
  var lastConfiguration: TunnelConfiguration?
  var startCallCount = 0
  var signOutCallCount = 0
  var clearLogsCallCount = 0

  func fetchResources(currentHash: Data) async throws -> Data? {
    fetchResourcesCallCount += 1
    if let error = fetchResourcesError { throw error }
    return fetchResourcesResponse
  }

  func setConfiguration(_ config: TunnelConfiguration) async throws {
    setConfigurationCallCount += 1
    lastConfiguration = config
  }

  func start() throws {
    startCallCount += 1
  }

  func start(token: String) throws {
    startCallCount += 1
  }

  func signOut() async throws {
    signOutCallCount += 1
  }

  func clearLogs() async throws {
    clearLogsCallCount += 1
  }
}
