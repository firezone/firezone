//
//  TokenTests.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation
import Security
import Testing

@testable import FirezoneKit

@Suite("Token")
struct TokenTests {
  @Test(
    "legacy Keychain tokens without sign-in metadata remain readable",
    arguments: [nil, Data()] as [Data?])
  func loadsLegacyToken(metadata: Data?) throws {
    var attributes: [String: Any] = [kSecValueData as String: Data("legacy-token".utf8)]
    attributes[kSecAttrGeneric as String] = metadata

    let token = try #require(Token(keychainAttributes: attributes))

    #expect(token.description == "legacy-token")
    #expect(token.signInSettings == nil)
  }
}
