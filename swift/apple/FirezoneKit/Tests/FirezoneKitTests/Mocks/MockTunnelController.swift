//
//  MockTunnelController.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import NetworkExtension

@testable import FirezoneKit

/// Mock tunnel controller for testing Store's VPN status handling.
@MainActor
final class MockTunnelController: TunnelControllerProtocol {
  let mockSession = MockTunnelSession()
  var session: TunnelSessionProtocol? { mockSession }

  var startCallCount = 0
  var statusHandler: ((NEVPNStatus) async throws -> Void)?

  func start() throws {
    startCallCount += 1
  }

  func stop() {
    mockSession.stopTunnel()
  }

  func subscribeToStatusUpdates(handler: @escaping (NEVPNStatus) async throws -> Void) {
    statusHandler = handler
  }

  /// Test helper: simulate a VPN status change.
  func simulateStatusChange(_ status: NEVPNStatus) async throws {
    mockSession.mockStatus = status
    try await statusHandler?(status)
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
