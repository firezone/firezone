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

  public var errorDescription: String? {
    switch self {
    case .providerConfigurationIsInvalid:
      return "The VPN profile is missing the settings the tunnel needs to start."
    case .firezoneIdIsInvalid:
      return "The device identifier could not be read."
    case .credentialNotConfigured:
      return "Neither a sign-in token nor a client certificate is configured."
    }
  }
}
