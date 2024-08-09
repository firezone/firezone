//
//  Resource.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

// This models resources that are displayed in the UI

import Foundation

public struct Resource: Decodable, Identifiable, Equatable {
  public let id: String
  public var name: String
  public var address: String
  public var addressDescription: String?
  public var status: ResourceStatus
  public var sites: [Site]
  public var type: ResourceType
  public var canDisable: Bool

  public init(id: String, name: String, address: String, addressDescription: String?, status: ResourceStatus, sites: [Site], type: ResourceType, canToggle: Bool) {
    self.id = id
    self.name = name
    self.address = address
    self.addressDescription = addressDescription
    self.status = status
    self.sites = sites
    self.type = type
    self.canDisable = canToggle
  }
}

public enum ResourceStatus: String, Decodable {
  case offline = "Offline"
  case online = "Online"
  case unknown = "Unknown"

  public func toSiteStatus() -> String {
    switch self {
    case .offline:
      return "All Gateways offline"
    case .online:
      return "Gateway connected"
    case .unknown:
      return "No activity"
    }
  }

  // Longer explanation shown when hovering over the site status menu item
  public func toSiteStatusTooltip() -> String {
    switch self {
    case .offline:
      return "No healthy Gateways are online in this Site."
    case .online:
      return "You're connected to a healthy Gateway in this Site."
    case .unknown:
      return "No connection has been attempted to Resources in this Site. Access a Resource to establish a Gateway connection."
    }
  }
}

public enum ResourceType: String, Decodable {
  case dns = "dns"
  case cidr = "cidr"
  case ip = "ip"
}
