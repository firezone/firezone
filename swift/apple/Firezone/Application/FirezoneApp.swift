//
//  FirezoneApp.swift
//  (c) 2023 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import FirezoneKit
import SwiftUI

@main
struct FirezoneApp: App {
  #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject var askPermissionViewModel: AskPermissionViewModel
  #endif

  #if os(iOS)
    @StateObject var appViewModel: AppViewModel
  #endif

  @StateObject var appStore = AppStore()

  init() {
    let appStore = AppStore()
    self._appStore = StateObject(wrappedValue: appStore)

    #if os(macOS)
      self._askPermissionViewModel =
        StateObject(
          wrappedValue: AskPermissionViewModel(
            tunnelStore: appStore.tunnelStore,
            notificationDecisionHelper: SessionNotificationHelper(logger: appStore.logger, authStore: appStore.authStore)
          )
        )
      appDelegate.appStore = appStore
    #elseif os(iOS)
      self._appViewModel =
        StateObject(wrappedValue: AppViewModel(appStore: appStore))
    #endif

  }

  var body: some Scene {
    #if os(iOS)
      WindowGroup {
        AppView(model: appViewModel)
      }
    #else
      WindowGroup(
        "Firezone (VPN Permission)",
        id: AppStore.WindowDefinition.askPermission.identifier
      ) {
        AskPermissionView(model: askPermissionViewModel)
      }
      .handlesExternalEvents(
        matching: [AppStore.WindowDefinition.askPermission.externalEventMatchString]
      )
      WindowGroup(
        "Settings",
        id: AppStore.WindowDefinition.settings.identifier
      ) {
        SettingsView(model: appStore.settingsViewModel)
      }
      .handlesExternalEvents(
        matching: [AppStore.WindowDefinition.settings.externalEventMatchString]
      )
    #endif
  }
}

#if os(macOS)
  @MainActor
  final class AppDelegate: NSObject, NSApplicationDelegate {
    private var isAppLaunched = false
    private var menuBar: MenuBar?

    public var appStore: AppStore? {
      didSet {
        if self.isAppLaunched {
          // This is not expected to happen because appStore
          // should be set before the app finishes launching.
          // This code is only a contingency.
          if let appStore = self.appStore {
            self.menuBar = MenuBar(appStore: appStore)
          }
        }
      }
    }

    func applicationDidFinishLaunching(_: Notification) {
      self.isAppLaunched = true
      if let appStore = self.appStore {
        self.menuBar = MenuBar(appStore: appStore)
      }

      // SwiftUI will show the first window group, so close it on launch
      _ = AppStore.WindowDefinition.allCases.map { $0.window()?.close() }
    }

    func applicationWillTerminate(_: Notification) {
      self.appStore?.authStore.cancelSignIn()
    }
  }
#endif
