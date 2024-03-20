//
//  KeychainStorage.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Dependencies
import Foundation

struct KeychainStorage: Sendable {
  var store: @Sendable (Keychain.Token) async throws -> Keychain.PersistentRef
  var delete: @Sendable (Keychain.PersistentRef) async throws -> Void
  var fetch: @Sendable () async -> Keychain.PersistentRef?
}

extension KeychainStorage: DependencyKey {
  static var liveValue: KeychainStorage {
    let keychain = Keychain()

    return KeychainStorage(
      store: { try await keychain.store(token: $0) },
      delete: { try await keychain.delete(persistentRef: $0) },
      fetch: { await keychain.fetch() }
    )
  }

  static var testValue: KeychainStorage {
    let storage = LockIsolated([Data: (Keychain.Token)]())
    return KeychainStorage(
      store: { token in
        storage.withValue {
          let uuid = UUID().uuidString.data(using: .utf8)!
          $0[uuid] = (token)
          return uuid
        }
      },
      delete: { ref in
        storage.withValue {
          $0[ref] = nil
        }
      },
      fetch: {
        nil
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
