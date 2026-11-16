//
//  ContentFilterManager.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

#if os(macOS)
  import NetworkExtension

  /// Keeps the content filter installed exactly while an application policy applies.
  ///
  /// macOS lets the app enable its own filter; on iOS the filter is installed by MDM,
  /// so there is nothing for the app to do there.
  public enum ContentFilterManager {
    public static func sync(enabled: Bool) async throws {
      let manager = NEFilterManager.shared()
      try await manager.loadFromPreferences()

      guard enabled else {
        if manager.providerConfiguration != nil {
          try await manager.removeFromPreferences()
        }
        return
      }

      let configuration = NEFilterProviderConfiguration()
      configuration.filterSockets = true
      configuration.filterPackets = false
      manager.providerConfiguration = configuration
      manager.localizedDescription = "Firezone"
      manager.isEnabled = true
      try await manager.saveToPreferences()
    }
  }
#endif
