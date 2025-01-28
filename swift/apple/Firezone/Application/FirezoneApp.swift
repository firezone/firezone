//
//  FirezoneApp.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import FirezoneKit
import SwiftUI

@main
struct FirezoneApp: App {
  #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
  #endif

  @StateObject var favorites: Favorites
  @StateObject var appViewModel: AppViewModel
  @StateObject var store: Store
  @StateObject private var errorHandler = GlobalErrorHandler()

  init() {
    // Initialize Telemetry as early as possible
    Telemetry.start()

    let favorites = Favorites()
    let store = Store()
    _favorites = StateObject(wrappedValue: favorites)
    _store = StateObject(wrappedValue: store)
    _appViewModel = StateObject(wrappedValue: AppViewModel(favorites: favorites, store: store))

    #if os(macOS)
      appDelegate.store = store
    #endif
  }

  var body: some Scene {
#if os(iOS)
    WindowGroup {
      AppView(model: appViewModel).environmentObject(errorHandler)
    }
#elseif os(macOS)
    WindowGroup(
      "Welcome to Firezone",
      id: AppViewModel.WindowDefinition.main.identifier
    ) {
      if let menuBar = appDelegate.menuBar {
        // menuBar will be initialized by this point
        AppView(model: appViewModel).environmentObject(menuBar)
      } else {
        ProgressView("Loading...")
      }
    }
    .handlesExternalEvents(
      matching: [AppViewModel.WindowDefinition.main.externalEventMatchString]
    )
    // macOS doesn't have Sheets, need to use another Window group to show settings
    WindowGroup(
      "Settings",
      id: AppViewModel.WindowDefinition.settings.identifier
    ) {
      SettingsView(favorites: appDelegate.favorites, model: SettingsViewModel(store: store))
    }
    .handlesExternalEvents(
      matching: [AppViewModel.WindowDefinition.settings.externalEventMatchString]
    )
#endif
  }
}

#if os(macOS)
  @MainActor
  final class AppDelegate: NSObject, NSApplicationDelegate {
    var favorites: Favorites = Favorites()
    var menuBar: MenuBar?
    public var store: Store?

    func applicationDidFinishLaunching(_: Notification) {
      if let store = store {
        menuBar = MenuBar(model: SessionViewModel(favorites: favorites, store: store))
      }

      // SwiftUI will show the first window group, so close it on launch
      _ = AppViewModel.WindowDefinition.allCases.map { $0.window()?.close() }

      // Show alert for macOS 15.0.x which has issues with Network Extensions.
      maybeShowOutdatedAlert()
    }

    private func maybeShowOutdatedAlert() {
      let osVersion = ProcessInfo.processInfo.operatingSystemVersion

      guard osVersion.majorVersion == 15,
            osVersion.minorVersion == 0
      else {
        return
      }

      let alert = NSAlert()
      alert.messageText = "macOS Update Required"
      alert.informativeText =
      """
      macOS 15.0 contains a known issue that can prevent Firezone and other VPN
      apps from functioning correctly. It's highly recommended you upgrade to
      macOS 15.1 or higher.
      """
      alert.addButton(withTitle: "Open System Preferences")
      alert.addButton(withTitle: "OK")

      let response = alert.runModal()

      if response == .alertFirstButtonReturn {
        let softwareUpdateURL = URL(
          string: "x-apple.systempreferences:com.apple.preferences.softwareupdate"
        )

        NSWorkspace.shared.open(softwareUpdateURL!)
      }
    }
  }
#endif
