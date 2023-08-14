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
    @StateObject var model = AppViewModel()
  #endif

  var body: some Scene {
    #if os(iOS)
      WindowGroup {
        AppView(model: model)
          .onOpenURL { url in
            model.appStore?.continueSignIn(appOpenedWithURL: url)
          }
      }
    #else
      WindowGroup("Settings") {
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

    func application(_: NSApplication, open urls: [URL]) {
      if let openedWithURL = urls.first {
        menuBar.appStore?.continueSignIn(appOpenedWithURL: openedWithURL)
      }
    }

    func applicationWillTerminate(_: Notification) {}
  }
#endif
