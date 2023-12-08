//
//  NetworkResource.swift
//  (c) 2023 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import FirezoneKit
import Foundation

public struct NetworkResource: Decodable {
  enum ResourceLocation {
    case dns(domain: String)
    case cidr(cidrAddress: String)

    func toString() -> String {
      switch self {
      case .dns(let domain): return domain
      case .cidr(let cidrAddress): return cidrAddress
      }
    }

    var domain: String? {
      switch self {
      case .dns(let domain): return domain
      case .cidr: return nil
      }
    }
  }

  let name: String
  let resourceLocation: ResourceLocation

  var displayableResource: DisplayableResources.Resource {
    DisplayableResources.Resource(name: name, location: resourceLocation.toString())
  }
}

// A DNS resource example:
//  {
//    "type": "dns",
//    "address": "app.posthog.com",
//    "name": "PostHog",
//  }
//
// A CIDR resource example:
//   {
//     "type": "cidr",
//     "address": "10.0.0.0/24",
//     "name": "AWS SJC VPC1",
//   }

extension NetworkResource {
  enum ResourceKeys: String, CodingKey {
    case type
    case address
    case name
  }

  enum DecodeError: Error {
    case invalidType(String)
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: ResourceKeys.self)
    let name = try container.decode(String.self, forKey: .name)
    let type = try container.decode(String.self, forKey: .type)
    let resourceLocation: ResourceLocation = try {
      switch type {
      case "dns":
        let domain = try container.decode(String.self, forKey: .address)
        return .dns(domain: domain)
      case "cidr":
        let address = try container.decode(String.self, forKey: .address)
        return .cidr(cidrAddress: address)
      default:
        throw DecodeError.invalidType(type)
      }
    }()
    self.init(name: name, resourceLocation: resourceLocation)
  }
}
