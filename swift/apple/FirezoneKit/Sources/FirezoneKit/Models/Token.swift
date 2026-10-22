//
//  Token.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//
//  Convenience wrapper for working with our auth token stored in the Keychain.

import Foundation

public struct Token: CustomStringConvertible, Sendable {
  #if DEBUG
    private static let label = "Firezone token (debug)"
    private static let account = "1 (debug)"
    private static let description = "Firezone access token (debug)"
  #else
    private static let label = "Firezone token"
    private static let account = "1"
    private static let description = "Firezone access token"
  #endif

  private static var query: [CFString: Any] {
    [
      kSecAttrLabel: label,
      kSecAttrAccount: account,
      kSecAttrService: BundleHelper.appGroupId,
      kSecAttrDescription: description,
    ]
  }

  private var data: Data

  // TODO: refactor to avoid force unwrapping
  // swiftlint:disable:next force_unwrapping
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
    if let existingRef = Keychain.search(query: Token.query) {
      let updateQuery = Token.query.merging([
        kSecClass: kSecClassGenericPassword
      ]) { (_, new) in new }

      do {
        try Keychain.update(
          query: updateQuery,
          attributesToUpdate: [kSecValueData: data]
        )
        return
      } catch let error as KeychainError {
        // If update fails due to permissions (item owned by different code signature),
        // delete the old item and add a fresh one
        if case .appleSecError("SecItemUpdate", errSecWrPerm) = error {
          try Keychain.delete(persistentRef: existingRef)
        } else {
          throw error
        }
      }
    }

    let query = Token.query.merging([
      kSecClass: kSecClassGenericPassword,
      kSecValueData: data,
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
