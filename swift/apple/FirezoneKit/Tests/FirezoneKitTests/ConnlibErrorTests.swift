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
  @Test("A disconnect carries whether the certificate is what failed")
  func disconnectCarriesTheCertificateFlag() {
    let error = ConnlibError.disconnected("revoked", isCertificateError: true) as NSError

    #expect(error.userInfo["reason"] as? String == "revoked")
    #expect(error.userInfo[ConnlibError.isCertificateErrorKey] as? Bool == true)
  }

  @Test("A disconnect defaults to blaming something other than the certificate")
  func disconnectDefaultsToNotBlamingTheCertificate() {
    let error = ConnlibError.disconnected("gateway went away") as NSError

    #expect(error.userInfo[ConnlibError.isCertificateErrorKey] as? Bool == false)
  }

  #if os(macOS)
    @Test("A failed certificate points the user at their administrator")
    @MainActor
    func certificateDisconnectMentionsTheAdministrator() {
      let text = MacOSAlert.disconnectedText("revoked", isCertificateError: true)

      #expect(text.contains("revoked"))
      #expect(text.contains("Contact your administrator for support."))
    }

    @Test("Any other disconnect keeps the reason it was given")
    @MainActor
    func otherDisconnectsKeepTheReason() {
      let text = MacOSAlert.disconnectedText("gateway went away", isCertificateError: false)

      #expect(text == "gateway went away")
    }
  #endif
}
