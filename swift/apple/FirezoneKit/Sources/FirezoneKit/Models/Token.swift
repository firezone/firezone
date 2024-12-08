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
    kSecAttrService: AppInfoPlistConstants.appGroupId,
    kSecAttrDescription: "Firezone access token",
  ]

  private var data: Data

  public var description: String { String(data: data, encoding: .utf8)! }

  public init(_ data: Data) {
    self.data = data
  }

  public static func delete() async throws {
    guard let tokenRef = await Keychain.shared.search(query: query)
    else { return }

    try await Keychain.shared.delete(persistentRef: tokenRef)
  }

  // Upsert token to Keychain
  public func save() async throws {
    guard await Keychain.shared.search(query: Token.query) == nil
    else {
      let query = Token.query.merging([
        kSecClass: kSecClassGenericPassword
      ]) { (_, new) in new }
      
      return try await Keychain.shared.update(
        query: query,
        attributesToUpdate: [kSecValueData: data]
      )
    }

    let query = Token.query.merging([
      kSecClass: kSecClassGenericPassword,
      kSecValueData: data
    ]) { (_, new) in new }

    try await Keychain.shared.add(query: query)
  }

  // Attempt to load token from Keychain
  public static func load() async throws -> Token? {
    guard let tokenRef = await Keychain.shared.search(query: query)
    else { return nil }

    guard let data = await Keychain.shared.load(persistentRef: tokenRef)
    else { return nil }

    return Token(data)
  }
}
