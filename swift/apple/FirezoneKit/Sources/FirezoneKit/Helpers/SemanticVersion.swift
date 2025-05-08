//
//  UpdateNotification.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//
// TODO: This file can be deleted once most users have upgraded past 1.4.14

import Foundation

struct SemanticVersion: Comparable, CustomStringConvertible, Codable {
  var description: String {
    return "\(major).\(minor).\(patch)"
  }

  enum Error: Swift.Error {
    case invalidVersionString
  }

  private let major: Int
  private let minor: Int
  private let patch: Int

  // This doesn't conform to the full semver spec but it's enough for our use-case
  init(_ version: String) throws {
    guard let coreVersion = version.components(separatedBy: ["+", "-"]).first
    else {
      throw Error.invalidVersionString
    }

    let components = coreVersion.split(separator: ".")

    guard components.count == 3
    else {
      throw Error.invalidVersionString
    }

    guard let major = Int(components[0]),
          let minor = Int(components[1]),
          let patch = Int(components[2])
    else {
      throw Error.invalidVersionString
    }

    self.major = major
    self.minor = minor
    self.patch = patch
  }

  static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
    if lhs.major != rhs.major {
      return lhs.major < rhs.major
    }

    if lhs.minor != rhs.minor {
      return lhs.minor < rhs.minor
    }

    return lhs.patch < rhs.patch
  }

  static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
    return lhs.major == rhs.major &&
    lhs.minor == rhs.minor &&
    lhs.patch == rhs.patch
  }
}
