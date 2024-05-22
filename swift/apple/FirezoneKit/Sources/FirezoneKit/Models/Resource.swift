//
//  Resource.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

// This models resources that are displayed in the UI

import Foundation

public struct Resource: Decodable, Identifiable {
  public let id: String
  public var name: String
  public var address: String
  public var addressDescription: String?
  public var status: ResourceStatus
  public var sites: [Site]
  public var type: ResourceType

  public init(id: String, name: String, address: String, addressDescription: String?, status: ResourceStatus, sites: [Site], type: ResourceType) {
    self.id = id
    self.name = name
    self.address = address
    self.addressDescription = addressDescription
    self.status = status
    self.sites = sites
    self.type = type
  }
}

public enum ResourceStatus: String, Decodable {
  case offline = "Offline"
  case online = "Online"
  case unknown = "Unknown"
}

public enum ResourceType: String, Decodable {
  case dns = "dns"
  case cidr = "cidr"
  case ip = "ip"
}
