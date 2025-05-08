//
//  Bundle.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

public enum BundleHelper {
  static func isAppStore() -> Bool {
    if let receiptURL = Bundle.main.appStoreReceiptURL,
       FileManager.default.fileExists(atPath: receiptURL.path) {
      return true
    }

    return false
  }

  static var version: String {
    guard let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    else {
      fatalError("CFBundleShortVersionString missing in app's Info.plist")
    }

    return version
  }

  static var gitSha: String {
    guard let gitSha = Bundle.main.object(forInfoDictionaryKey: "GitSha") as? String,
          !gitSha.isEmpty
    else { return "unknown" }

    return String(gitSha.prefix(8))
  }

  public static var appGroupId: String {
    guard let appGroupId = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String
    else {
      fatalError("AppGroupIdentifier missing in app's Info.plist")
    }
    return appGroupId
  }
}
