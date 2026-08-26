//
//  FirezoneApp.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Combine
import FirezoneKit
import Sentry
import SwiftUI

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

    #if DEBUG
      // `--mock-tunnel` runs the real Store against a canned backend, and
      // `--mock-scenario` picks the state it presents (see MockTunnel.swift).
      let store = Store.mockFromCommandLine() ?? Store()

      #if os(macOS)
        // Here rather than in the app delegate: SwiftUI installs the delegate
        // late enough to miss `applicationWillFinishLaunching`, and this has to
        // run before the scenes create their windows.
        NSApplication.applyMockPresentation()
      #elseif os(iOS)
        // Before the scenes exist, so the bars are built from the appearance it
        // sets rather than adopting it on their next update.
        UIApplication.applyMockPresentation()
      #endif
    #else
      let store = Store()
    #endif

    // Not `.task` on a view: the main window closes right after launch on macOS, and
    // startup must not be cancelled with it.
    Task { await store.start() }

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
      // The system presents none of these window groups at launch, so a
      // UI-test build declares none: its window is the one the app delegate
      // puts up itself, which cannot lose a race the way asking the system
      // to present a scene can.
      #if !UITEST
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
      #endif

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
      .commands {
        CommandGroup(replacing: .appTermination) {
          Button(store.quitMenuTitle) {
            store.quitApp()
          }
          .keyboardShortcut("q")
        }
      }
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
    }

    func applicationDidFinishLaunching(_: Notification) {
      if let store {
        AppView.subscribeToGlobalEvents(store: store)
      }

      #if UITEST
        presentChosenWindow()
      #else
        // SwiftUI will show the first window group, so close it on launch.
        _ = AppView.WindowDefinition.allCases.map { $0.window()?.close() }
      #endif

      // Show alert for macOS 15.0.x which has issues with Network Extensions.
      maybeShowOutdatedAlert()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
      // Stopping is a request rather than an operation to wait on, so there is
      // nothing left for the app to defer its termination for once it is made.
      store?.requestStop()

      return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
      Log.log("\(#function) - app is about to quit")
    }

    #if UITEST
      /// Keeps the window below alive for the life of the process.
      private var chosenWindow: NSWindow?

      /// Puts the window `--mock-window` names on the screen.
      ///
      /// The app hosts the screen in a window of its own rather than in one of
      /// its window groups: the system presents no scene at this app's launch,
      /// and everything that asks it to present one later is asynchronous, so a
      /// window made right here is the only one that is certainly up before the
      /// test starts looking for it.
      private func presentChosenWindow() {
        guard let store else { return }

        let chosen = AppView.WindowDefinition.mockFromCommandLine() ?? .main

        let title: String
        let screen: AnyView
        switch chosen {
        case .main:
          title = "Welcome to Firezone"
          screen = AnyView(AppView().environmentObject(store))
        case .settings:
          title = "Settings"
          screen = AnyView(SettingsView(store: store))
        }

        // Pinned to the frame SwiftUI gives the app's window groups: the
        // hosting controller sizes its window to the screen's preferred size,
        // and any other preference photographs at the wrong size.
        let host = NSHostingController(rootView: screen.frame(width: 900, height: 450))

        let window = NSWindow(contentViewController: host)
        window.title = title
        window.identifier = NSUserInterfaceItemIdentifier(chosen.identifier)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        chosenWindow = window
      }
    #endif

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
