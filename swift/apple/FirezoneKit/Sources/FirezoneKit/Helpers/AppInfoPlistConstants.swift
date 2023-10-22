//
//  AppInfoPlistConstants.swift
//  (c) 2023 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

struct AppInfoPlistConstants {

  static var authBaseURL: URL {
    let infoPlistDictionary = Bundle.main.infoDictionary
    guard let authUrl = (infoPlistDictionary?["AuthURL"] as? String), !authUrl.isEmpty
    else {
      fatalError(
        "AuthURL missing in app's Info.plist. Please define AUTH_URL in config.xcconfig."
      )
    }
    guard let url = URL(string: "\(authUrl)") else {
      fatalError("Auth: Cannot form valid URL from string: \(authUrl)")
    }
    return url
  }

  static var appGroupId: String {
    guard let appGroupId = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String
    else {
      fatalError("AppGroupIdentifier missing in app's Info.plist")
    }
    return appGroupId
  }
}
