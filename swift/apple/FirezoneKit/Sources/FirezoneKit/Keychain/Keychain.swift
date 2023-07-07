//
//  Keychain.swift
//  (c) 2023 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

enum KeychainError: Error {
  case securityError(Status)
}

actor Keychain {
  private static let account = "Firezone"

  func store(key: String, data: Data) throws {
    let query = ([
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: getServiceIdentifier(key),
      kSecAttrAccount: Keychain.account,
      kSecValueData: data,
    ] as [CFString: Any]) as CFDictionary

    let status = SecItemAdd(query, nil)

    if status == Status.duplicateItem {
      try update(key: key, data: data)
    } else if status != Status.success {
      throw securityError(status)
    }
  }

  func update(key: String, data: Data) throws {
    let query = ([
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: getServiceIdentifier(key),
      kSecAttrAccount: Keychain.account,
    ] as [CFString: Any]) as CFDictionary

    let updatedData = [kSecValueData: data] as CFDictionary

    let status = SecItemUpdate(query, updatedData)

    if status != Status.success {
      throw securityError(status)
    }
  }

  func load(key: String) throws -> Data? {
    let query = ([
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: getServiceIdentifier(key),
      kSecAttrAccount: Keychain.account,
      kSecReturnData: kCFBooleanTrue!,
      kSecMatchLimit: kSecMatchLimitOne,
    ] as [CFString: Any]) as CFDictionary

    var data: AnyObject?

    let status = SecItemCopyMatching(query, &data)

    if status == Status.success {
      return data as? Data
    } else if status == Status.itemNotFound {
      return nil
    } else {
      throw securityError(status)
    }
  }

  func delete(key: String) throws {
    let query = ([
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: getServiceIdentifier(key),
      kSecAttrAccount: Keychain.account,
    ] as [CFString: Any]) as CFDictionary

    let status = SecItemDelete(query)

    if status != Status.success {
      throw securityError(status)
    }
  }

  private func getServiceIdentifier(_ key: String) -> String {
    var bundleIdentifier = Bundle.main.bundleIdentifier ?? "dev.firezone.firezone"

    if bundleIdentifier.hasSuffix(".network-extension") {
      bundleIdentifier.removeLast(".network-extension".count)
    }

    return bundleIdentifier + "." + key
  }

  private func securityError(_ status: OSStatus) -> Error {
    KeychainError.securityError(Status(rawValue: status)!)
  }
}
