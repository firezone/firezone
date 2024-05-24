//
//  Site.swift
//
//
//  Created by Jamil Bou Kheir on 5/21/24.
//

import Foundation

public struct Site: Decodable, Identifiable {
  public let id: String
  public var name: String

  public init(id: String, name: String) {
    self.id = id
    self.name = name
  }
}

extension Site: Equatable {
  public static func == (lhs: Site, rhs: Site) -> Bool {
    return lhs.id == rhs.id && lhs.name == rhs.name
  }
}
