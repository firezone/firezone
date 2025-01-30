//
//  FirezoneId.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//
//  Convenience wrapper for working with our firezone-id file stored by the
//  tunnel process.

import Foundation

/// Prior to 1.4.0, our firezone-id was saved in a file accessible to both the
/// app and tunnel process. Starting with 1.4.0,
/// the macOS client uses a system extension, which makes sharing folders with
/// the app cumbersome, so we move to persisting the firezone-id only from the
/// tunnel process since that is the only place it's used.
///
/// Can be refactored to remove the Version enum all clients >= 1.4.0
public struct FirezoneId {
  public enum Version {
    case pre140
    case post140
  }

  public static func save(_ id: String) {
    guard let fileURL = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: BundleHelper.appGroupId)?
      .appendingPathComponent("firezone-id")
    else {
      // Nothing we can do about disk errors
      return
    }

    try? id.write(
      to: fileURL,
      atomically: true,
      encoding: .utf8
    )
  }

  public static func load(_ version: Version) -> String? {
    let appGroupId = switch version {
    case .post140:
      BundleHelper.appGroupId
    case .pre140:
#if os(macOS)
      "47R2M6779T.group.dev.firezone.firezone"
#elseif os(iOS)
      "group.dev.firezone.firezone"
#endif
    }

    guard let containerURL =
            FileManager.default.containerURL(
              forSecurityApplicationGroupIdentifier: appGroupId),
          let id =
            try? String(
              contentsOf: containerURL.appendingPathComponent("firezone-id"))
    else {
      return nil
    }

    return id
  }
}
