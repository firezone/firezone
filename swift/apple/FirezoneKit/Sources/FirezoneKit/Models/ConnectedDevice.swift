//
//  ConnectedDevice.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

// Models a peer device the client currently has a live connection to, shown in the UI.

import Foundation

public struct ConnectedDevice: Codable, Identifiable, Equatable, Sendable {
  public let id: String
  public let tunneledIPv4: String
  public let pools: [String]

  public init(id: String, tunneledIPv4: String, pools: [String]) {
    self.id = id
    self.tunneledIPv4 = tunneledIPv4
    self.pools = pools
  }
}
