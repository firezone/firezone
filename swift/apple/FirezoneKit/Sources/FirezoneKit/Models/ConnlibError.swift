//
//  ConnlibError.swift
//  © 2025 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

public enum ConnlibError: Swift.Error {
  case sessionExpired(String, id: String = UUID().uuidString)
}

extension ConnlibError: CustomNSError {
  public static var errorDomain: String {
    return "FirezoneKit.ConnlibError"
  }

  public var errorCode: Int {
    switch self {
    case .sessionExpired:
      return 0
    }
  }

  public var errorUserInfo: [String: Any] {
    switch self {
    case .sessionExpired(let reason, let id):
      return [
        "reason": reason,
        "id": id,
      ]
    }
  }
}
