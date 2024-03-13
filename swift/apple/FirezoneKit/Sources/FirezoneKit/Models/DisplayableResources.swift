//
//  DisplayableResources.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

// This models resources that are displayed in the UI

import Foundation

public class DisplayableResources {

  public struct Resource: Identifiable {
    public var id: String { address }
    public let name: String
    public let address: String

    public init(name: String, address: String) {
      self.name = name
      self.address = address
    }
  }

  public private(set) var version: UInt64
  public private(set) var versionString: String
  public private(set) var resources: [Resource]

  public init(version: UInt64, resources: [Resource]) {
    self.version = version
    self.versionString = "\(version)"
    self.resources = resources
  }

  public convenience init() {
    self.init(version: 0, resources: [])
  }

  public func update(resources: [Resource]) {
    self.version = self.version &+ 1  // Overflow is ok
    self.versionString = "\(version)"
    self.resources = resources
  }
}

extension DisplayableResources {
  public func toData() -> Data? {
    ("\(versionString),"
      + (resources.flatMap { [$0.name, $0.address] })
      .map { $0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) }.compactMap { $0 }
      .joined(separator: ",")).data(using: .utf8)
  }

  public convenience init?(from data: Data) {
    guard let components = String(data: data, encoding: .utf8)?.split(separator: ",") else {
      return nil
    }
    guard let versionString = components.first, let version = UInt64(versionString) else {
      return nil
    }
    var resources: [Resource] = []
    for index in stride(from: 2, to: components.count, by: 2) {
      guard let name = components[index - 1].removingPercentEncoding,
        let address = components[index].removingPercentEncoding
      else {
        continue
      }
      resources.append(Resource(name: name, address: address))
    }
    self.init(version: version, resources: resources)
  }

  public func versionStringToData() -> Data {
    versionString.data(using: .utf8)!
  }
}
