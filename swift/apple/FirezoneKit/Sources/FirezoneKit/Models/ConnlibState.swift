//
//  ConnlibState.swift
//  © 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import CryptoKit
import Foundation

public struct ConnlibState: Encodable, Decodable {
  // swiftlint:disable:next discouraged_optional_collection
  private let resources: [FirezoneKit.Resource]?
  private let unreachableResources: Set<UnreachableResource>

  private static let encoder = PropertyListEncoder()
  private static let decoder = PropertyListDecoder()

  // Custom encoding to ensure deterministic hash by sorting the set
  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(resources, forKey: .resources)

    // Sort unreachable resources for deterministic encoding
    let sortedUnreachableResources = unreachableResources.sorted { lhs, rhs in
      if lhs.resourceId != rhs.resourceId {
        return lhs.resourceId < rhs.resourceId
      }
      // If resourceIds are equal, sort by reason
      return lhs.reason.sortValue < rhs.reason.sortValue
    }
    try container.encode(sortedUnreachableResources, forKey: .unreachableResources)
  }

  private enum CodingKeys: String, CodingKey {
    case resources
    case unreachableResources
  }

  /// Decodes a ConnlibState from data and returns both the state and its hash
  /// - Parameter data: The encoded data to decode
  /// - Returns: A tuple containing the decoded state and its hash
  /// - Throws: If decoding fails
  public static func decode(
    from data: Data
  ) throws -> (state: ConnlibState, hash: Data) {
    let hash = Data(SHA256.hash(data: data))
    let state = try Self.decoder.decode(ConnlibState.self, from: data)
    return (state: state, hash: hash)
  }

  /// Creates a ConnlibState from resources and returns encoded data only if different from currentHash
  /// - Parameters:
  ///   - resources: Optional array of resources
  ///   - unreachableResources: Set of unreachable resources
  ///   - currentHash: The hash to compare against
  /// - Returns: The encoded data if the hash differs, nil otherwise
  /// - Throws: If encoding fails
  public static func encodeIfChanged(
    resources: [FirezoneKit.Resource]?,
    unreachableResources: Set<UnreachableResource>,
    comparedTo currentHash: Data
  ) throws -> Data? {
    let state = ConnlibState(resources: resources, unreachableResources: unreachableResources)
    let encodedData = try Self.encoder.encode(state)
    let newHash = Data(SHA256.hash(data: encodedData))

    return newHash == currentHash ? nil : encodedData
  }

}

public enum UnreachableReason: Hashable, Encodable, Decodable {
  case offline
  case versionMismatch

  // Helper for sorting
  var sortValue: Int {
    switch self {
    case .offline: return 0
    case .versionMismatch: return 1
    }
  }
}

public struct UnreachableResource: Hashable, Encodable, Decodable {
  public let resourceId: String
  public let reason: UnreachableReason

  public init(resourceId: String, reason: UnreachableReason) {
    self.resourceId = resourceId
    self.reason = reason
  }
}
