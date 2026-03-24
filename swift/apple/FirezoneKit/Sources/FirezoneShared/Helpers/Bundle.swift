//
//  Bundle.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

public enum BundleHelper {
  public static func isAppStore() -> Bool {
    if let receiptURL = Bundle.main.appStoreReceiptURL,
      FileManager.default.fileExists(atPath: receiptURL.path)
    {
      return true
    }

    return false
  }

  public static var gitSha: String {
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

  // App cannot run without bundle identifier - force unwrap is safe
  public static let networkExtensionBundleIdentifier: String =
    "\(Bundle.main.bundleIdentifier!).network-extension" // swiftlint:disable:this force_unwrapping
}
