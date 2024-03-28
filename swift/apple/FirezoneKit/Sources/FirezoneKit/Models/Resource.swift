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
  public var type: String

  public init(id: String, name: String, address: String, type: String) {
    self.id = id
    self.name = name
    self.address = address
    self.type = type
  }
}
