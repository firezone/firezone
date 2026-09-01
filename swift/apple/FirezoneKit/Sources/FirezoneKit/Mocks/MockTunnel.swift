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
    let connectedDevices: [ConnectedDevice]
    let favorites: [String]
    let providerLogFolderSize: Int64

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
    /// Every case but `absent` and `unreadable` names a certificate this bundle ships under
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
      /// Bytes that are not a certificate, which the client cannot read.
      case unreadable
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
    /// A certificate that will not load ends the process, the way a scenario that
    /// will not load does: a screen reporting no certificate instead would go
    /// unnoticed until someone read the screenshots.
    private var der: Data? {
      switch self {
      case .absent:
        return nil

      case .unreadable:
        return Data("These bytes are not a certificate.".utf8)

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
      UserDefaults.standard.set(scenario.favorites, forKey: Favorites.key)

      seedConfiguration(with: scenario)

      #if os(macOS)
        return Store(
          sessionNotification: MockSessionNotification(decision: scenario.notifications.status),
          systemExtensionManager: MockSystemExtensionManager(
            status: scenario.systemExtension.status
          ),
          updateChecker: MockUpdateChecker(),
          tunnelManagerFactory: MockTunnelProviderManagerFactory(scenario: scenario),
          x509CertificateSource: scenario.clientCertificate.source,
          logDirectory: logDirectory ?? MockFixtures.makeLogDirectory()
        )
      #else
        return Store(
          sessionNotification: MockSessionNotification(decision: scenario.notifications.status),
          tunnelManagerFactory: MockTunnelProviderManagerFactory(scenario: scenario),
          x509CertificateSource: scenario.clientCertificate.source,
          logDirectory: logDirectory ?? MockFixtures.makeLogDirectory()
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
    /// Holds the window observer below for the life of the process.
    @MainActor private var mockWindowObserver: (any NSObjectProtocol)?

    extension AppView.WindowDefinition {
      public static func mockFromCommandLine() -> Self? {
        guard let name = flagValue("--mock-window") else { return nil }

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
        shared.appearance = mockAppearance()

        mockWindowObserver = NotificationCenter.default.addObserver(
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
        }
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

  /// Answers `pollUpdates` with the scenario's snapshot and reports its tunnel status.
  private final class MockTunnelSession: TunnelSessionProtocol {
    private let scenario: MockScenario

    var status: NEVPNStatus { scenario.vpnStatus.status }

    /// Drops to zero when a clear is acknowledged, so the settings screen shows
    /// the size a real provider would report afterwards.
    ///
    /// nonisolated(unsafe): the session is Sendable, but the mock is only ever
    /// driven from the main actor.
    nonisolated(unsafe) private var providerLogFolderSize: Int64

    init(scenario: MockScenario) {
      self.scenario = scenario
      self.providerLogFolderSize = scenario.providerLogFolderSize
    }

    // swiftlint:disable:next discouraged_optional_collection
    func startTunnel(options: [String: Any]?) throws {}
    func stopTunnel() {}

    func fetchLastDisconnectError(completionHandler: @escaping @Sendable (Error?) -> Void) {
      completionHandler(nil)
    }

    func sendProviderMessage(_ messageData: Data, responseHandler: ((Data?) -> Void)?) throws {
      guard let responseHandler else { return }

      let message: ProviderMessage
      do {
        message = try PropertyListDecoder().decode(ProviderMessage.self, from: messageData)
      } catch {
        Log.warning("MockTunnelSession: ignoring undecodable ProviderMessage: \(error)")
        responseHandler(nil)
        return
      }

      // Listed exhaustively (no `default`) so adding a `ProviderMessage` variant
      // fails to compile here and forces a decision about the mock's response.
      switch message {
      case .pollUpdates(let request):
        do {
          let stateChange = try ConnlibState.makeIfChanged(
            resources: scenario.resources,
            connectedDevices: scenario.connectedDevices,
            isLogStreamingActive: false,
            actorName: scenario.actorName,
            comparedTo: request.stateHash
          )

          responseHandler(
            try PropertyListEncoder().encode(
              StatePollResponse(
                stateChange: stateChange,
                notifications: []
              )
            )
          )
        } catch {
          Log.warning("MockTunnelSession: failed to encode state updates: \(error)")
          responseHandler(nil)
        }
      case .getLogFolderSize:
        // The provider answers with the raw bytes of an `Int64`.
        responseHandler(withUnsafeBytes(of: providerLogFolderSize) { Data($0) })
      case .clearLogs:
        // The provider answers a successful clear with an empty response.
        providerLogFolderSize = 0
        responseHandler(nil)
      case .exportLogs:
        // The provider streams plist-encoded `LogChunk`s; everything fits in one
        // final chunk here.
        do {
          responseHandler(
            try PropertyListEncoder().encode(
              LogChunk(done: true, data: MockFixtures.exportedTunnelLogs)
            )
          )
        } catch {
          Log.warning("MockTunnelSession: failed to encode the log chunk: \(error)")
          responseHandler(nil)
        }
      case .setInternetResourceEnabled, .signOut, .getEncodedFirezoneId, .drainFlowLogs:
        responseHandler(nil)
      }
    }
  }

  /// Both factory methods hand back the same `MockTunnelProviderManager`, so session
  /// identity survives a reload and `Store` can subscribe to one mock session for the
  /// life of the app.
  @MainActor
  private final class MockTunnelProviderManagerFactory: TunnelProviderManagerFactory {
    private let scenario: MockScenario
    private let manager: MockTunnelProviderManager

    init(scenario: MockScenario) {
      self.scenario = scenario
      self.manager = MockTunnelProviderManager(scenario: scenario)
    }

    func loadAllFromPreferences() async throws -> [any TunnelProviderManager] {
      scenario.hasVPNConfiguration ? [manager] : []
    }

    func createManager() -> any TunnelProviderManager { manager }
  }

  @MainActor
  private final class MockTunnelProviderManager: TunnelProviderManager {
    var isEnabled = true
    var localizedDescription: String? = VPNConfigurationManager.bundleDescription
    var protocolConfiguration: NEVPNProtocol?
    var tunnelSession: (any TunnelSessionProtocol)? { session }
    // Only the system would read this, to launch the extension; the mock never talks to
    // the system, so the shipped identifier serves as well as a derived one.
    let extensionBundleIdentifier = "dev.firezone.firezone.network-extension"

    private let session: MockTunnelSession

    init(scenario: MockScenario) {
      session = MockTunnelSession(scenario: scenario)

      let proto = NETunnelProviderProtocol()
      proto.providerConfiguration = Configuration.shared.toProviderConfiguration()
      proto.providerBundleIdentifier = extensionBundleIdentifier
      proto.serverAddress = "Firezone"
      protocolConfiguration = proto
    }

    func saveToPreferences() async throws {}
    func loadFromPreferences() async throws {}
  }

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
    /// The real `UpdateChecker` would poll firezone.dev on a timer and register a
    /// notification category, neither of which a demo or a test should be doing.
    @MainActor
    private final class MockUpdateChecker: UpdateCheckerProtocol {
      let updateAvailable = false
    }
  #endif

  /// Reports the scenario's answer to the notification prompt.
  ///
  /// Both platforms use it: the real `SessionNotification` reaches
  /// `UNUserNotificationCenter`, which raises rather than returning an error when
  /// the process has no app bundle, so it cannot be built from a test.
  @MainActor
  private final class MockSessionNotification: SessionNotificationProtocol {
    var signInHandler: () async -> Void = {}

    private let decision: UNAuthorizationStatus

    init(decision: UNAuthorizationStatus) {
      self.decision = decision
    }

    func askUserForNotificationPermissions() async throws -> UNAuthorizationStatus { decision }
    func loadAuthorizationStatus() async -> UNAuthorizationStatus { decision }
    func showResourceNotification(title: String, body: String) async {}

    #if os(macOS)
      func showSignedOutAlertMacOS(_ message: String?) async {}
      func showDisconnectedAlertMacOS(_ message: String?) async {}
      func showRestartRequiredAlertMacOS() {}
    #endif
  }

  private enum MockFixtures {
    /// The provider streams the bytes of a ZIP archive, so answer with the
    /// smallest valid one: an empty end-of-central-directory record. An export
    /// produced against the mock then unzips cleanly.
    static let exportedTunnelLogs = Data(
      [0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18)
    )

    /// A throwaway log directory seeded with two files of fixed contents, so
    /// the computed app-side log size is real and deterministic.
    static func makeLogDirectory() -> URL {
      let fileManager = FileManager.default
      let directory = fileManager.temporaryDirectory
        .appendingPathComponent("firezone-mock-logs-\(UUID().uuidString)")

      do {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("2026-01-01T00:00:00 INFO Connected to the portal\n".utf8)
          .write(to: directory.appendingPathComponent("app.log"))
        try Data("2026-01-01T00:00:00 DEBUG Tunnel interface is up\n".utf8)
          .write(to: directory.appendingPathComponent("connlib.log"))
      } catch {
        Log.warning("MockFixtures: failed to seed the log directory: \(error)")
      }

      return directory
    }
  }
#endif
