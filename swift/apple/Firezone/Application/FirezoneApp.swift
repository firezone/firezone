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
    /// Frames in the menu bar connecting / disconnecting animations, which run
    /// from an empty "F" to a full one and back.
    private static let animationFrameCount = 4

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var connectingAnimationFrame: Int = 0
  #endif

  @StateObject var store: Store
  @StateObject private var errorHandler = GlobalErrorHandler()

  init() {
    // Initialize Telemetry as early as possible
    Telemetry.start()

    installCertificateParser()

    #if DEBUG
      // `--mock-tunnel` runs the real Store against a canned backend (see MockTunnel.swift).
      let store = Store.mockFromCommandLine() ?? Store()

      #if os(iOS)
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
      mainWindowScene(store: store)
        .handlesExternalEvents(
          matching: [AppView.WindowDefinition.main.externalEventMatchString]
        )
      // macOS doesn't have Sheets, need to use another Window group to show settings
      settingsWindowScene(store: store)
        .handlesExternalEvents(
          matching: [AppView.WindowDefinition.settings.externalEventMatchString]
        )

      MenuBarExtra {
        MenuBarView()
          .environmentObject(store)
          .onReceive(connectingAnimationPublisher) { _ in
            connectingAnimationFrame = (connectingAnimationFrame + 1) % Self.animationFrameCount
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
      case .connecting, .reasserting:
        return "MenuBarIconConnecting\(connectingAnimationFrame + 1)"
      case .disconnecting:
        return "MenuBarIconDisconnecting\(connectingAnimationFrame + 1)"
      default:
        return store.menuBarIconName
      }
    }

    /// Publisher that emits timer ticks only when VPN is in a transitional state
    private var connectingAnimationPublisher: AnyPublisher<Date, Never> {
      Timer.publish(every: 0.125, on: .main, in: .common)
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

/// Hands FirezoneKit the certificate parser the settings screen calls back into.
///
/// Parsing lives in Rust. FirezoneKit is a Swift package and cannot import the
/// UniFFI bindings, so every entry point has to install this before a screen
/// asks for a certificate's details; without it they all report the same parse
/// failure instead of the certificate they were given.
@MainActor
func installCertificateParser() {
  X509CertificateParser.use { der in
    guard let parsed = parseClientCertificate(der: der) else { return .unreadable }

    return X509CertificateSummary(
      isUsable: parsed.isUsable,
      certificateProblems: parsed.certificateProblems.map { X509UnusableReason($0) },
      fields: parsed.detailFields.map { field in
        X509CertificateField(
          label: field.label,
          value: X509ClaimValue(field.value),
          problem: field.problem.map { X509FieldProblem($0) }
        )
      },
      actorEmail: parsed.userIdentity?.email
    )
  }
}

/// Bridges the parser's claim value into the model the settings screen renders.
extension X509ClaimValue {
  init(_ value: ClaimValue) {
    switch value {
    case .present(let value): self = .present(value)
    case .absent: self = .absent
    }
  }
}

extension X509FieldProblem {
  init(_ problem: FieldProblem) {
    switch problem {
    case .rejected(let reason): self = .rejected(X509ClaimRejection(reason))
    case .unusable(let reason): self = .unusable(X509UnusableReason(reason))
    }
  }
}

extension X509UnusableReason {
  init(_ reason: UnusableReason) {
    switch reason {
    case .noClientAuthEku: self = .noClientAuthEku
    case .noDigitalSignatureKeyUsage: self = .noDigitalSignatureKeyUsage
    case .notYetValid: self = .notYetValid
    case .expired: self = .expired
    case .unsupportedKeyAlgorithm: self = .unsupportedKeyAlgorithm
    case .refusedIdentity: self = .refusedIdentity
    case .unreadable: self = .unreadable
    }
  }
}

extension X509ClaimRejection {
  init(_ reason: RejectionReason) {
    switch reason {
    case .empty: self = .empty
    case .tooLong: self = .tooLong
    case .notAnEmailAddress: self = .notAnEmailAddress
    case .notAUuid: self = .notAUuid
    case .ambiguous: self = .ambiguous
    case .placeholderIdentifier: self = .placeholderIdentifier
    case .unknownAttribute: self = .unknownAttribute
    }
  }
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

      // SwiftUI will show the first window group, so close it on launch
      _ = AppView.WindowDefinition.allCases.map { $0.window()?.close() }

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

#if os(macOS)
  @MainActor
  func mainWindowScene(store: Store) -> some Scene {
    WindowGroup(
      "Welcome to Firezone",
      id: AppView.WindowDefinition.main.identifier
    ) {
      AppView()
        .environmentObject(store)
    }
  }

  @MainActor
  func settingsWindowScene(store: Store) -> some Scene {
    WindowGroup(
      "Settings",
      id: AppView.WindowDefinition.settings.identifier
    ) {
      SettingsView(store: store)
    }
  }
#endif

#if os(macOS) && DEBUG
  // The apps a `--mock-window` run launches, one per window it can name.
  struct UITestMainApp: App {
    @StateObject var store = uiTestStore()

    var body: some Scene {
      mainWindowScene(store: store)
      windowOpenerExtra(id: AppView.WindowDefinition.main.identifier)
    }
  }

  struct UITestSettingsApp: App {
    @StateObject var store = uiTestStore()

    var body: some Scene {
      settingsWindowScene(store: store)
      windowOpenerExtra(id: AppView.WindowDefinition.settings.identifier)
    }
  }

  /// A menu bar scene whose one job is presenting the window scene beside it.
  ///
  /// XCUITest's launch presents no scene at all, and `openWindow` lives in a
  /// view's environment, so opening a window takes a view that exists without
  /// one: a menu bar item's label is built for the status bar at launch.
  @MainActor
  func windowOpenerExtra(id windowID: String) -> some Scene {
    MenuBarExtra {
      EmptyView()
    } label: {
      WindowOpenerLabel(windowID: windowID)
    }
  }

  private struct WindowOpenerLabel: View {
    @Environment(\.openWindow) private var openWindow

    let windowID: String

    var body: some View {
      Text("Firezone UI Test")
        .onAppear { openWindow(id: windowID) }
    }
  }

  @MainActor
  private func uiTestStore() -> Store {
    NSApplication.applyMockPresentation()
    installCertificateParser()

    let store = Store.mockFromCommandLine() ?? Store()
    Task { await store.start() }

    return store
  }
#endif
