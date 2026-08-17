//
//  IPCClientTests.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation
import NetworkExtension
import Testing

@testable import FirezoneKit

// `@unchecked Sendable`: IPCClient and these tests are `@MainActor`, so all access is too.
private final class RecordingTunnelSession: TunnelSessionProtocol, @unchecked Sendable {
  private(set) var status: NEVPNStatus

  private(set) var startTunnelCallCount = 0
  private(set) var stopTunnelCallCount = 0
  private(set) var sentMessages: [ProviderMessage] = []
  private let responseData: Data?

  init(status: NEVPNStatus, responseData: Data? = nil) {
    self.status = status
    self.responseData = responseData
  }

  // swiftlint:disable:next discouraged_optional_collection
  func startTunnel(options: [String: Any]?) throws {
    startTunnelCallCount += 1
    if options?["cycleStart"] as? Bool == true {
      status = .connecting
    }
  }

  func stopTunnel() {
    stopTunnelCallCount += 1
    status = .disconnected
  }

  func sendProviderMessage(_ messageData: Data, responseHandler: ((Data?) -> Void)?) throws {
    sentMessages.append(try PropertyListDecoder().decode(ProviderMessage.self, from: messageData))
    responseHandler?(responseData)
  }

  func fetchLastDisconnectError(completionHandler: @escaping @Sendable (Error?) -> Void) {
    completionHandler(nil)
  }
}

@Suite("IPCClient")
@MainActor
struct IPCClientTests {
  @Test("Polling decodes state and notifications from one response")
  func pollUpdates() async throws {
    let previousHash = Data([0x01, 0x02])
    let stateChange = try #require(
      try ConnlibState.makeIfChanged(
        resources: nil,
        connectedDevices: [],
        isLogStreamingActive: false,
        comparedTo: previousHash
      )
    )
    let response = StatePollResponse(
      stateChange: stateChange,
      notifications: [UnreachableResource(resourceId: "resource-1", reason: .offline)]
    )
    let session = RecordingTunnelSession(
      status: .connected,
      responseData: try PropertyListEncoder().encode(response)
    )

    let decoded = try await IPCClient.pollUpdates(
      session: session,
      currentHash: previousHash
    )

    #expect(decoded.stateHash == stateChange.hash)
    #expect(decoded.notifications == response.notifications)
    #expect(session.sentMessages.count == 1)
    guard case .pollUpdates(let request) = session.sentMessages[0] else {
      Issue.record("Expected a pollUpdates message")
      return
    }
    #expect(request.stateHash == previousHash)
  }

  @Test("A running tunnel is left alone")
  func drainDoesNotCycleRunningTunnel() async throws {
    for status in [NEVPNStatus.connected, .connecting, .reasserting] {
      let session = RecordingTunnelSession(status: status)

      try await IPCClient.drainFlowLogs(session: session)

      #expect(session.sentMessages.count == 1)
      #expect(session.startTunnelCallCount == 0)
      #expect(session.stopTunnelCallCount == 0)
    }
  }

  @Test("An invalid session is refused rather than started")
  func drainRefusesInvalidSession() async {
    let session = RecordingTunnelSession(status: .invalid)

    await #expect(throws: IPCClient.Error.self) {
      try await IPCClient.drainFlowLogs(session: session)
    }

    #expect(session.startTunnelCallCount == 0)
  }

  #if os(macOS)
    @Test("A stopped tunnel is cycle-started and stopped again")
    func drainCycleStartsStoppedTunnel() async throws {
      let session = RecordingTunnelSession(status: .disconnected)

      try await IPCClient.drainFlowLogs(session: session)

      #expect(session.sentMessages.count == 1)
      #expect(session.startTunnelCallCount == 1)
      #expect(session.stopTunnelCallCount == 1)
    }
  #endif
}
