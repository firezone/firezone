//
//  SettingsClient.swift
//  (c) 2023 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Dependencies
import Foundation

struct SettingsClient {
  var fetchSettings: () -> Settings?
  var saveSettings: (Settings?) -> Void
}

extension SettingsClient: DependencyKey {
  static let liveValue = SettingsClient(
    fetchSettings: {
      guard let data = UserDefaults.standard.data(forKey: "settings") else {
        return nil
      }

      return try? JSONDecoder().decode(Settings.self, from: data)
    },
    saveSettings: { settings in
      let data = try? JSONEncoder().encode(settings)
      UserDefaults.standard.set(data, forKey: "settings")
    }
  )

  static var testValue: SettingsClient {
    let settings = LockIsolated(Settings?.none)
    return SettingsClient(
      fetchSettings: { settings.value },
      saveSettings: { settings.setValue($0) }
    )
  }
}

extension DependencyValues {
  var settingsClient: SettingsClient {
    get { self[SettingsClient.self] }
    set { self[SettingsClient.self] = newValue }
  }
}
