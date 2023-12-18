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
  #endif

  #if os(iOS)
    @StateObject var appViewModel: AppViewModel
  #endif

  init() {
    let tunnelStore = TunnelStore()
    let appStore = AppStore(tunnelStore: tunnelStore)
    #if os(macOS)
    #elseif os(iOS)
      self._appViewModel = StateObject(wrappedValue: AppViewModel(appStore: appStore))
    #endif
  }

  var body: some Scene {
    #if os(iOS)
      WindowGroup {
        AppView(model: appViewModel)
      }
    #else
      WindowGroup("Settings", id: "firezone-settings") {
        SettingsView(model: appDelegate.settingsViewModel)
      }
      .handlesExternalEvents(matching: ["settings"])
    #endif
  }
}

#if os(macOS)
  @MainActor
  final class AppDelegate: NSObject, NSApplicationDelegate {
    let settingsViewModel = SettingsViewModel()
    private var menuBar: MenuBar!

    func applicationDidFinishLaunching(_: Notification) {
      menuBar = MenuBar(settingsViewModel: settingsViewModel)

      // SwiftUI will show the first window group, so close it on launch
      let window = NSApp.windows[0]
      window.close()
    }

    func applicationWillTerminate(_: Notification) {}
  }
#endif
