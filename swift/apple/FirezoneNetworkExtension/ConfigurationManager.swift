//
//  ConfigurationManager.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//
//  A wrapper around UserDefaults.

import Foundation
import FirezoneKit
import CryptoKit

class ConfigurationManager {
  static let shared = ConfigurationManager()

  let userDictKey = "dev.firezone.configuration"
  let managedDictKey = "com.apple.configuration.managed"

  private var userDefaults: UserDefaults

  // We maintain a cache of the user dictionary to buffer against unnecessary reads from UserDefaults which
  // can cause deadlocks in rare cases.
  var userDict: [String: Any?]

  var managedDict: [String: Any?] {
    userDefaults.dictionary(forKey: managedDictKey) ?? [:]
  }

  private init() {
    userDefaults = UserDefaults.standard
    userDict = userDefaults.dictionary(forKey: userDictKey) ?? [:]

    migrateFirezoneId()
    Telemetry.firezoneId = userDict[Configuration.Keys.firezoneId] as? String
  }

  func setAuthURL(_ authURL: URL) {
    userDict[Configuration.Keys.authURL] = authURL.absoluteString
    saveUserDict()
  }

  func setApiURL(_ apiURL: URL) {
    userDict[Configuration.Keys.apiURL] = apiURL.absoluteString
    saveUserDict()
  }

  func setLogFilter(_ logFilter: String) {
    userDict[Configuration.Keys.logFilter] = logFilter
    saveUserDict()
  }

  func setActorName(_ actorName: String) {
    userDict[Configuration.Keys.actorName] = actorName
    saveUserDict()
  }

  func setAccountSlug(_ accountSlug: String) {
    userDict[Configuration.Keys.accountSlug] = accountSlug
    saveUserDict()
  }

  func setInternetResourceEnabled(_ internetResourceEnabled: Bool) {
    userDict[Configuration.Keys.internetResourceEnabled] = internetResourceEnabled
    saveUserDict()
  }

  // Firezone ID migration. Can be removed once most clients migrate past 1.4.15.
  private func migrateFirezoneId() {

    // 1. Try to load from file, deleting it
    if let containerURL = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: BundleHelper.appGroupId),
       let idFromFile = try? String(contentsOf: containerURL.appendingPathComponent("firezone-id")) {
      setFirezoneId(idFromFile)
      try? FileManager.default.removeItem(at: containerURL.appendingPathComponent("firezone-id"))
      return
    }

    // 2. Try to load from dict
    if userDict[Configuration.Keys.firezoneId] is String {
      return
    }

    // 3. Generate and save new one
    setFirezoneId(UUID().uuidString)
  }

  private func saveUserDict() {
    userDefaults.set(userDict, forKey: userDictKey)
  }

  private func setFirezoneId(_ firezoneId: String) {
    userDict[Configuration.Keys.firezoneId] = firezoneId
    saveUserDict()
  }
}

// Add methods needed by the tunnel side
extension Configuration {
  func toDataIfChanged(hash: Data?) -> Data? {
    let encoder = PropertyListEncoder()

    do {
      let encoded = try encoder.encode(self)
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
