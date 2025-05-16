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
  private var userDict: [String: Any?]

  private var managedDict: [String: Any?]

  private init() {
    userDefaults = UserDefaults.standard
    userDict = userDefaults.dictionary(forKey: userDictKey) ?? [:]
    managedDict = userDefaults.dictionary(forKey: managedDictKey) ?? [:]

    migrateFirezoneId()
    Telemetry.firezoneId = userDict[Configuration.Keys.firezoneId] as? String

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleUserDefaultsChanged),
      name: UserDefaults.didChangeNotification,
      object: userDefaults
    )
  }

  deinit {
    NotificationCenter.default.removeObserver(self, name: UserDefaults.didChangeNotification, object: userDefaults)
  }

  // Save user-settable configuration
  func setConfiguration(_ configuration: Configuration) {
    userDict[Configuration.Keys.authURL] = configuration.authURL
    userDict[Configuration.Keys.apiURL] = configuration.apiURL
    userDict[Configuration.Keys.logFilter] = configuration.logFilter
    userDict[Configuration.Keys.accountSlug] = configuration.accountSlug
    userDict[Configuration.Keys.connectOnStart] = configuration.connectOnStart
    userDict[Configuration.Keys.startOnLogin] = configuration.startOnLogin

    saveUserDict()
  }

  func toConfiguration() -> Configuration {
    return Configuration(userDict: userDict, managedDict: managedDict)
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

  @objc private func handleUserDefaultsChanged(_ notification: Notification) {
    let newManagedDict = (userDefaults.dictionary(forKey: managedDictKey) ?? [:]) as [String: Any?]

    // NSDictionary conforms to Equatable
    if (managedDict as NSDictionary) == (newManagedDict as NSDictionary) {
      return
    }

    Log.log("Applying MDM configuration. Old: \(managedDict) New: \(newManagedDict)")
    self.managedDict = newManagedDict
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
