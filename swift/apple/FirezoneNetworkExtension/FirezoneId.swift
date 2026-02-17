//
//  FirezoneId.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

/// A device identifier that stores a raw UUID and can produce
/// a SHA256-encoded form for Sentry/analytics via the Rust FFI.
struct FirezoneId: Sendable {
  /// The raw UUID string, as stored on disk.
  let uuid: String

  /// The SHA256 hex-encoded form, for use in Sentry and analytics.
  var encoded: String {
    hashDeviceId(id: uuid)
  }

  /// Generates a new firezone ID backed by a random UUID.
  static func generate() -> FirezoneId {
    FirezoneId(uuid: UUID().uuidString)
  }
}
