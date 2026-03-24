//
//  PacketTunnelProviderError.swift
//  (c) 2025 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

public enum PacketTunnelProviderError: Error {
  case tunnelConfigurationIsInvalid
  case firezoneIdIsInvalid
  case tokenNotFoundInKeychain
}
