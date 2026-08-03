//
//  ConnlibState.swift
//  © 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import CryptoKit
import Foundation

public struct ConnlibState: Encodable, Decodable {
  // swiftlint:disable:next discouraged_optional_collection
  public let resources: [FirezoneKit.Resource]?
  public let connectedDevices: [FirezoneKit.ConnectedDevice]
  public let isLogStreamingActive: Bool

  private enum CodingKeys: String, CodingKey {
    case resources
    case connectedDevices
    case isLogStreamingActive
  }

  public init(
    resources: [FirezoneKit.Resource]?,  // swiftlint:disable:this discouraged_optional_collection
    connectedDevices: [FirezoneKit.ConnectedDevice],
    isLogStreamingActive: Bool
  ) {
    self.resources = resources
    self.connectedDevices = connectedDevices
    self.isLogStreamingActive = isLogStreamingActive
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    resources = try container.decodeIfPresent([FirezoneKit.Resource].self, forKey: .resources)
    connectedDevices =
      try container.decodeIfPresent([FirezoneKit.ConnectedDevice].self, forKey: .connectedDevices)
      ?? []
    isLogStreamingActive =
      try container.decodeIfPresent(Bool.self, forKey: .isLogStreamingActive) ?? false
  }

  /// A stable content hash used to avoid sending an unchanged snapshot on every poll.
  public func contentHash() throws -> Data {
    let encodedData = try PropertyListEncoder().encode(self)
    return Data(SHA256.hash(data: encodedData))
  }
}

public struct StatePollRequest: Codable, Sendable {
  public let stateHash: Data

  public init(stateHash: Data) {
    self.stateHash = stateHash
  }
}

public struct StatePollResponse: Codable {
  // `state` and `stateHash` are both nil when the snapshot has not changed.
  public let state: ConnlibState?
  public let stateHash: Data?
  public let notifications: [UnreachableResource]

  public init(
    state: ConnlibState?,
    stateHash: Data?,
    notifications: [UnreachableResource]
  ) {
    self.state = state
    self.stateHash = stateHash
    self.notifications = notifications
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
