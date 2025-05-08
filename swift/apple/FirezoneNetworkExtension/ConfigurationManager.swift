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

  enum Keys {
    static let authURL = "dev.firezone.configuration.authURL"
    static let apiURL = "dev.firezone.configuration.apiURL"
    static let logFilter = "dev.firezone.configuration.logFilter"
    static let actorName = "dev.firezone.configuration.actorName"
    static let accountSlug = "dev.firezone.configuration.accountSlug"
    static let internetResourceEnabled = "dev.firezone.configuration.internetResourceEnabled"
    static let firezoneId = "dev.firezone.configuration.firezoneId"
  }

  private var userDefaults: UserDefaults

  var authURL: URL? {
    get { userDefaults.url(forKey: Keys.authURL) }
    set { userDefaults.set(newValue, forKey: Keys.authURL) }
  }

  var apiURL: URL? {
    get { userDefaults.url(forKey: Keys.apiURL) }
    set { userDefaults.set(newValue, forKey: Keys.apiURL) }
  }

  var logFilter: String? {
    get { userDefaults.string(forKey: Keys.logFilter) }
    set { userDefaults.set(newValue, forKey: Keys.logFilter) }
  }

  var actorName: String? {
    get { userDefaults.string(forKey: Keys.actorName) }
    set { userDefaults.set(newValue, forKey: Keys.actorName) }
  }

  var accountSlug: String? {
    get { userDefaults.string(forKey: Keys.accountSlug) }
    set { userDefaults.set(newValue, forKey: Keys.accountSlug) }
  }

  var internetResourceEnabled: Bool? {
    get { userDefaults.bool(forKey: Keys.internetResourceEnabled) }
    set { userDefaults.set(newValue, forKey: Keys.internetResourceEnabled) }
  }

  var firezoneId: String? {
    get { userDefaults.string(forKey: Keys.firezoneId) }
    set { userDefaults.set(newValue, forKey: Keys.firezoneId) }
  }

  private init() {
    guard let defaults = UserDefaults(suiteName: BundleHelper.appGroupId)
    else {
      fatalError("Could not create UserDefaults for app group \(BundleHelper.appGroupId)")
    }

    self.userDefaults = defaults

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

    dict[Keys.accountSlug] = accountSlug
    dict[Keys.actorName] = actorName
    dict[Keys.firezoneId] = firezoneId
    dict[Keys.internetResourceEnabled] = internetResourceEnabled
    dict[Keys.authURL] = authURL
    dict[Keys.apiURL] = apiURL
    dict[Keys.logFilter] = logFilter

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
