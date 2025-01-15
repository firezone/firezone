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

  public static func delete() throws {
    guard let tokenRef = Keychain.search(query: query)
    else { return }

    try Keychain.delete(persistentRef: tokenRef)
  }

  // Upsert token to Keychain
  public func save() throws {

    guard Keychain.search(query: Token.query) == nil
    else {
      let query = Token.query.merging([
        kSecClass: kSecClassGenericPassword
      ]) { (_, new) in new }

      return try Keychain.update(
        query: query,
        attributesToUpdate: [kSecValueData: data]
      )
    }

    let query = Token.query.merging([
      kSecClass: kSecClassGenericPassword,
      kSecValueData: data
    ]) { (_, new) in new }

    try Keychain.add(query: query)
  }

  // Attempt to load token from Keychain
  public static func load() throws -> Token? {

    guard let tokenRef = Keychain.search(query: query)
    else { return nil }

    guard let data = Keychain.load(persistentRef: tokenRef)
    else { return nil }

    return Token(data)
  }
}
