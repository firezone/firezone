//
//  ConnlibError.swift
//  © 2025 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

public enum SessionAuthenticationMode: String, Sendable {
  case token
  case x509

  static let unusableX509PrivateKeyMessage =
    "The VPN profile references an X.509 certificate that isn't usable. Your administrator needs to enable “Allow access to all apps” for its private key."

  public func failureMessage(_ reason: String?) -> String {
    let detail = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
    let message: String
    if self == .x509,
      let detail,
      detail.contains(Self.unusableX509PrivateKeyMessage)
    {
      // The platform callback and TLS stack add diagnostic context around this
      // known administrator-actionable failure. Keep that context in logs, but
      // show only the actionable sentence to the user.
      message = Self.unusableX509PrivateKeyMessage
    } else if let detail, !detail.isEmpty {
      message = detail
    } else {
      message = "Firezone could not establish a connection."
    }

    guard self == .x509 else { return message }
    return "\(message)\n\nContact your administrator for support."
  }
}

public enum ConnlibError: Swift.Error {
  case sessionExpired(String, id: String = UUID().uuidString)
  case disconnected(
    String,
    authenticationMode: SessionAuthenticationMode? = nil,
    id: String = UUID().uuidString
  )

  public static let authenticationModeUserInfoKey = "authenticationMode"

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
      var userInfo: [String: Any] = [
        "reason": reason,
        "id": id,
      ]
      userInfo[Self.authenticationModeUserInfoKey] = authenticationMode?.rawValue
      return userInfo
    }
  }
}
