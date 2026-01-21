//
//  UnreachableSite.swift
//  © 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

public struct ConnlibState: Encodable, Decodable {
  public let resources: [FirezoneKit.Resource]?
  public let unreachableResources: Set<UnreachableResource>

  public init(resources: [FirezoneKit.Resource]?, unreachableResources: Set<UnreachableResource>) {
    self.resources = resources
    self.unreachableResources = unreachableResources
  }
}

public enum UnreachableReason: Hashable, Encodable, Decodable {
  case Offline
  case VersionMismatch
}

public struct UnreachableResource: Hashable, Encodable, Decodable {
  public let resourceId: String
  public let reason: UnreachableReason

  public init(resourceId: String, reason: UnreachableReason) {
    self.resourceId = resourceId
    self.reason = reason
  }
}
