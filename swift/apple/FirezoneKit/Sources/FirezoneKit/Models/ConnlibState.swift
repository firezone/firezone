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
  /// The account and actor the portal named in `init`, `nil` until it arrives.
  public let accountSlug: String?
  public let actorName: String?

  private enum CodingKeys: String, CodingKey {
    case resources
    case connectedDevices
    case isLogStreamingActive
    case accountSlug
    case actorName
  }

  private init(
    resources: [FirezoneKit.Resource]?,  // swiftlint:disable:this discouraged_optional_collection
    connectedDevices: [FirezoneKit.ConnectedDevice],
    isLogStreamingActive: Bool,
    accountSlug: String?,
    actorName: String?
  ) {
    self.resources = resources
    self.connectedDevices = connectedDevices
    self.isLogStreamingActive = isLogStreamingActive
    self.accountSlug = accountSlug
    self.actorName = actorName
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    resources = try container.decodeIfPresent([FirezoneKit.Resource].self, forKey: .resources)
    connectedDevices =
      try container.decodeIfPresent([FirezoneKit.ConnectedDevice].self, forKey: .connectedDevices)
      ?? []
    isLogStreamingActive =
      try container.decodeIfPresent(Bool.self, forKey: .isLogStreamingActive) ?? false
    accountSlug = try container.decodeIfPresent(String.self, forKey: .accountSlug)
    actorName = try container.decodeIfPresent(String.self, forKey: .actorName)
  }

  /// A state snapshot that is known to differ from the hash it was compared against.
  public struct Change {
    let state: ConnlibState
    let hash: Data

    fileprivate init(state: ConnlibState, hash: Data) {
      self.state = state
      self.hash = hash
    }
  }

  /// Creates a state snapshot only when its encoded content differs from `currentHash`.
  public static func makeIfChanged(
    resources: [FirezoneKit.Resource]?,  // swiftlint:disable:this discouraged_optional_collection
    connectedDevices: [FirezoneKit.ConnectedDevice],
    isLogStreamingActive: Bool,
    accountSlug: String? = nil,
    actorName: String? = nil,
    comparedTo currentHash: Data
  ) throws -> Change? {
    let state = ConnlibState(
      resources: resources,
      connectedDevices: connectedDevices,
      isLogStreamingActive: isLogStreamingActive,
      accountSlug: accountSlug,
      actorName: actorName
    )
    let encodedData = try PropertyListEncoder().encode(state)
    let hash = Data(SHA256.hash(data: encodedData))

    guard hash != currentHash else { return nil }

    return Change(state: state, hash: hash)
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
    stateChange: ConnlibState.Change?,
    notifications: [UnreachableResource]
  ) {
    self.state = stateChange?.state
    self.stateHash = stateChange?.hash
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
