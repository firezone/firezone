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
      AppView(model: appViewModel)
    }
#elseif os(macOS)
    WindowGroup(
      "Welcome to Firezone",
      id: AppViewModel.WindowDefinition.main.identifier
    ) {
      if let menuBar = appDelegate.menuBar {
        // menuBar will be initialized by this point
        AppView(model: appViewModel).environmentObject(menuBar)
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

      Task {
        // In 1.4.0 and higher, the macOS client uses a system extension as its
        // Network Extension packaging type. It runs as root and can't read the
        // existing firezone-id file. So read it here from the app process instead
        // and save it to the Keychain, where we should store shared persistent
        // data going forward.
        //
        // Can be removed once all clients >= 1.4.0
        try await FirezoneId.migrate()

        try await FirezoneId.createIfMissing()
      }

      if let store = store {
        menuBar = MenuBar(model: SessionViewModel(favorites: favorites, store: store))
      }

      // Apple recommends installing the system extension as early as possible after app launch.
      // See https://developer.apple.com/documentation/systemextensions/installing-system-extensions-and-drivers
      SystemExtensionManager.shared.installSystemExtension(identifier: TunnelManager.bundleIdentifier)

      // SwiftUI will show the first window group, so close it on launch
      _ = AppViewModel.WindowDefinition.allCases.map { $0.window()?.close() }
    }
  }
#endif
