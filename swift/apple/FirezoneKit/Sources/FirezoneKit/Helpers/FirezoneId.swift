//
//  FirezoneId.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

/// A device identifier that stores a raw UUID and can produce
/// a SHA256-encoded form for Sentry/analytics via the Rust FFI.
public struct FirezoneId {
  /// The raw UUID string, as stored on disk.
  public let uuid: String

  public init(uuid: String) {
    self.uuid = uuid
  }

  /// The SHA256 hex-encoded form, for use in Sentry and analytics.
  public var encoded: String {
    hashDeviceId(id: uuid)
  }

  /// Generates a new firezone ID backed by a random UUID.
  public static func generate() -> FirezoneId {
    FirezoneId(uuid: UUID().uuidString)
  }
}
