//
//  SharedAccess.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

public struct SharedAccess {
  private static let applicationSupportFolderName = "Application Support"
  private static let keepAppRunningSentinelFileName = ".running"

  public static var baseFolderURL: URL {
    guard
      let url = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: BundleHelper.appGroupId)
    else {
      fatalError("Shared folder unavailable")
    }
    return url
  }

  public static var applicationSupportFolderURL: URL? {
    let url =
      baseFolderURL
      .appendingPathComponent("Library")
      .appendingPathComponent(applicationSupportFolderName)
    guard ensureDirectoryExists(at: url.path) else {
      return nil
    }
    return url
  }

  public static var cacheFolderURL: URL? {
    let url = baseFolderURL.appendingPathComponent("Library").appendingPathComponent("Caches")
    guard ensureDirectoryExists(at: url.path) else {
      return nil
    }
    return url
  }

  public static var logFolderURL: URL? {
    if let url = cacheFolderURL?.appendingPathComponent("logs") {
      guard ensureDirectoryExists(at: url.path) else {
        return nil
      }
      return url
    }
    NSLog("Can't access cacheFolderURL to create logFolderURL")
    return nil
  }

  public static var connlibLogFolderURL: URL? {
    if let url = logFolderURL?.appendingPathComponent("connlib") {
      guard ensureDirectoryExists(at: url.path) else {
        return nil
      }
      return url
    }
    NSLog("Can't access logFolderURL to create connlibLogFolderURL")
    return nil
  }

  public static var appLogFolderURL: URL? {
    if let url = logFolderURL?.appendingPathComponent("app") {
      guard ensureDirectoryExists(at: url.path) else {
        return nil
      }
      return url
    }
    NSLog("Can't access logFolderURL to create appLogFolderURL")
    return nil
  }

  public static var tunnelLogFolderURL: URL? {
    if let url = logFolderURL?.appendingPathComponent("tunnel") {
      guard ensureDirectoryExists(at: url.path) else {
        return nil
      }
      return url
    }
    NSLog("Can't access logFolderURL to create tunnelLogFolderURL")
    return nil
  }

  public static var providerStopReasonURL: URL {
    baseFolderURL.appendingPathComponent("reason")
  }

  public static var keepAppRunningSentinelURL: URL? {
    applicationSupportFolderURL?.appendingPathComponent(keepAppRunningSentinelFileName)
  }

  @discardableResult
  public static func markAppRunning() -> Bool {
    guard let sentinelURL = keepAppRunningSentinelURL else { return false }
    do {
      try Data().write(to: sentinelURL, options: .atomic)
      return true
    } catch {
      return false
    }
  }

  @discardableResult
  public static func clearAppRunning() -> Bool {
    guard let sentinelURL = keepAppRunningSentinelURL else { return false }

    guard FileManager.default.fileExists(atPath: sentinelURL.path) else {
      return true
    }

    do {
      try FileManager.default.removeItem(at: sentinelURL)
      return true
    } catch {
      return false
    }
  }

  public static func ensureDirectoryExists(at path: String) -> Bool {
    let fileManager = FileManager.default
    do {
      var isDirectory: ObjCBool = false
      if fileManager.fileExists(atPath: path, isDirectory: &isDirectory) {
        if isDirectory.boolValue {
          return true
        } else {
          try fileManager.removeItem(atPath: path)
        }
      }
      try fileManager.createDirectory(atPath: path, withIntermediateDirectories: true)
      return true
    } catch {
      NSLog("Error while ensuring directory '\(path)' exists: \(error)")
      return false
    }
  }
}
