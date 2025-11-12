//
//  MenuBarIconProvider.swift
//  (c) 2025 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import NetworkExtension

/// Provides menu bar icon names from asset catalog based on VPN status and notifications
@MainActor
public struct MenuBarIconProvider {
  /// Returns the appropriate icon name from asset catalog for the current state
  /// - Parameters:
  ///   - status: Current VPN connection status
  ///   - updateAvailable: Whether an update is available
  /// - Returns: Icon name string from Assets.xcassets
  public static func icon(for status: NEVPNStatus?, updateAvailable: Bool) -> String {
    switch status {
    case nil, .invalid, .disconnected:
      return updateAvailable ? "MenuBarIconSignedOutNotification" : "MenuBarIconSignedOut"
    case .connected:
      return updateAvailable
        ? "MenuBarIconSignedInConnectedNotification" : "MenuBarIconSignedInConnected"
    case .connecting, .disconnecting, .reasserting:
      return "MenuBarIconConnecting3"
    @unknown default:
      return "MenuBarIconSignedOut"
    }
  }
}
