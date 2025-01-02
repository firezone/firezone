//
//  Keychain.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

public enum KeychainError: Error {
  case securityError(KeychainStatus)
  case appleSecError(call: String, status: Keychain.SecStatus)
  case nilResultFromAppleSecCall(call: String)
  case resultFromAppleSecCallIsInvalid(call: String)
  case unableToFindSavedItem
  case unableToGetAppGroupIdFromInfoPlist
  case unableToFormExtensionPath
  case unableToGetPluginsPath
}

public enum Keychain {
  public typealias PersistentRef = Data

  public enum SecStatus: Equatable {
    case status(KeychainStatus)
    case unknownStatus(OSStatus)

    init(_ osStatus: OSStatus) {
      if let status = KeychainStatus(rawValue: osStatus) {
        self = .status(status)
      } else {
        self = .unknownStatus(osStatus)
      }
    }

    var isSuccess: Bool {
      return self == .status(.success)
    }
  }

  public static func add(query: [CFString: Any]) throws {
    var ref: CFTypeRef?
    let ret = SecStatus(SecItemAdd(query as CFDictionary, &ref))
    guard ret.isSuccess else {
      throw KeychainError.appleSecError(call: "SecItemAdd", status: ret)
    }

    return
  }

  public static func update(
    query: [CFString: Any],
    attributesToUpdate: [CFString: Any]
  ) throws {

    let ret = SecStatus(
      SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary))

    guard ret.isSuccess else {
      throw KeychainError.appleSecError(call: "SecItemUpdate", status: ret)
    }
  }

  public static func load(persistentRef: PersistentRef) -> Data? {
    let query = [
      kSecClass: kSecClassGenericPassword,
      kSecValuePersistentRef: persistentRef,
      kSecReturnData: true,
    ] as [CFString: Any]

    var result: CFTypeRef?
    let ret = SecStatus(SecItemCopyMatching(query as CFDictionary, &result))

    guard ret.isSuccess,
          let resultData = result as? Data
    else {
      return nil
    }

    return resultData
  }

  public static func search(query: [CFString: Any]) -> PersistentRef? {
    let query = query.merging([
      kSecClass: kSecClassGenericPassword,
      kSecReturnPersistentRef: true,
    ]) { (_, new) in new }

    var result: CFTypeRef?
    let ret = SecStatus(SecItemCopyMatching(query as CFDictionary, &result))

    guard ret.isSuccess,
          let persistentRef = result as? Data
    else {
      return nil
    }

    return persistentRef
  }

  public static func delete(persistentRef: PersistentRef) throws {
    let query = [kSecValuePersistentRef: persistentRef] as [CFString: Any]
    let ret = SecStatus(SecItemDelete(query as CFDictionary))

    guard ret.isSuccess || ret == .status(.itemNotFound)
    else {
      throw KeychainError.appleSecError(call: "SecItemDelete", status: ret)
    }
  }
}
