import Foundation

public struct SemanticVersion: Comparable, CustomStringConvertible, Codable, Sendable {
  public var description: String {
    return "\(major).\(minor).\(patch)"
  }

  public enum Error: Swift.Error {
    case invalidVersionString
  }

  private let major: Int
  private let minor: Int
  private let patch: Int

  // This doesn't conform to the full semver spec but it's enough for our use-case
  public init(_ version: String) throws {
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

  public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
    if lhs.major != rhs.major {
      return lhs.major < rhs.major
    }

    if lhs.minor != rhs.minor {
      return lhs.minor < rhs.minor
    }

    return lhs.patch < rhs.patch
  }

  public static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
    return lhs.major == rhs.major && lhs.minor == rhs.minor && lhs.patch == rhs.patch
  }

  public func save(to userDefaults: UserDefaults, forKey key: String) {
    let encoder = PropertyListEncoder()

    do {
      let data = try encoder.encode(self)
      userDefaults.set(data, forKey: key)
    } catch {
      Log.error(error)
    }
  }

  public init?(from userDefaults: UserDefaults, forKey key: String) {
    guard let data = userDefaults.data(forKey: key) else { return nil }

    let decoder = PropertyListDecoder()

    do {
      self = try decoder.decode(SemanticVersion.self, from: data)
    } catch {
      Log.error(error)
      return nil
    }
  }
}
