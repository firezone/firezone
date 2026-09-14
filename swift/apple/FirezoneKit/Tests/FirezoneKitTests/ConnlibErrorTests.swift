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
  @Test("A disconnect carries its reason in userInfo")
  func disconnectCarriesItsReasonInUserInfo() {
    let error = ConnlibError.disconnected("revoked") as NSError

    #expect(error.userInfo["reason"] as? String == "revoked")
  }

  #if os(macOS)
    @Test("A disconnect keeps the reason it was given")
    @MainActor
    func disconnectsKeepTheReason() {
      let text = MacOSAlert.disconnectedText("gateway went away")

      #expect(text == "gateway went away")
    }

    @Test("A disconnect without a reason falls back to a generic one")
    @MainActor
    func disconnectsWithoutAReasonFallBack() {
      let text = MacOSAlert.disconnectedText(nil)

      #expect(text == "Firezone has been disconnected.")
    }
  #endif
}
