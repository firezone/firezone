//
//  KeychainStorage.swift
//  (c) 2023 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Dependencies
import Foundation

struct KeychainStorage: Sendable {
  var store: @Sendable (String, Data) async throws -> Void
  var load: @Sendable (String) async throws -> Data?
  var delete: @Sendable (String) async throws -> Void
}

extension KeychainStorage: DependencyKey {
  static var liveValue: KeychainStorage {
    let keychain = Keychain()

    return KeychainStorage(
      store: { try await keychain.store(key: $0, data: $1) },
      load: { try await keychain.load(key: $0) },
      delete: { try await keychain.delete(key: $0) }
    )
  }

  static var testValue: KeychainStorage {
    let storage = LockIsolated([String: Data]())
    return KeychainStorage(
      store: { key, data in
        storage.withValue {
          $0[key] = data
        }
      },
      load: { storage.value[$0] },
      delete: { key in
        storage.withValue {
          $0[key] = nil
        }
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
