//
//  PacketTunnelProviderError.swift
//  (c) 2025 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

public enum PacketTunnelProviderError: Error, CustomNSError, LocalizedError {
  case providerConfigurationIsInvalid
  case firezoneIdIsInvalid
  case credentialNotConfigured

  public static var errorDomain: String {
    "FirezoneKit.PacketTunnelProviderError"
  }

  public var errorCode: Int {
    switch self {
    case .providerConfigurationIsInvalid: 0
    case .firezoneIdIsInvalid: 1
    case .credentialNotConfigured: 2
    }
  }

  public var errorDescription: String? { message }

  /// `LocalizedError` is a Swift witness, so it is lost when the error crosses to
  /// another process: the network extension hands one to its completion handler and
  /// the app receives an `NSError` carrying only the domain and code, which Foundation
  /// renders as "The operation couldn't be completed." User info survives the trip.
  public var errorUserInfo: [String: Any] {
    [NSLocalizedDescriptionKey: message]
  }

  private var message: String {
    switch self {
    case .providerConfigurationIsInvalid:
      "The VPN profile is missing the settings the tunnel needs to start."
    case .firezoneIdIsInvalid:
      "The device identifier could not be read."
    case .credentialNotConfigured:
      "A sign-in token is not configured."
    }
  }
}
