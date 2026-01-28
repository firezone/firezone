//
//  Resource.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

// This models resources that are displayed in the UI

import Foundation

#if os(macOS)
  import AppKit
#endif

class StatusSymbol {
  static let enabled: String = "<->"
  static let disabled: String = "—"
}

public enum ResourceList: Sendable {
  case loading
  case loaded([Resource])

  public func asArray() -> [Resource] {
    switch self {
    case .loading:
      []
    case .loaded(let ele):
      ele
    }
  }
}

public struct Resource: Codable, Identifiable, Equatable, Sendable {
  public let id: String
  public var name: String
  public var address: String?
  public var addressDescription: String?
  public var status: ResourceStatus
  public var sites: [Site]
  public var type: ResourceType

  public init(
    id: String,
    name: String,
    address: String?,
    addressDescription: String?,
    status: ResourceStatus,
    sites: [Site],
    type: ResourceType
  ) {
    self.id = id
    self.name = name
    self.address = address
    self.addressDescription = addressDescription
    self.status = status
    self.sites = sites
    self.type = type
  }

  public func isInternetResource() -> Bool {
    self.type == ResourceType.internet
  }
}

public enum ResourceStatus: String, Codable, Sendable {
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
      return """
        No connection has been attempted to Resources in this Site.
        Access a Resource to establish a Gateway connection.
        """
    }
  }

  #if os(macOS)
    /// Returns the system status icon for this resource status
    public var statusIcon: NSImage? {
      switch self {
      case .online:
        return NSImage(named: NSImage.statusAvailableName)
      case .offline:
        return NSImage(named: NSImage.statusUnavailableName)
      case .unknown:
        return NSImage(named: NSImage.statusNoneName)
      }
    }
  #endif
}

public enum ResourceType: String, Codable, Sendable {
  case dns
  case cidr
  case ip
  case internet
}
