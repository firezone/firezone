//
//  ConnectedDevice.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

// Models a peer device the client currently has a live connection to, shown in the UI.

import Foundation

public struct ConnectedDevice: Codable, Identifiable, Hashable, Sendable {
  /// Appended to a device's slug to form the domain it answers DNS at.
  public static let domainSuffix = ".firezone.network"

  public let id: String
  public let name: String
  public let slug: String
  public let tunIPv4: String
  public let tunIPv6: String

  public var domain: String { slug + Self.domainSuffix }

  public init(id: String, name: String, slug: String, tunIPv4: String, tunIPv6: String) {
    self.id = id
    self.name = name
    self.slug = slug
    self.tunIPv4 = tunIPv4
    self.tunIPv6 = tunIPv6
  }
}
