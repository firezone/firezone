//
//  ConfigurationManager.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//
//  A wrapper around UserDefaults

import Foundation
import FirezoneKit
import CryptoKit

class ConfigurationManager {
  static let shared = ConfigurationManager()

  let encoder = PropertyListEncoder()

  private var userDefaults: UserDefaults

  var authURL: URL? {
    get { userDefaults.url(forKey: Configuration.Keys.authURL) }
    set { userDefaults.set(newValue, forKey: Configuration.Keys.authURL) }
  }

  var apiURL: URL? {
    get { userDefaults.url(forKey: Configuration.Keys.apiURL) }
    set { userDefaults.set(newValue, forKey: Configuration.Keys.apiURL) }
  }

  var logFilter: String? {
    get { userDefaults.string(forKey: Configuration.Keys.logFilter) }
    set { userDefaults.set(newValue, forKey: Configuration.Keys.logFilter) }
  }

  var actorName: String? {
    get { userDefaults.string(forKey: Configuration.Keys.actorName) }
    set { userDefaults.set(newValue, forKey: Configuration.Keys.actorName) }
  }

  var accountSlug: String? {
    get { userDefaults.string(forKey: Configuration.Keys.accountSlug) }
    set { userDefaults.set(newValue, forKey: Configuration.Keys.accountSlug) }
  }

  var internetResourceEnabled: Bool? {
    get { userDefaults.bool(forKey: Configuration.Keys.internetResourceEnabled) }
    set { userDefaults.set(newValue, forKey: Configuration.Keys.internetResourceEnabled) }
  }

  var firezoneId: String? {
    get { userDefaults.string(forKey: Configuration.Keys.firezoneId) }
    set { userDefaults.set(newValue, forKey: Configuration.Keys.firezoneId) }
  }

  private init() {
    self.userDefaults = UserDefaults.standard

    if let containerURL = FileManager.default.containerURL(
                          forSecurityApplicationGroupIdentifier: BundleHelper.appGroupId),
       let idFromFile = try? String(contentsOf: containerURL.appendingPathComponent("firezone-id")) {

      self.firezoneId = idFromFile
      try? FileManager.default.removeItem(at: containerURL.appendingPathComponent("firezone-id"))
      Telemetry.firezoneId = idFromFile

      return
    }

    if let firezoneId {
      Telemetry.firezoneId = firezoneId
      return
    }

    self.firezoneId = UUID().uuidString
    Telemetry.firezoneId = firezoneId
  }

  func toDataIfChanged(hash: Data?) -> Data? {
    var dict: [String: Any] = [:]

    dict[Configuration.Keys.accountSlug] = accountSlug
    dict[Configuration.Keys.actorName] = actorName
    dict[Configuration.Keys.firezoneId] = firezoneId
    dict[Configuration.Keys.internetResourceEnabled] = internetResourceEnabled
    dict[Configuration.Keys.authURL] = authURL
    dict[Configuration.Keys.apiURL] = apiURL
    dict[Configuration.Keys.logFilter] = logFilter

    let configuration = Configuration(from: dict)

    do {
      let encoded = try encoder.encode(configuration)
      let hashData = Data(SHA256.hash(data: encoded))

      if hash == hashData {
        // same
        return nil
      }

      return encoded

    } catch {
      Log.error(error)
    }

    return nil
  }
}
