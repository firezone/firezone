//
//  Token.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//
//  Convenience wrapper for working with our auth token stored in the Keychain.

import Foundation

public struct Token: CustomStringConvertible {
  private static let query: [CFString: Any] = [
    kSecAttrLabel: "Firezone token",
    kSecAttrAccount: "1",
    kSecAttrService: BundleHelper.appGroupId,
    kSecAttrDescription: "Firezone access token",
  ]

  private var data: Data

  public var description: String { String(data: data, encoding: .utf8)! }

  public init?(_ tokenString: String?) {
    guard let tokenString = tokenString,
          let data = tokenString.data(using: .utf8)
    else { return nil }

    self.data = data
  }

  public init(_ data: Data) {
    self.data = data
  }

  public static func delete(
    _ keychain: Keychain = Keychain.shared
  ) async throws {

    guard let tokenRef = await keychain.search(query: query)
    else { return }

    try await keychain.delete(persistentRef: tokenRef)
  }

  // Upsert token to Keychain
  public func save(_ keychain: Keychain = Keychain.shared) async throws {

    guard await keychain.search(query: Token.query) == nil
    else {
      let query = Token.query.merging([
        kSecClass: kSecClassGenericPassword
      ]) { (_, new) in new }

      return try await keychain.update(
        query: query,
        attributesToUpdate: [kSecValueData: data]
      )
    }

    let query = Token.query.merging([
      kSecClass: kSecClassGenericPassword,
      kSecValueData: data
    ]) { (_, new) in new }

    try await keychain.add(query: query)
  }

  // Attempt to load token from Keychain
  public static func load(
    _ keychain: Keychain = Keychain.shared
  ) async throws -> Token? {

    guard let tokenRef = await keychain.search(query: query)
    else { return nil }

    guard let data = await keychain.load(persistentRef: tokenRef)
    else { return nil }

    return Token(data)
  }
}
