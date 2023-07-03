//
//  Keychain+Token.swift
//  (c) 2023 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import JWTDecode

extension KeychainStorage {
  static let tokenKey = "token"

  func tokenString() async throws -> String? {
    let jwt = try await load(KeychainStorage.tokenKey).flatMap { data in
      String(data: data, encoding: .utf8)
    }

    guard let jwt else { return nil }
    return jwt
  }

  func save(tokenString: String) async throws {
    try await store(KeychainStorage.tokenKey, tokenString.data(using: .utf8)!)
  }

  func deleteTokenString() async throws {
    try await delete(KeychainStorage.tokenKey)
  }
}
