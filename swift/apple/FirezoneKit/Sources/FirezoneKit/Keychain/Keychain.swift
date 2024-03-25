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
  private let label = "Firezone token"
  private let description = "Firezone access token used to authenticate the client."
  private let account = "Firezone"
  private let service = Bundle.main.bundleIdentifier!

  private let workQueue = DispatchQueue(label: "FirezoneKeychainWorkQueue")

  public typealias Token = String
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

  func add(token: Token) async throws -> PersistentRef {
    return try await withCheckedThrowingContinuation { [weak self] continuation in
      self?.workQueue.async { [weak self] in
        guard let self = self else {
          continuation.resume(throwing: KeychainError.securityError(.unexpectedError))
          return
        }

        let query: [CFString: Any] = [
          // Common for both iOS and macOS:
          kSecClass: kSecClassGenericPassword,
          kSecAttrLabel: label,
          kSecAttrDescription: description,
          kSecAttrAccount: account,
          kSecAttrService: service,
          kSecValueData: token.data(using: .utf8) as Any,
          kSecReturnPersistentRef: true,
          kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
          kSecAttrAccessGroup: AppInfoPlistConstants.appGroupId as CFString as Any,
        ]

        var ref: CFTypeRef?
        let ret = SecStatus(SecItemAdd(query as CFDictionary, &ref))
        guard ret.isSuccess else {
          continuation.resume(
            throwing: KeychainError.appleSecError(call: "SecItemAdd", status: ret))
          return
        }

        guard let savedPersistentRef = ref as? Data else {
          continuation.resume(throwing: KeychainError.nilResultFromAppleSecCall(call: "SecItemAdd"))
          return
        }
        continuation.resume(returning: savedPersistentRef)
        return
      }
    }
  }

  func update(token: Token) async throws {

    return try await withCheckedThrowingContinuation { [weak self] continuation in
      self?.workQueue.async { [weak self] in
        guard let self = self else {
          continuation.resume(throwing: KeychainError.securityError(.unexpectedError))
          return
        }

        let query: [CFString: Any] = [
          kSecClass: kSecClassGenericPassword,
          kSecAttrAccount: self.account,
          kSecAttrService: self.service,
        ]
        let attributesToUpdate = [
          kSecValueData: token.data(using: .utf8) as Any
        ]
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

  // This function is public because the tunnel needs to call it to get the token
  public func load(persistentRef: PersistentRef) async -> Token? {
    return await withCheckedContinuation { [weak self] continuation in
      self?.workQueue.async {
        let query =
          [
            kSecValuePersistentRef: persistentRef,
            kSecReturnData: true,
          ] as [CFString: Any]
        var result: CFTypeRef?
        let ret = SecStatus(SecItemCopyMatching(query as CFDictionary, &result))
        if ret.isSuccess,
          let resultData = result as? Data,
          let resultString = String(data: resultData, encoding: .utf8)
        {
          continuation.resume(returning: resultString)
        } else {
          continuation.resume(returning: nil)
        }
      }
    }
  }

  func search() async -> PersistentRef? {
    return await withCheckedContinuation { [weak self] continuation in
      guard let self = self else { return }
      self.workQueue.async {
        let query =
          [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: self.account,
            kSecAttrDescription: self.description,
            kSecAttrService: self.service,
            kSecReturnPersistentRef: true,
          ] as [CFString: Any]
        var result: CFTypeRef?
        let ret = SecStatus(SecItemCopyMatching(query as CFDictionary, &result))
        if ret.isSuccess, let tokenRef = result as? Data {
          continuation.resume(returning: tokenRef)
        } else {
          continuation.resume(returning: nil)
        }
      }
    }
  }

  private func securityError(_ status: OSStatus) -> Error {
    KeychainError.securityError(KeychainStatus(rawValue: status)!)
  }
}
