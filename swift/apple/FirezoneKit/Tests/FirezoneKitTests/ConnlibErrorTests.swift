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
}
