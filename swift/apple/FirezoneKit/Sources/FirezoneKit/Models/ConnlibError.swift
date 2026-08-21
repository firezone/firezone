//
//  ConnlibError.swift
//  © 2025 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

public enum ConnlibError: Swift.Error {
  case sessionExpired(String, id: String = UUID().uuidString)
  case disconnected(
    String,
    isCertificateError: Bool = false,
    id: String = UUID().uuidString
  )

  /// Key under which `errorUserInfo` carries whether the client certificate is what failed.
  public static let isCertificateErrorKey = "isCertificateError"

  public enum Code: Int {
    case sessionExpired = 0
    case disconnected = 1
  }

  public var code: Code {
    switch self {
    case .sessionExpired:
      return .sessionExpired
    case .disconnected:
      return .disconnected
    }
  }
}

extension ConnlibError: CustomNSError {
  public static var errorDomain: String {
    return "FirezoneKit.ConnlibError"
  }

  public var errorCode: Int { code.rawValue }

  public var errorUserInfo: [String: Any] {
    switch self {
    case .sessionExpired(let reason, let id):
      return [
        "reason": reason,
        "id": id,
      ]
    case .disconnected(let reason, let isCertificateError, let id):
      return [
        "reason": reason,
        "id": id,
        Self.isCertificateErrorKey: isCertificateError,
      ]
    }
  }
}
