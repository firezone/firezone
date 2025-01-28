//
//  Keychain.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

public enum KeychainError: Error {
  case securityError(OSStatus)
  case appleSecError(call: String, status: OSStatus)
  case nilResultFromAppleSecCall(call: String)
  case resultFromAppleSecCallIsInvalid(call: String)
  case unableToFindSavedItem
  case unableToGetAppGroupIdFromInfoPlist
  case unableToFormExtensionPath
  case unableToGetPluginsPath
}

public enum Keychain {
  public typealias PersistentRef = Data

  enum Result: Int32 {
    case success = 0
    case itemNotFound = -25300
  }

  public static func add(query: [CFString: Any]) throws {
    var ref: CFTypeRef?
    let status = SecItemAdd(query as CFDictionary, &ref)

    guard status == Result.success.rawValue
    else {
      throw KeychainError.appleSecError(call: "SecItemAdd", status: status)
    }

    return
  }

  public static func update(
    query: [CFString: Any],
    attributesToUpdate: [CFString: Any]
  ) throws {

    let status = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)

    guard status == Result.success.rawValue
    else {
      throw KeychainError.appleSecError(call: "SecItemUpdate", status: status)
    }
  }

  public static func load(persistentRef: PersistentRef) -> Data? {
    let query = [
      kSecClass: kSecClassGenericPassword,
      kSecValuePersistentRef: persistentRef,
      kSecReturnData: true
    ] as [CFString: Any]

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)

    guard status == Result.success.rawValue,
          let resultData = result as? Data
    else {
      return nil
    }

    return resultData
  }

  public static func search(query: [CFString: Any]) -> PersistentRef? {
    let query = query.merging([
      kSecClass: kSecClassGenericPassword,
      kSecReturnPersistentRef: true
    ]) { (_, new) in new }

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)

    guard status == Result.success.rawValue,
          let persistentRef = result as? Data
    else {
      return nil
    }

    return persistentRef
  }

  public static func delete(persistentRef: PersistentRef) throws {
    let query = [kSecValuePersistentRef: persistentRef] as [CFString: Any]
    let status = SecItemDelete(query as CFDictionary)

    guard status == Result.success.rawValue || status == Result.itemNotFound.rawValue
    else {
      throw KeychainError.appleSecError(call: "SecItemDelete", status: status)
    }
  }
}
