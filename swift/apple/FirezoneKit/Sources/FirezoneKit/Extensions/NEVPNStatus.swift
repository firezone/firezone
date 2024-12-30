//
//  NEVPNStatus.swift
//
//
//  Created by Jamil Bou Kheir on 4/2/24.
//

import NetworkExtension

/// Make NEVPNStatus convertible to a string
extension NEVPNStatus: @retroactive CustomStringConvertible {
  public var description: String {
    switch self {
    case .disconnected: return "Disconnected"
    case .invalid: return "Invalid"
    case .connected: return "Connected"
    case .connecting: return "Connecting…"
    case .disconnecting: return "Disconnecting…"
    case .reasserting: return "No network connectivity"
    @unknown default: return "Unknown"
    }
  }
}
