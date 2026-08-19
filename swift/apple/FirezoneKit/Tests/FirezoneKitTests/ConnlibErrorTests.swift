//
//  ConnlibErrorTests.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation
import Testing

@testable import FirezoneKit

@Suite("ConnlibError Tests")
struct ConnlibErrorTests {
  @Test("A disconnect carries how the session authenticated")
  func disconnectCarriesAuthenticationMode() {
    let error = ConnlibError.disconnected("revoked", authenticationMode: .certificate)
      as NSError

    #expect(error.userInfo["reason"] as? String == "revoked")
    #expect(
      error.userInfo[ConnlibError.authenticationModeKey] as? String
        == SessionAuthenticationMode.certificate.rawValue)
  }

  @Test("A disconnect defaults to token authentication")
  func disconnectDefaultsToToken() {
    let error = ConnlibError.disconnected("gateway went away") as NSError

    #expect(
      error.userInfo[ConnlibError.authenticationModeKey] as? String
        == SessionAuthenticationMode.token.rawValue)
  }

  #if os(macOS)
    @Test("A certificate session points the user at their administrator")
    @MainActor
    func certificateDisconnectMentionsTheAdministrator() {
      let text = MacOSAlert.disconnectedText("revoked", authenticationMode: .certificate)

      #expect(text.contains("revoked"))
      #expect(text.contains("Contact your administrator for support."))
    }

    @Test("A token session keeps the reason it was given")
    @MainActor
    func tokenDisconnectKeepsTheReason() {
      let text = MacOSAlert.disconnectedText("gateway went away", authenticationMode: .token)

      #expect(text == "gateway went away")
    }
  #endif
}
