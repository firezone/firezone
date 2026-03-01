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
  private let unreachableResources: [UnreachableResource]
  private let isLogStreamingActive: Bool

  private enum CodingKeys: String, CodingKey {
    case resources
    case unreachableResources
    case isLogStreamingActive
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    resources = try container.decodeIfPresent([FirezoneKit.Resource].self, forKey: .resources)
    unreachableResources = try container.decode([UnreachableResource].self, forKey: .unreachableResources)
    isLogStreamingActive = try container.decodeIfPresent(Bool.self, forKey: .isLogStreamingActive) ?? false
  }

  private static let encoder = PropertyListEncoder()
  private static let decoder = PropertyListDecoder()

  public struct DecodedState {
    public let resources: [FirezoneKit.Resource]?  // swiftlint:disable:this discouraged_optional_collection
    public let unreachableResources: [UnreachableResource]
    public let isLogStreamingActive: Bool
    public let hash: Data
  }

  /// Decodes a ConnlibState from data and returns the fields and hash.
  /// - Parameter data: The encoded data to decode
  /// - Throws: If decoding fails
  public static func decode(from data: Data) throws -> DecodedState {
    let hash = Data(SHA256.hash(data: data))
    let state = try Self.decoder.decode(ConnlibState.self, from: data)
    return DecodedState(
      resources: state.resources,
      unreachableResources: state.unreachableResources,
      isLogStreamingActive: state.isLogStreamingActive,
      hash: hash
    )
  }

  /// Creates a ConnlibState from resources and returns encoded data only if different from currentHash
  /// - Parameters:
  ///   - resources: Optional array of resources
  ///   - unreachableResources: Set of unreachable resources
  ///   - isLogStreamingActive: Whether the NE has log streaming enabled
  ///   - currentHash: The hash to compare against
  /// - Returns: The encoded data if the hash differs, nil otherwise
  /// - Throws: If encoding fails
  public static func encodeIfChanged(
    resources: [FirezoneKit.Resource]?,  // swiftlint:disable:this discouraged_optional_collection
    unreachableResources: [UnreachableResource],
    isLogStreamingActive: Bool,
    comparedTo currentHash: Data
  ) throws -> Data? {
    let state = ConnlibState(
      resources: resources, unreachableResources: unreachableResources,
      isLogStreamingActive: isLogStreamingActive)
    let encodedData = try Self.encoder.encode(state)
    let newHash = Data(SHA256.hash(data: encodedData))

    return newHash == currentHash ? nil : encodedData
  }

}

public enum UnreachableReason: Hashable, Encodable, Decodable {
  case offline
  case versionMismatch
}

public struct UnreachableResource: Hashable, Encodable, Decodable {
  public let resourceId: String
  public let reason: UnreachableReason

  public init(resourceId: String, reason: UnreachableReason) {
    self.resourceId = resourceId
    self.reason = reason
  }
}
