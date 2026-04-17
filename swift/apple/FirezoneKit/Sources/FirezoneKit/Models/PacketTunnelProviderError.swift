//
//  PacketTunnelProviderError.swift
//  (c) 2025 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

public enum PacketTunnelProviderError: Error, CustomNSError {
  case tunnelConfigurationIsInvalid
  case firezoneIdIsInvalid
  case tokenNotFoundInKeychain

  public static var errorDomain: String {
    "FirezoneKit.PacketTunnelProviderError"
  }

  public var errorCode: Int {
    switch self {
    case .tunnelConfigurationIsInvalid: 0
    case .firezoneIdIsInvalid: 1
    case .tokenNotFoundInKeychain: 2
    }
  }
}
