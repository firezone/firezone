//
//  ConnlibError.swift
//  © 2025 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

public enum ConnlibError: Swift.Error {
  case sessionExpired(String, id: String = UUID().uuidString)
  case disconnected(String, id: String = UUID().uuidString)

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
    case .sessionExpired(let reason, let id), .disconnected(let reason, let id):
      return [
        "reason": reason,
        "id": id,
      ]
    }
  }
}
