//
//  AppInfoPlistConstants.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

struct AppInfoPlistConstants {
  static var appGroupId: String {
    guard let appGroupId = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String
    else {
      fatalError("AppGroupIdentifier missing in app's Info.plist")
    }
    return appGroupId
  }
}
