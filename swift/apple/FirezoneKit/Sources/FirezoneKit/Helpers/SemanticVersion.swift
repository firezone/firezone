//
//  UpdateNotification.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation


public struct VersionInfo: Decodable {
  let apple: SemVerString

  public static func from(data: Data?) -> VersionInfo? {
    guard let data = data,
      let versionString = String(data: data, encoding: .utf8),
      let versionString = versionString.data(using: .utf8),
      let versionInfo = try? JSONDecoder().decode(VersionInfo.self, from: versionString) else {
        return nil
    }

    return versionInfo
  }
}

struct SemVerString: Decodable, Comparable {
    private let originalString: String
    private let semVer: SemanticVersion

    private init(originalString: String, semVer: SemanticVersion) {
        self.originalString = originalString
        self.semVer = semVer
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.singleValueContainer()
      let versionString = try container.decode(String.self)

      guard let parsed = SemanticVersion.from(string: versionString) else {
          throw DecodingError.dataCorruptedError(in: container,
                                                 debugDescription: "Invalid SemVer string format")
      }

      originalString = versionString
      semVer = parsed
    }

    public static func from(string: String) -> SemVerString? {
      guard let parsed = SemanticVersion.from(string: string) else { return nil }
      return SemVerString(originalString: string, semVer: parsed)
    }

    public func versionString() -> String {
        originalString
    }

    static func < (lhs: SemVerString, rhs: SemVerString) -> Bool {
        lhs.semVer < rhs.semVer
    }

    static func == (lhs: SemVerString, rhs: SemVerString) -> Bool {
        lhs.semVer == rhs.semVer
    }
}

private struct SemanticVersion: Comparable {
  let major: Int
  let minor: Int
  let patch: Int

  init(major: Int, minor: Int, patch: Int) {
      self.major = major
      self.minor = minor
      self.patch = patch
  }

  // This doesn't conform to the full semver spec but it's enough for our use-case
  static func parse(versionString: String) -> (major: Int, minor: Int, patch: Int)? {
      guard let coreVersion = versionString.components(separatedBy: ["+", "-"]).first else {
        return nil
      }

      let components = coreVersion.split(separator: ".")
      guard components.count == 3,
            let major = Int(components[0]),
            let minor = Int(components[1]),
            let patch = Int(components[2]) else {
          return nil
      }
      return (major, minor, patch)
  }

  static func from(string: String) -> SemanticVersion? {
      guard let parsed = parse(versionString: string) else {
          return nil
      }
      return SemanticVersion(major: parsed.major, minor: parsed.minor, patch: parsed.patch)
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
