//
//  MockTunnel.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

// Backs the `--mock-tunnel` launch argument: feeds the real `Store` the state a
// scenario fixture describes, so the macOS menu bar and the iOS app UI can be
// exercised without a portal, auth, system extension, or live peers. Mirrors the
// desktop client's `fake_controller.rs`. The code is DEBUG-only, so it ships in no
// release; only the fixtures travel as ordinary resources. On iOS the Simulator
// cannot run a Network Extension at all; the mock sidesteps it entirely.
//
// `--mock-scenario <name>` picks the fixture (see `Mocks/Scenarios`), so a screen
// that needs a state no fixture describes wants a new fixture rather than new
// code here.

#if DEBUG
  import Foundation
  @preconcurrency import NetworkExtension
  import UserNotifications

  #if os(macOS)
    import AppKit
  #endif

  /// The state the `--mock-tunnel` backend presents, as a fixture describes it.
  ///
  /// Every field is terminal: the mock reports it unchanged for the life of the
  /// process, so a screenshot or a demo cannot race a transition. Decoding is
  /// strict, so a fixture that leaves a field out fails to load rather than
  /// quietly standing in for another scenario.
  struct MockScenario: Decodable, Sendable {
    /// Whether a VPN configuration exists, as it does once the user has granted
    /// the VPN permission.
    let hasVPNConfiguration: Bool

    /// The status the tunnel session reports. A scenario without a VPN
    /// configuration has no session to report one, and the app treats it as
    /// `invalid` whatever this says.
    let vpnStatus: VPNStatus

    /// What the system reports about the network extension. iOS has none and
    /// ignores this.
    let systemExtension: SystemExtension

    /// What the user answered when asked to allow notifications.
    let notifications: NotificationDecision

    /// The signed-in user, as the provider configuration carries it.
    let actorName: String

    let resources: [Resource]

    let connectedDevices: [ConnectedDevice]

    /// The ids of the resources the user has starred.
    let favorites: [String]

    /// The size the provider reports for its own log folder, in bytes.
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
  }

  extension MockScenario {
    /// The scenario a mock presents when none is named.
    static var connected: MockScenario { named("connected") }

    /// The scenario `nameOrPath` describes.
    ///
    /// A name resolves to a fixture this bundle ships; a path starting with `/`
    /// is read as it stands, which is what makes iterating on a screen a matter
    /// of editing one JSON file. Either way the app reads it: a UI-test runner
    /// is sandboxed and could hand no file over.
    ///
    /// A fixture that will not load ends the process. Presenting some other
    /// state instead would go unnoticed until someone read the screenshots.
    static func named(_ nameOrPath: String) -> MockScenario {
      guard let url = url(of: nameOrPath) else {
        fatalError("No mock scenario named '\(nameOrPath)'")
      }

      do {
        return try JSONDecoder().decode(MockScenario.self, from: Data(contentsOf: url))
      } catch {
        fatalError("Mock scenario '\(nameOrPath)' did not load: \(error)")
      }
    }

    private static func url(of nameOrPath: String) -> URL? {
      guard !nameOrPath.hasPrefix("/") else {
        return URL(fileURLWithPath: nameOrPath)
      }

      return Bundle.module.url(
        forResource: nameOrPath, withExtension: "json", subdirectory: "Scenarios"
      )
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
    /// A `Store` against the mocked backend when the command line asks for one
    /// with `--mock-tunnel`, and `nil` otherwise.
    ///
    /// `--mock-scenario <name>` picks the state it presents. Both flags carry two
    /// dashes, which keeps them out of `UserDefaults`' argument domain, where a
    /// single dash would land them.
    public static func mockFromCommandLine(
      _ arguments: [String] = CommandLine.arguments
    ) -> Store? {
      guard arguments.contains("--mock-tunnel") else { return nil }

      guard let name = flagValue("--mock-scenario", in: arguments) else {
        return mock()
      }

      return mock(scenario: .named(name))
    }

    /// A `Store` wired to mock dependencies presenting `scenario`.
    ///
    /// The scenario's favorites go through `userDefaults` because that is where
    /// `Favorites` reads them from.
    static func mock(
      scenario: MockScenario = .connected,
      logDirectory: URL? = nil,
      // swiftlint:disable:next no_userdefaults_standard - DI entry point
      userDefaults: UserDefaults = .standard
    ) -> Store {
      Favorites.seed(scenario.favorites, in: userDefaults)

      #if os(macOS)
        return Store(
          sessionNotification: MockSessionNotification(decision: scenario.notifications.status),
          systemExtensionManager: MockSystemExtensionManager(
            status: scenario.systemExtension.status
          ),
          updateChecker: MockUpdateChecker(),
          tunnelManagerFactory: MockTunnelProviderManagerFactory(scenario: scenario),
          logDirectory: logDirectory ?? MockFixtures.makeLogDirectory(),
          userDefaults: userDefaults
        )
      #else
        return Store(
          sessionNotification: MockSessionNotification(decision: scenario.notifications.status),
          tunnelManagerFactory: MockTunnelProviderManagerFactory(scenario: scenario),
          logDirectory: logDirectory ?? MockFixtures.makeLogDirectory(),
          userDefaults: userDefaults
        )
      #endif
    }
  }

  /// The argument following `flag`, or the value it carries after an `=`.
  private func flagValue(_ flag: String, in arguments: [String]) -> String? {
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

  #if os(macOS)
    extension NSApplication {
      /// Draws the app in the appearance `--mock-appearance` names, when it names
      /// one, rather than in the system's.
      ///
      /// Nothing outside the app can pin its appearance for one process: AppKit
      /// resolves it from the system setting through `CFPreferences`, which does
      /// not read `UserDefaults`' argument domain, so an `-AppleInterfaceStyle`
      /// argument reaches the app and changes nothing. Photographing both
      /// appearances therefore means asking the app itself.
      @MainActor
      public static func applyMockAppearance(_ arguments: [String] = CommandLine.arguments) {
        guard let name = flagValue("--mock-appearance", in: arguments) else { return }

        switch name {
        case "light":
          NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case "dark":
          NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        default:
          Log.warning("Ignoring unknown --mock-appearance '\(name)'")
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

  /// Both factory methods hand back the same `MockTunnelProviderManager` instance, so
  /// session identity is stable across reloads — `Store` can subscribe to one mock
  /// session for the lifetime of the app.
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

      // The signed-in user reaches the app through the provider configuration,
      // the way a real session hands it over.
      let configuration = Configuration()
      configuration.actorName = scenario.actorName

      let proto = NETunnelProviderProtocol()
      proto.providerConfiguration = configuration.toProviderConfiguration()
      proto.providerBundleIdentifier = extensionBundleIdentifier
      proto.serverAddress = "Firezone"
      protocolConfiguration = proto
    }

    func saveToPreferences() async throws {}
    func loadFromPreferences() async throws {}
  }

  #if os(macOS)
    /// Reports the fixed status the scenario prescribes, from `check` and
    /// `tryInstall` alike: scenarios are terminal, so even the install button
    /// on the grant screen changes nothing.
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

  /// Reports the scenario's answer to the notification prompt, so the iOS app can be
  /// shown either on `GrantNotificationsView` or past it.
  ///
  /// Both platforms use it: the real `SessionNotification` reaches
  /// `UNUserNotificationCenter`, which raises rather than returning an error when the
  /// process has no app bundle, so it cannot be built from a test.
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
