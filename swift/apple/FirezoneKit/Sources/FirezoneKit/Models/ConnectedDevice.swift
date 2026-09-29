//
//  ConnectedDevice.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

// Models a peer device the client currently has a live connection to, shown in the UI.

import Foundation

public struct ConnectedDevice: Codable, Identifiable, Hashable, Sendable {
  public let id: String
  public let name: String
  public let tunIPv4: String
  public let tunIPv6: String

  public init(id: String, name: String, tunIPv4: String, tunIPv6: String) {
    self.id = id
    self.name = name
    self.tunIPv4 = tunIPv4
    self.tunIPv6 = tunIPv6
  }
}
