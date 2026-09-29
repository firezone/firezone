//
//  MockTunnel.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

// Backs the `--mock-tunnel` launch argument: feeds the real `Store` the state a
// fixture in `Mocks/Scenarios` describes, so the UI can be exercised without a
// portal, auth, system extension, or live peers. Mirrors the desktop client's
// `fake_controller.rs`. DEBUG-only, so it ships in no release.

#if DEBUG
  import Foundation
  @preconcurrency import NetworkExtension
  import UserNotifications

  #if os(macOS)
    import AppKit
  #endif

  #if os(iOS)
    import UIKit
  #endif

  /// The state a fixture describes, reported unchanged for the life of the
  /// process so that a capture cannot race a transition.
  struct MockScenario: Decodable, Sendable {
    let hasVPNConfiguration: Bool
    let vpnStatus: VPNStatus
    let systemExtension: SystemExtension
    let notifications: NotificationDecision
    let clientCertificate: ClientCertificate
    /// The actor the portal would name on `init`; absent unless the scenario is connected.
    let actorName: String?
    let resources: [Resource]
    let favorites: [String]
    let providerLogFolderSize: Int64
    /// Bytes of random data the app's log directory holds on top of its fixed lines.
    let appLogFolderSize: Int?

    enum VPNStatus: String, Decodable, Sendable {
      case invalid
      case disconnected
      case connecting
      case connected
      case reasserting
      case disconnecting
    }

    enum SystemExtension: String, Decodable, Sendable {
      case needsInstall
      case needsReplacement
      case installed
      case needsReboot
    }

    enum NotificationDecision: String, Decodable, Sendable {
      case notDetermined
      case denied
      case authorized
    }

    /// The certificate the diagnostics screen is handed, named by what it carries.
    ///
    /// Every case but `absent` names a certificate this bundle ships under
    /// `Mocks/Certificates`, whose subject, serial, fingerprint and validity dates are
    /// fixed. A capture of the screen is then the same picture on every run, and the
    /// wording on it comes from the parser rather than from a fixture.
    enum ClientCertificate: String, Decodable, Sendable {
      /// No certificate is configured.
      case absent
      /// A certificate the client can present for mutual TLS.
      case usable
      /// A usable certificate carrying a `firezone://` attribute the parser does not read.
      case unknownAttribute = "unknown-attribute"
      /// A certificate whose validity window has passed.
      case expired
    }
  }

  extension MockScenario {
    static var connected: MockScenario { named("connected") }

    static func named(_ name: String) -> MockScenario {
      let url = Bundle.module.url(
        forResource: name, withExtension: "json", subdirectory: "Scenarios"
      )

      guard let url else { fatalError("No mock scenario named '\(name)'") }

      do {
        return try JSONDecoder().decode(MockScenario.self, from: Data(contentsOf: url))
      } catch {
        fatalError("Mock scenario '\(name)' did not load: \(error)")
      }
    }
  }

  extension MockScenario.VPNStatus {
    fileprivate var status: NEVPNStatus {
      switch self {
      case .invalid: return .invalid
      case .disconnected: return .disconnected
      case .connecting: return .connecting
      case .connected: return .connected
      case .reasserting: return .reasserting
      case .disconnecting: return .disconnecting
      }
    }
  }

  extension MockScenario.NotificationDecision {
    fileprivate var status: UNAuthorizationStatus {
      switch self {
      case .notDetermined: return .notDetermined
      case .denied: return .denied
      case .authorized: return .authorized
      }
    }
  }

  extension MockScenario.ClientCertificate {
    /// Where the certificate screen reads this state's certificate from.
    var source: X509CertificateSource { .fixed(certificate: der) }

    /// The bytes the certificate screen is handed, `nil` when this state has none.
    ///
    /// A fixture that will not load ends the process so a capture cannot silently
    /// omit the Device Trust tab it was meant to exercise.
    private var der: Data? {
      switch self {
      case .absent:
        return nil

      case .usable, .unknownAttribute, .expired:
        guard let url = Self.url(of: rawValue) else {
          fatalError("No mock certificate named '\(rawValue)'")
        }

        do {
          return try Data(contentsOf: url)
        } catch {
          fatalError("Mock certificate '\(rawValue)' did not load: \(error)")
        }
      }
    }

    private static func url(of name: String) -> URL? {
      Bundle.module.url(forResource: name, withExtension: "der", subdirectory: "Certificates")
    }
  }

  #if os(macOS)
    extension MockScenario.SystemExtension {
      fileprivate var status: SystemExtensionStatus {
        switch self {
        case .needsInstall: return .needsInstall
        case .needsReplacement: return .needsReplacement
        case .installed: return .installed
        case .needsReboot: return .needsReboot
        }
      }
    }
  #endif

  extension Store {
    public static func mockFromCommandLine() -> Store? {
      guard MockRun.isActive else { return nil }

      guard let name = flagValue("--mock-scenario") else { return mock() }

      return mock(scenario: .named(name))
    }

    static func mock(scenario: MockScenario = .connected, logDirectory: URL? = nil) -> Store {
      // swiftlint:disable:next no_userdefaults_standard - DI entry point
      let defaults = UserDefaults.standard
      defaults.set(scenario.favorites, forKey: Favorites.key)
      // Otherwise the welcome window opens over the screen being photographed.
      defaults.set(true, forKey: "launchedBefore")

      seedConfiguration(with: scenario)

      let logDirectory =
        logDirectory ?? MockFixtures.makeLogDirectory(randomBytes: scenario.appLogFolderSize ?? 0)

      let session = MockTunnelSession(
        status: scenario.vpnStatus.status,
        resources: scenario.resources,
        actorName: scenario.actorName,
        providerLogFolderSize: scenario.providerLogFolderSize
      )
      let tunnelManagerFactory = MockTunnelProviderManagerFactory(
        manager: MockTunnelProviderManager(session: session),
        installed: scenario.hasVPNConfiguration
      )

      #if os(macOS)
        return Store(
          sessionNotification: MockSessionNotification(decision: scenario.notifications.status),
          systemExtensionManager: MockSystemExtensionManager(
            status: scenario.systemExtension.status
          ),
          updateChecker: MockUpdateChecker(),
          tunnelManagerFactory: tunnelManagerFactory,
          x509CertificateSource: scenario.clientCertificate.source,
          logDirectory: logDirectory
        )
      #else
        return Store(
          sessionNotification: MockSessionNotification(decision: scenario.notifications.status),
          tunnelManagerFactory: tunnelManagerFactory,
          x509CertificateSource: scenario.clientCertificate.source,
          logDirectory: logDirectory
        )
      #endif
    }

    /// Settles the settings the app reports before anything reads them.
    ///
    /// `SettingsViewModel` snapshots each unforced setting when it is built and only
    /// ever re-reads the forced ones, so a value that arrives later leaves the form
    /// showing a stale one and its Apply button lit.
    private static func seedConfiguration(with scenario: MockScenario) {
      let configuration = Configuration.shared

      configuration.accountSlug = "example-corp"

      // A DEBUG build points these at the staging stack, which a screenshot of the
      // settings screens would then advertise.
      configuration.authURL = "https://app.firezone.dev"
      configuration.apiURL = "wss://api.firezone.dev"
      configuration.logFilter = "info"
    }
  }

  /// The argument following `flag`, or the value it carries after an `=`.
  private func flagValue(_ flag: String) -> String? {
    let arguments = CommandLine.arguments

    for (index, argument) in arguments.enumerated() {
      if argument == flag, index + 1 < arguments.count {
        return arguments[index + 1]
      }

      if argument.hasPrefix("\(flag)=") {
        return String(argument.dropFirst(flag.count + 1))
      }
    }

    return nil
  }

  #if os(iOS)
    extension UIApplication {
      /// Takes the animation and the translucency out of a mocked run.
      ///
      /// Both hold still long enough to be photographed, so waiting for the
      /// screen to settle cannot tell a bar mid-animation, or one sampling
      /// whatever is behind it, from one that has come to rest.
      @MainActor
      public static func applyMockPresentation() {
        guard MockRun.isActive else { return }

        UIView.setAnimationsEnabled(false)

        // A bar button's default background image draws it on a material of its
        // own that does not come out the same twice; an empty image is flat.
        let flatButton = UIBarButtonItemAppearance(style: .plain)
        flatButton.normal.backgroundImage = UIImage()
        flatButton.highlighted.backgroundImage = UIImage()
        flatButton.disabled.backgroundImage = UIImage()

        let navigationBar = UINavigationBarAppearance()
        navigationBar.configureWithOpaqueBackground()
        navigationBar.buttonAppearance = flatButton
        navigationBar.backButtonAppearance = flatButton
        navigationBar.doneButtonAppearance = flatButton
        UINavigationBar.appearance().standardAppearance = navigationBar
        UINavigationBar.appearance().scrollEdgeAppearance = navigationBar
        UINavigationBar.appearance().compactAppearance = navigationBar

        let tabBar = UITabBarAppearance()
        tabBar.configureWithOpaqueBackground()
        UITabBar.appearance().standardAppearance = tabBar
        UITabBar.appearance().scrollEdgeAppearance = tabBar

        let toolbar = UIToolbarAppearance()
        toolbar.configureWithOpaqueBackground()
        UIToolbar.appearance().standardAppearance = toolbar
        UIToolbar.appearance().scrollEdgeAppearance = toolbar
      }
    }
  #endif

  #if os(macOS)
    /// Holds the observers below for the life of the process.
    @MainActor private var mockObservers: [any NSObjectProtocol] = []

    extension AppView.WindowDefinition {
      public static func mockFromCommandLine() -> Self? {
        // `none` leaves the full app running with its menu bar item and no window.
        guard let name = flagValue("--mock-window"), name != "none" else { return nil }

        guard let window = Self(rawValue: name) else {
          Log.warning("Ignoring unknown --mock-window '\(name)'")

          return nil
        }

        return window
      }
    }

    extension NSApplication {
      /// Sets the appearance a capture wants and keeps the focus off its windows.
      ///
      /// The appearance is set from in here because AppKit resolves it through
      /// `CFPreferences`, which does not read `UserDefaults`' argument domain: an
      /// `-AppleInterfaceStyle` argument reaches the app and changes nothing.
      ///
      /// The focus is cleared because the insertion point a text field blinks keeps
      /// two captures half a second apart from ever matching. SwiftUI claims it back
      /// while the window settles, hence the second pass a turn later.
      @MainActor
      public static func applyMockPresentation() {
        guard MockRun.isActive else { return }

        let appearance = mockAppearance()
        shared.appearance = appearance

        mockObservers.append(
          NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
          ) { notification in
            guard let window = notification.object as? NSWindow else { return }

            MainActor.assumeIsolated {
              DispatchQueue.main.async { window.makeFirstResponder(nil) }
              DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                window.makeFirstResponder(nil)
              }
            }
          })

        // A menu takes the system's appearance rather than the app's, so the
        // light and dark captures of it came out identical. Every menu is set as
        // it opens, which reaches the submenus too.
        mockObservers.append(
          NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
          ) { notification in
            // The observer runs on the main queue, whatever the compiler can see of it.
            nonisolated(unsafe) let menu = notification.object as? NSMenu

            MainActor.assumeIsolated { menu?.appearance = NSApplication.shared.appearance }
          })
      }

      private static func mockAppearance() -> NSAppearance? {
        guard let name = flagValue("--mock-appearance") else { return nil }

        switch name {
        case "light": return NSAppearance(named: .aqua)
        case "dark": return NSAppearance(named: .darkAqua)
        default:
          Log.warning("Ignoring unknown --mock-appearance '\(name)'")
          return nil
        }
      }
    }
  #endif

  #if os(macOS)
    @MainActor
    private final class MockSystemExtensionManager: SystemExtensionManagerProtocol {
      private let status: SystemExtensionStatus

      init(status: SystemExtensionStatus) {
        self.status = status
      }

      func check() async throws -> SystemExtensionStatus { status }
      func tryInstall() async throws -> SystemExtensionStatus { status }
    }

    /// Reports the client as up to date, so the menu bar shows no update item.
    ///
    /// The real `UpdateChecker` would poll firezone.dev on a timer, which neither a demo
    /// nor a test should be doing.
    @MainActor
    private final class MockUpdateChecker: UpdateCheckerProtocol {
      let downloadURL: URL? = nil
    }
  #endif

  /// Reports the scenario's answer to the notification prompt and keeps what it was
  /// asked to show.
  ///
  /// Both platforms use it: the real `SessionNotification` reaches
  /// `UNUserNotificationCenter`, which raises rather than returning an error when
  /// the process has no app bundle, so it cannot be built from a test.
  @MainActor
  final class MockSessionNotification: SessionNotificationProtocol {
    enum Shown: Equatable {
      case resource(title: String, body: String)
      case disconnected(String, requiresSignIn: Bool)
      #if os(macOS)
        case restartRequired
        case update(downloadURL: URL)
      #endif
    }

    var signInHandler: () async -> Void = {}
    private(set) var shown: [Shown] = []

    private let decision: UNAuthorizationStatus

    init(decision: UNAuthorizationStatus) {
      self.decision = decision
    }

    func askUserForNotificationPermissions() async throws -> UNAuthorizationStatus { decision }
    func loadAuthorizationStatus() async -> UNAuthorizationStatus { decision }

    func showResourceNotification(title: String, body: String) async {
      shown.append(.resource(title: title, body: body))
    }

    func showDisconnectedNotification(_ message: String, requiresSignIn: Bool) {
      shown.append(.disconnected(message, requiresSignIn: requiresSignIn))
    }

    #if os(macOS)
      func showRestartRequiredAlertMacOS() {
        shown.append(.restartRequired)
      }

      func showUpdateNotification(downloadURL: URL) {
        shown.append(.update(downloadURL: downloadURL))
      }
    #endif
  }

  private enum MockFixtures {
    /// A throwaway log directory seeded with two files of fixed contents, so
    /// the computed app-side log size is real and deterministic.
    ///
    /// `randomBytes` of random data, in files of 20 MB, go into the subfolders a real
    /// log directory has. Random data does not compress, so an archive of it stays as
    /// large and takes as long to write as one of real logs that size.
    static func makeLogDirectory(randomBytes: Int) -> URL {
      let fileManager = FileManager.default
      let directory = fileManager.temporaryDirectory
        .appendingPathComponent("firezone-mock-logs-\(UUID().uuidString)")

      do {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("2026-01-01T00:00:00 INFO Connected to the portal\n".utf8)
          .write(to: directory.appendingPathComponent("app.log"))
        try Data("2026-01-01T00:00:00 DEBUG Tunnel interface is up\n".utf8)
          .write(to: directory.appendingPathComponent("connlib.log"))
        try fill(directory, withRandomBytes: randomBytes)
      } catch {
        Log.warning("MockFixtures: failed to seed the log directory: \(error)")
      }

      return directory
    }

    private static func fill(_ directory: URL, withRandomBytes count: Int) throws {
      let fileSize = 20_000_000
      let folders = ["app", "connlib", "tunnel"]

      for index in 0..<count / fileSize {
        let folder = directory.appendingPathComponent(folders[index % folders.count])
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var data = Data(count: fileSize)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        try data.write(to: folder.appendingPathComponent("\(index).log"))
      }
    }
  }
#endif
