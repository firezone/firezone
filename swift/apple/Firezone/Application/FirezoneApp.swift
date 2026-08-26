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
      WindowGroup(
        "Welcome to Firezone",
        id: AppView.WindowDefinition.main.identifier
      ) {
        AppView()
          .environmentObject(store)
          .providingWindowOpener()
      }
      // macOS doesn't have Sheets, need to use another Window group to show settings
      WindowGroup(
        "Settings",
        id: AppView.WindowDefinition.settings.identifier
      ) {
        SettingsView(store: store)
          .providingWindowOpener()
      }

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

    /// Opens the window a `firezone://<window>` URL names.
    ///
    /// `handlesExternalEvents` used to do this, at the cost of every window the app
    /// showed itself going out to `NSWorkspace` and back.
    func application(_ application: NSApplication, open urls: [URL]) {
      for url in urls {
        guard url.scheme == "firezone",
          let host = url.host,
          let window = AppView.WindowDefinition(rawValue: host)
        else { continue }

        window.openWindow()
      }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
      // Enforce single instance BEFORE the app fully launches
      enforceSingleInstance()
    }

    func applicationDidFinishLaunching(_: Notification) {
      if let store {
        AppView.subscribeToGlobalEvents(store: store)
      }

      presentLaunchWindows()

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

    /// Leaves the app showing what it should be showing after launch.
    ///
    /// SwiftUI shows the first window group, which a menu bar app has no use
    /// for, so the windows are closed again. `--mock-window` names one to keep
    /// on the screen instead, which is how a screenshot run gets its window
    /// without asking the system to open a `firezone://` URL.
    private func presentLaunchWindows() {
      #if DEBUG
        if let wanted = AppView.WindowDefinition.mockFromCommandLine() {
          // A turn later, so that the group SwiftUI showed has appeared and lent
          // its `openWindow` action: without it, opening a window is the URL
          // round trip this avoids.
          DispatchQueue.main.async {
            wanted.openWindow()

            for other in AppView.WindowDefinition.allCases where other != wanted {
              other.window()?.close()
            }
          }

          return
        }
      #endif

      _ = AppView.WindowDefinition.allCases.map { $0.window()?.close() }
    }

    private func enforceSingleInstance() {
      // Get the actual bundle identifier from the running app
      guard let bundleId = Bundle.main.bundleIdentifier else { return }

      let runningApps = NSRunningApplication.runningApplications(
        withBundleIdentifier: bundleId
      )

      guard runningApps.count > 1 else { return }

      #if DEBUG
        // A mock run is a screenshot run, which launches and quits copies faster than
        // LaunchServices keeps up with, so it can answer a request meant for the copy
        // already running by starting another. That copy leaves quietly: there is
        // nobody to dismiss the alert below, and a second copy in the element tree
        // shows its windows through the corners of the one being photographed.
        //
        // It leaves after the launch rather than during it. Quitting from here
        // ends the app before it has finished launching, which LaunchServices
        // reports to whoever asked for it as -609, in a dialog that belongs to
        // Finder. Nothing in the run dismisses that dialog, so it sits on the
        // screen and is photographed over whichever screen comes next.
        if CommandLine.arguments.contains("--mock-tunnel") {
          DispatchQueue.main.async { NSApp.terminate(nil) }

          return
        }
      #endif

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
