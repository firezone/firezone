//
//  DisconnectErrorTests.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation
import Testing

@testable import FirezoneKit

/// The network extension's errors reach the app as plain `NSError`s, so these are built the
/// way they arrive rather than from the Swift types.
@Suite("DisconnectError Tests")
struct DisconnectErrorTests {
  @Test("A connlib error keeps its code, reason and id")
  func connlibError() {
    let error = NSError(
      domain: ConnlibError.errorDomain,
      code: ConnlibError.Code.sessionExpired.rawValue,
      userInfo: ["reason": "expired", "id": "1"]
    )

    #expect(DisconnectError(error) == .connlib(.sessionExpired, reason: "expired", id: "1"))
  }

  @Test("A provider error is recognised by its code")
  func packetTunnelProviderError() {
    let error = NSError(domain: PacketTunnelProviderError.errorDomain, code: 2)

    #expect(DisconnectError(error) == .packetTunnelProvider(.credentialNotConfigured))
  }

  @Test("Any other error is unknown")
  func unknownError() {
    let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)

    #expect(DisconnectError(error) == .unknown)
  }
}
