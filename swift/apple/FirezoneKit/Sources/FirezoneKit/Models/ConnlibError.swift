//
//  ConnlibError.swift
//  © 2025 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

/// What proved the session's identity to the portal.
public enum SessionAuthenticationMode: String, Sendable {
  /// A token the user obtained through web sign-in.
  case token
  /// A client certificate the administrator installed on the VPN profile.
  case certificate
}

public enum ConnlibError: Swift.Error {
  case sessionExpired(String, id: String = UUID().uuidString)
  case disconnected(
    String,
    authenticationMode: SessionAuthenticationMode = .token,
    id: String = UUID().uuidString
  )

  /// Key under which `errorUserInfo` carries the session's authentication mode.
  public static let authenticationModeKey = "authenticationMode"

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
    case .disconnected(let reason, let authenticationMode, let id):
      return [
        "reason": reason,
        "id": id,
        Self.authenticationModeKey: authenticationMode.rawValue,
      ]
    }
  }
}
