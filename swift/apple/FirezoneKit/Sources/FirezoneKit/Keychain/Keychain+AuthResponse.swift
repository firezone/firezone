//
//  Keychain+AuthResponse.swift
//  (c) 2023 Firezone, Inc.
//  LICENSE: Apache-2.0
//

extension KeychainStorage {
  static let tokenKey = "token"
  static let actorNameKey = "actorName"

  func token() async throws -> String? {
    let token = try await load(KeychainStorage.tokenKey).flatMap { data in
      String(data: data, encoding: .utf8)
    }

    guard let token else { return nil }
    return token
  }

  func actorName() async throws -> String? {
    let actorName = try await load(KeychainStorage.actorNameKey).flatMap { data in
      String(data: data, encoding: .utf8)
    }

    guard let actorName else { return nil }
    return actorName
  }

  func save(token: String, actorName: String?) async throws {
    try await store(KeychainStorage.tokenKey, token.data(using: .utf8)!)

    if let actorName {
      try await store(KeychainStorage.actorNameKey, actorName.data(using: .utf8)!)
    }
  }

  func deleteAuthResponse() async throws {
    try await delete(KeychainStorage.tokenKey)
    try await delete(KeychainStorage.actorNameKey)
  }
}
