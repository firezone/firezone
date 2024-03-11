//
//  KeychainStorage.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Dependencies
import Foundation

struct KeychainStorage: Sendable {
  var store:
    @Sendable (Keychain.Token, Keychain.TokenAttributes) async throws -> Keychain.PersistentRef
  var delete: @Sendable (Keychain.PersistentRef) async throws -> Void
  var loadAttributes: @Sendable (Keychain.PersistentRef) async -> Keychain.TokenAttributes?
  var searchByAuthBaseURL: @Sendable (URL) async -> Keychain.PersistentRef?
}

extension KeychainStorage: DependencyKey {
  static var liveValue: KeychainStorage {
    let keychain = Keychain()

    return KeychainStorage(
      store: { try await keychain.store(token: $0, tokenAttributes: $1) },
      delete: { try await keychain.delete(persistentRef: $0) },
      loadAttributes: { await keychain.loadAttributes(persistentRef: $0) },
      searchByAuthBaseURL: { await keychain.search(authBaseURLString: $0.absoluteString) }
    )
  }

  static var testValue: KeychainStorage {
    let storage = LockIsolated([Data: (Keychain.Token, Keychain.TokenAttributes)]())
    return KeychainStorage(
      store: { token, attributes in
        storage.withValue {
          let uuid = UUID().uuidString.data(using: .utf8)!
          $0[uuid] = (token, attributes)
          return uuid
        }
      },
      delete: { ref in
        storage.withValue {
          $0[ref] = nil
        }
      },
      loadAttributes: { ref in
        storage.value[ref]?.1
      },
      searchByAuthBaseURL: { _ in
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
