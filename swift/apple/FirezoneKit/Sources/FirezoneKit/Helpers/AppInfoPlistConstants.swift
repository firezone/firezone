//
//  AppInfoPlistConstants.swift
//  (c) 2023 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

struct AppInfoPlistConstants {

  static var authBaseURL: URL {
    let infoPlistDictionary = Bundle.main.infoDictionary
    guard let urlScheme = (infoPlistDictionary?["AuthURLScheme"] as? String), !urlScheme.isEmpty
    else {
      fatalError(
        "AuthURLScheme missing in app's Info.plist. Please define AUTH_URL_SCHEME, AUTH_URL_HOST, CONTROL_PLANE_URL_SCHEME, and CONTROL_PLANE_URL_HOST in Server.xcconfig."
      )
    }
    guard let urlHost = (infoPlistDictionary?["AuthURLHost"] as? String), !urlHost.isEmpty else {
      fatalError(
        "AuthURLHost missing in app's Info.plist. Please define AUTH_URL_SCHEME, AUTH_URL_HOST, CONTROL_PLANE_URL_SCHEME, and CONTROL_PLANE_URL_HOST in Server.xcconfig."
      )
    }
    let urlString = "\(urlScheme)://\(urlHost)/"
    guard let url = URL(string: urlString) else {
      fatalError("AuthURL: Cannot form valid URL from string: \(urlString)")
    }
    return url
  }

  static var controlPlaneURL: URL {
    let infoPlistDictionary = Bundle.main.infoDictionary
    guard let urlScheme = (infoPlistDictionary?["ControlPlaneURLScheme"] as? String),
      !urlScheme.isEmpty
    else {
      fatalError(
        "ControlPlaneURLScheme missing in app's Info.plist. Please define AUTH_URL_SCHEME, AUTH_URL_HOST, CONTROL_PLANE_URL_SCHEME, and CONTROL_PLANE_URL_HOST in Server.xcconfig."
      )
    }
    guard let urlHost = (infoPlistDictionary?["ControlPlaneURLHost"] as? String), !urlHost.isEmpty
    else {
      fatalError(
        "ControlPlaneURLHost missing in app's Info.plist. Please define AUTH_URL_SCHEME, AUTH_URL_HOST, CONTROL_PLANE_URL_SCHEME, and CONTROL_PLANE_URL_HOST in Server.xcconfig."
      )
    }
    let urlString = "\(urlScheme)://\(urlHost)/"
    guard let url = URL(string: urlString) else {
      fatalError("ControlPlaneURL: Cannot form valid URL from string: \(urlString)")
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
