//
//  ConnlibErrorTests.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation
import Testing

@testable import FirezoneKit

@Suite("Connlib Error Tests")
struct ConnlibErrorTests {
  @Test("X.509 failures request administrator support without sign-in vocabulary")
  func x509FailureMessage() {
    let message = SessionAuthenticationMode.x509.failureMessage(
      "Portal rejected X.509 certificate authentication"
    )

    #expect(message.contains("Portal rejected X.509 certificate authentication"))
    #expect(message.contains("Contact your administrator for support."))
    #expect(!message.localizedCaseInsensitiveContains("sign in"))
  }

  @Test("X.509 key ACL failures hide transport diagnostics")
  func x509KeyAclFailureMessage() {
    let message = SessionAuthenticationMode.x509.failureMessage(
      "Connection to portal failed: X.509 client certificate signing failed: Callback failed: signingFailed(\"\(SessionAuthenticationMode.unusableX509PrivateKeyMessage)\")"
    )

    #expect(
      message
        == "\(SessionAuthenticationMode.unusableX509PrivateKeyMessage)\n\nContact your administrator for support."
    )
    #expect(!message.contains("Connection to portal failed"))
    #expect(!message.contains("Callback failed"))
  }

  @Test("Token failures preserve token-authentication copy")
  func tokenFailureMessage() {
    let message = SessionAuthenticationMode.token.failureMessage("Connection failed")

    #expect(message == "Connection failed")
    #expect(!message.contains("Contact your administrator"))
  }

  @Test("Disconnect error carries its authentication mode through NSError")
  func authenticationModeRoundTripsThroughNSError() {
    let error =
      ConnlibError.disconnected(
        "Certificate rejected",
        authenticationMode: .x509,
        id: "error-id"
      ) as NSError

    #expect(error.domain == ConnlibError.errorDomain)
    #expect(error.code == ConnlibError.Code.disconnected.rawValue)
    #expect(error.userInfo["reason"] as? String == "Certificate rejected")
    #expect(error.userInfo["id"] as? String == "error-id")
    #expect(
      error.userInfo[ConnlibError.authenticationModeUserInfoKey] as? String
        == SessionAuthenticationMode.x509.rawValue
    )
  }
}
