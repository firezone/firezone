//
//  DisconnectError.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

/// The errors the tunnel reports for having stopped, recovered from the `NSError` that
/// crosses from the network extension, which keeps only the domain, code and user info.
enum DisconnectError: Equatable {
  case connlib(ConnlibError.Code, reason: String, id: String)
  case packetTunnelProvider(PacketTunnelProviderError)
  case unknown

  init(_ error: any Error) {
    let nsError = error as NSError

    if nsError.domain == ConnlibError.errorDomain,
      let code = ConnlibError.Code(rawValue: nsError.code),
      let reason = nsError.userInfo["reason"] as? String,
      let id = nsError.userInfo["id"] as? String
    {
      self = .connlib(code, reason: reason, id: id)
    } else if nsError.domain == PacketTunnelProviderError.errorDomain,
      let error = PacketTunnelProviderError(rawValue: nsError.code)
    {
      self = .packetTunnelProvider(error)
    } else {
      self = .unknown
    }
  }
}
