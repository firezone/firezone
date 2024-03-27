//
//  KeychainStorage.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Dependencies
import Foundation

struct KeychainStorage: Sendable {
  var add: @Sendable (Keychain.Token) async throws -> Keychain.PersistentRef
  var update: @Sendable (Keychain.Token) async throws -> Void
  var search: @Sendable () async -> Keychain.PersistentRef?
}

extension KeychainStorage: DependencyKey {
  static var liveValue: KeychainStorage {
    let keychain = Keychain()

    return KeychainStorage(
      add: { try await keychain.add(token: $0) },
      update: { try await keychain.update(token: $0) },
      search: { await keychain.search() }
    )
  }

  static var testValue: KeychainStorage {
    let storage = LockIsolated([Data: (Keychain.Token)]())
    return KeychainStorage(
      add: { token in
        storage.withValue {
          let uuid = UUID().uuidString.data(using: .utf8)!
          $0[uuid] = (token)
          return uuid
        }
      },
      update: { token in

      },
      search: {
        return UUID().uuidString.data(using: .utf8)!
      }
    )
  }
}

extension DependencyValues {
  var keychain: KeychainStorage {
    get { self[KeychainStorage.self] }
    set { self[KeychainStorage.self] = newValue }
  }
}
