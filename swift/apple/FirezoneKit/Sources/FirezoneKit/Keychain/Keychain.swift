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

public actor Keychain {
  public static let shared = Keychain()
  private let workQueue = DispatchQueue(label: "FirezoneKeychainWorkQueue")

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

  public init() {}

  public func add(query: [CFString: Any]) async throws {
    return try await withCheckedThrowingContinuation { [weak self] continuation in
      self?.workQueue.async {
        var ref: CFTypeRef?
        let ret = SecStatus(SecItemAdd(query as CFDictionary, &ref))
        guard ret.isSuccess else {
          continuation.resume(
            throwing: KeychainError.appleSecError(call: "SecItemAdd", status: ret))
          return
        }

        continuation.resume()
        return
      }
    }
  }

  public func update(
    query: [CFString: Any],
    attributesToUpdate: [CFString: Any]
  ) async throws {
    return try await withCheckedThrowingContinuation { [weak self] continuation in
      self?.workQueue.async {
        let ret = SecStatus(
          SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary))
        guard ret.isSuccess else {
          continuation.resume(
            throwing: KeychainError.appleSecError(call: "SecItemUpdate", status: ret))
          return
        }
        continuation.resume()
      }
    }
  }

  public func load(persistentRef: PersistentRef) async -> Data? {
    return await withCheckedContinuation { [weak self] continuation in
      self?.workQueue.async {
        let query =
          [
            kSecClass: kSecClassGenericPassword,
            kSecValuePersistentRef: persistentRef,
            kSecReturnData: true,
          ] as [CFString: Any]
        var result: CFTypeRef?
        let ret = SecStatus(SecItemCopyMatching(query as CFDictionary, &result))
        if ret.isSuccess,
          let resultData = result as? Data
        {
          continuation.resume(returning: resultData)
        } else {
          continuation.resume(returning: nil)
        }
      }
    }
  }

  public func search(query: [CFString: Any]) async -> PersistentRef? {
    return await withCheckedContinuation { [weak self] continuation in
      guard let self = self else { return }
      self.workQueue.async {
        let query = query.merging([
          kSecClass: kSecClassGenericPassword,
          kSecReturnPersistentRef: true,
        ]) { (current, new) in new }

        var result: CFTypeRef?
        let ret = SecStatus(SecItemCopyMatching(query as CFDictionary, &result))

        if ret.isSuccess, let persistentRef = result as? Data {
          continuation.resume(returning: persistentRef)
        } else {
          continuation.resume(returning: nil)
        }
      }
    }
  }

  public func delete(persistentRef: PersistentRef) async throws {
    return try await withCheckedThrowingContinuation { [weak self] continuation in
      self?.workQueue.async {
        let query = [kSecValuePersistentRef: persistentRef] as [CFString: Any]
        let ret = SecStatus(SecItemDelete(query as CFDictionary))
        guard ret.isSuccess || ret == .status(.itemNotFound) else {
          continuation.resume(
            throwing: KeychainError.appleSecError(call: "SecItemDelete", status: ret))
          return
        }
        continuation.resume(returning: ())
      }
    }
  }

  private func securityError(_ status: OSStatus) -> Error {
    KeychainError.securityError(KeychainStatus(rawValue: status)!)
  }
}
