//
//  FirezoneApp.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Combine
import FirezoneKit
import Sentry
import SwiftUI

@main
struct FirezoneApp: App {
  #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var connectingAnimationFrame: Int = 0
  #endif

  @StateObject var store: Store
  @StateObject private var errorHandler = GlobalErrorHandler()

  init() {
    // Initialize Telemetry as early as possible
    Telemetry.start()

    let store = Store()
    _store = StateObject(wrappedValue: store)

    #if os(macOS)
      appDelegate.store = store
    #endif
  }

  var body: some Scene {
    #if os(iOS)
      WindowGroup {
        AppView()
          .environmentObject(errorHandler)
          .environmentObject(store)
      }
    #elseif os(macOS)
      WindowGroup(
        "Welcome to Firezone",
        id: AppView.WindowDefinition.main.identifier
      ) {
        AppView()
          .environmentObject(store)
      }
      .handlesExternalEvents(
        matching: [AppView.WindowDefinition.main.externalEventMatchString]
      )
      // macOS doesn't have Sheets, need to use another Window group to show settings
      WindowGroup(
        "Settings",
        id: AppView.WindowDefinition.settings.identifier
      ) {
        SettingsView(store: store)
      }
      .handlesExternalEvents(
        matching: [AppView.WindowDefinition.settings.externalEventMatchString]
      )

      MenuBarExtra {
        MenuBarView()
          .environmentObject(store)
          .onReceive(connectingAnimationPublisher) { _ in
            connectingAnimationFrame = (connectingAnimationFrame + 1) % 3
          }
          .onReceive(store.$menuBarOpenRequested) { requested in
            if requested {
              StatusItemIntrospection.statusItem()?.button?.performClick(nil)
              store.menuBarOpenRequested = false
            }
          }
      } label: {
        Label {
          Text("Firezone")
        } icon: {
          Image(menuBarIconName)
            .renderingMode(.template)
        }
      }
      .menuBarExtraStyle(.menu)
    #endif
  }

  #if os(macOS)
    var menuBarIconName: String {
      switch store.vpnStatus {
      case .connecting, .disconnecting, .reasserting:
        return "MenuBarIconConnecting\(connectingAnimationFrame + 1)"
      default:
        return store.menuBarIconName
      }
    }

    /// Publisher that emits timer ticks only when VPN is in a transitional state
    private var connectingAnimationPublisher: AnyPublisher<Date, Never> {
      Timer.publish(every: 0.25, on: .main, in: .common)
        .autoconnect()
        .filter { [store] _ in
          switch store.vpnStatus {
          case .connecting, .disconnecting, .reasserting:
            return true
          default:
            return false
          }
        }
        .eraseToAnyPublisher()
    }
  #endif
}

#if os(macOS)
  @MainActor
  final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let softwareUpdateURL = URL(
      string: "x-apple.systempreferences:com.apple.preferences.softwareupdate"
    )!  // swiftlint:disable:this force_unwrapping

    var store: Store?

    func applicationWillFinishLaunching(_ notification: Notification) {
      // Enforce single instance BEFORE the app fully launches
      enforceSingleInstance()

      // Prevent sudden termination for menu bar apps to allow cleanup
      ProcessInfo.processInfo.disableSuddenTermination()
    }

    func applicationDidFinishLaunching(_: Notification) {
      if let store {
        AppView.subscribeToGlobalEvents(store: store)
      }

      // SwiftUI will show the first window group, so close it on launch
      _ = AppView.WindowDefinition.allCases.map { $0.window()?.close() }

      // Show alert for macOS 15.0.x which has issues with Network Extensions.
      maybeShowOutdatedAlert()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
      guard let store else {
        return .terminateNow
      }

      Task {
        do { try await store.stop() } catch { Log.error(error) }
        await MainActor.run { NSApp.reply(toApplicationShouldTerminate: true) }
      }

      return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
      Log.log("\(#function) - app is about to quit")
    }

    private func enforceSingleInstance() {
      // Get the actual bundle identifier from the running app
      guard let bundleId = Bundle.main.bundleIdentifier else { return }

      let runningApps = NSRunningApplication.runningApplications(
        withBundleIdentifier: bundleId
      )

      guard runningApps.count > 1 else { return }

      for app in runningApps where app != NSRunningApplication.current {
        Task { @MainActor in
          let alert = NSAlert()
          alert.messageText = "Another Firezone Instance Detected"
          alert.informativeText = """
            Another instance of Firezone is already running. \
            Please quit the other instance from the menu bar to continue.

            Location: \(app.bundleURL?.path ?? "Unknown")
            """
          alert.alertStyle = .warning
          alert.addButton(withTitle: "OK")

          _ = await MacOSAlert.show(alert)

          // Exit this instance since we can't terminate the other one
          NSApp.terminate(nil)
        }
      }
    }

    private func maybeShowOutdatedAlert() {
      let osVersion = ProcessInfo.processInfo.operatingSystemVersion

      guard osVersion.majorVersion == 15,
        osVersion.minorVersion == 0
      else {
        return
      }

      Task { @MainActor in
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

        let response = await MacOSAlert.show(alert)

        if response == .alertFirstButtonReturn {
          await NSWorkspace.shared.openAsync(Self.softwareUpdateURL)
        }
      }
    }
  }
#endif
