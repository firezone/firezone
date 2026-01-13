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

  /// When set, responses are returned in sequence. Once exhausted, falls back to fetchResourcesResponse.
  var fetchResourcesSequence: [Data?]? = nil
  private var sequenceIndex = 0

  // Track calls
  var setConfigurationCallCount = 0
  var lastConfiguration: TunnelConfiguration?
  var startCallCount = 0
  var lastStartToken: String?
  var signOutCallCount = 0
  var clearLogsCallCount = 0

  func fetchResources(currentHash: Data) async throws -> Data? {
    fetchResourcesCallCount += 1
    if let error = fetchResourcesError { throw error }

    // If sequence is configured, use it
    if let sequence = fetchResourcesSequence {
      if sequenceIndex < sequence.count {
        let response = sequence[sequenceIndex]
        sequenceIndex += 1
        return response
      }
    }

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
    lastStartToken = token
  }

  func signOut() async throws {
    signOutCallCount += 1
  }

  func clearLogs() async throws {
    clearLogsCallCount += 1
  }
}
