//
//  MockTunnelController.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import CryptoKit
import Foundation
import NetworkExtension

@testable import FirezoneKit

// MARK: - Shared Test Helpers

enum TestError: Error {
  case simulatedFailure
  case initializationTimeout
}

/// Mock tunnel controller for testing Store.
///
/// Combines tunnel control and IPC functionality in one mock,
/// matching the unified TunnelControllerProtocol design.
@MainActor
final class MockTunnelController: TunnelControllerProtocol {
  let mockSession = MockTunnelSession()

  // MARK: - State

  /// Returns the session only if load succeeded (matches real behavior)
  var session: TunnelSessionProtocol? {
    loadResult ? mockSession : nil
  }
  var isLoaded: Bool = true

  // MARK: - Call Order Tracking

  /// Records the order of method calls for verifying sequences.
  enum CallType: Equatable {
    case load
    case enable
    case start
    case startWithToken(String)
    case signOut
    case setConfiguration
    case fetchResources
    case subscribeToStatusUpdates
  }
  private(set) var callLog: [CallType] = []

  // MARK: - Lifecycle Tracking

  var loadCallCount = 0
  var loadResult: Bool = true
  var enableCallCount = 0
  var enableError: Error?
  var installConfigurationCallCount = 0

  // MARK: - IPC Tracking (merged from MockIPCClient)

  var fetchResourcesResponse: Data?
  var fetchResourcesError: Error?
  var fetchResourcesCallCount = 0

  /// When set, responses are returned in sequence. Once exhausted, falls back to fetchResourcesResponse.
  var fetchResourcesSequence: [Data?]?
  private var sequenceIndex = 0

  /// Enable realistic hash-based behavior for fetchResources.
  /// When true, the mock simulates the tunnel provider's hash comparison:
  /// - Returns nil if the incoming hash matches the current response's hash
  /// - Returns data if hashes differ
  /// When false (default), returns fetchResourcesResponse directly (legacy behavior).
  var simulateHashBehavior: Bool = false
  /// The last hash received from the client (for test inspection).
  private(set) var lastReceivedHash: Data?

  var setConfigurationCallCount = 0
  var setConfigurationError: Error?
  var lastConfiguration: TunnelConfiguration?
  var startCallCount = 0
  var startError: Error?
  var lastStartToken: String?
  var signOutCallCount = 0
  var signOutError: Error?
  var clearLogsCallCount = 0

  // MARK: - Status

  var statusHandler: (@Sendable (NEVPNStatus) async throws -> Void)?

  // MARK: - Lifecycle Implementations

  func load() async throws -> Bool {
    loadCallCount += 1
    callLog.append(.load)
    return loadResult
  }

  func enable() async throws {
    enableCallCount += 1
    callLog.append(.enable)
    if let error = enableError { throw error }
  }

  func installConfiguration() async throws {
    installConfigurationCallCount += 1
  }

  // MARK: - IPC Implementations

  func fetchResources(currentHash: Data) async throws -> Data? {
    fetchResourcesCallCount += 1
    callLog.append(.fetchResources)
    lastReceivedHash = currentHash
    if let error = fetchResourcesError { throw error }

    // If sequence is configured, use it
    if let sequence = fetchResourcesSequence, sequenceIndex < sequence.count {
      let response = sequence[sequenceIndex]
      sequenceIndex += 1
      return response
    }

    // When hash behavior is enabled, simulate realistic tunnel provider behavior
    if simulateHashBehavior, let data = fetchResourcesResponse {
      let responseHash = Data(SHA256.hash(data: data))
      // Return nil if hashes match (no changes), data if different
      return currentHash == responseHash ? nil : data
    }

    return fetchResourcesResponse
  }

  func setConfiguration(_ config: TunnelConfiguration) async throws {
    setConfigurationCallCount += 1
    callLog.append(.setConfiguration)
    lastConfiguration = config
    if let error = setConfigurationError { throw error }
  }

  func start() throws {
    startCallCount += 1
    callLog.append(.start)
    if let error = startError { throw error }
  }

  func start(token: String) throws {
    startCallCount += 1
    callLog.append(.startWithToken(token))
    lastStartToken = token
    if let error = startError { throw error }
  }

  func signOut() async throws {
    signOutCallCount += 1
    callLog.append(.signOut)
    if let error = signOutError { throw error }
  }

  func clearLogs() async throws {
    clearLogsCallCount += 1
  }

  // MARK: - Status Implementations

  func stop() {
    mockSession.stopTunnel()
  }

  func subscribeToStatusUpdates(handler: @escaping @Sendable (NEVPNStatus) async throws -> Void) {
    callLog.append(.subscribeToStatusUpdates)
    statusHandler = handler
  }

  // MARK: - Test Helpers

  /// Simulate a VPN status change.
  func simulateStatusChange(_ status: NEVPNStatus) async throws {
    mockSession.mockStatus = status
    try await statusHandler?(status)
  }

  /// Reset the fetch resources sequence index (useful between test phases).
  func resetFetchSequence() {
    sequenceIndex = 0
  }

  /// Waits for Store initialization to complete (status handler registered).
  ///
  /// Call this after creating a Store via `makeMockStore()` before testing
  /// status-dependent behavior like `simulateStatusChange()`.
  func waitForStatusSubscription(timeout: TimeInterval = 1.0) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while statusHandler == nil && Date() < deadline {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    guard statusHandler != nil else {
      throw TestError.initializationTimeout
    }
  }
}

/// Mock tunnel session for testing.
///
/// Not isolated to MainActor to match NETunnelProviderSession's non-isolated methods.
final class MockTunnelSession: TunnelSessionProtocol {
  private let lock = NSLock()
  private var _mockStatus: NEVPNStatus = .disconnected
  private var _stopCallCount = 0

  var mockStatus: NEVPNStatus {
    get { lock.withLock { _mockStatus } }
    set { lock.withLock { _mockStatus = newValue } }
  }

  var status: NEVPNStatus { mockStatus }

  var stopCallCount: Int {
    lock.withLock { _stopCallCount }
  }

  func stopTunnel() {
    lock.withLock { _stopCallCount += 1 }
  }
}
