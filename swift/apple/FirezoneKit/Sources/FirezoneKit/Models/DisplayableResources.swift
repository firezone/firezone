//
//  DisplayableResources.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

// This models resources that are displayed in the UI

import Foundation

public class DisplayableResources {

  public struct Resource: Identifiable {
    public var id: String { location }
    public let name: String
    public let location: String

    public init(name: String, location: String) {
      self.name = name
      self.location = location
    }
  }

  public private(set) var version: UInt64
  public private(set) var versionString: String
  public private(set) var orderedResources: [Resource]

  public init(version: UInt64, resources: [Resource]) {
    self.version = version
    self.versionString = "\(version)"
    self.orderedResources = resources
  }

  public convenience init() {
    self.init(version: 0, resources: [])
  }

  public func update(resources: [Resource]) {
    self.version = self.version &+ 1  // Overflow is ok
    self.versionString = "\(version)"
    self.orderedResources = resources
  }
}

extension DisplayableResources {
  public func toData() -> Data? {
    ("\(versionString),"
      + (orderedResources.flatMap { [$0.name, $0.location] })
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
        let location = components[index].removingPercentEncoding
      else {
        continue
      }
      resources.append(Resource(name: name, location: location))
    }
    self.init(version: version, resources: resources)
  }

  public func versionStringToData() -> Data {
    versionString.data(using: .utf8)!
  }
}
