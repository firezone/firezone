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

  @StateObject var appViewModel: AppViewModel
  @StateObject var store: Store

  init() {
    let store = Store()
    _store = StateObject(wrappedValue: store)
    _appViewModel = StateObject(wrappedValue: AppViewModel(store: store))

    #if os(macOS)
      appDelegate.store = store
    #endif
  }

  var body: some Scene {
    WindowGroup(
      "Welcome to Firezone",
      id: AppViewModel.WindowDefinition.main.identifier
    ) {
      AppView(model: appViewModel)
    }
    .handlesExternalEvents(
      matching: [AppViewModel.WindowDefinition.main.externalEventMatchString]
    )
    // macOS doesn't have Sheets, need to use another Window group to show settings
    #if os(macOS)
      WindowGroup(
        "Settings",
        id: AppViewModel.WindowDefinition.settings.identifier
      ) {
        SettingsView(model: SettingsViewModel(store: store))
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
    private var isAppLaunched = false
    private var menuBar: MenuBar?

    public var store: Store?

    func applicationDidFinishLaunching(_: Notification) {
      isAppLaunched = true
      if let store = store {
        menuBar = MenuBar(model: SessionViewModel(store: store))
      }

      // SwiftUI will show the first window group, so close it on launch
      _ = AppViewModel.WindowDefinition.allCases.map { $0.window()?.close() }
    }
  }
#endif
