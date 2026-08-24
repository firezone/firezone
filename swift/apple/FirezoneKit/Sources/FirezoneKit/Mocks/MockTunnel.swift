//
//  MockTunnel.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

// Backs the `--mock-tunnel` launch argument: feeds the real `Store` a connected
// status and a canned resource + connected-device list, so the macOS menu bar and
// the iOS app UI can be exercised without a portal, auth, system extension, or live
// peers. Mirrors the desktop client's `fake_controller.rs`. DEBUG-only, so it ships
// in no release. On iOS the Simulator cannot run a Network Extension at all; the mock
// sidesteps it entirely.

#if DEBUG
  import Foundation
  @preconcurrency import NetworkExtension
  import UserNotifications

  extension Store {
    /// A `Store` wired to mock dependencies for the `--mock-tunnel` demo.
    #if os(macOS)
      public static func mock() -> Store {
        Store(
          sessionNotification: MockSessionNotification(),
          systemExtensionManager: MockSystemExtensionManager(),
          updateChecker: MockUpdateChecker(),
          tunnelManagerFactory: MockTunnelProviderManagerFactory()
        )
      }
    #else
      public static func mock() -> Store {
        Store(
          sessionNotification: MockSessionNotification(),
          tunnelManagerFactory: MockTunnelProviderManagerFactory()
        )
      }
    #endif
  }

  /// Answers `pollUpdates` with the canned snapshot and reports a connected tunnel.
  private final class MockTunnelSession: TunnelSessionProtocol {
    var status: NEVPNStatus { .connected }

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
            resources: MockFixtures.resources,
            connectedDevices: MockFixtures.connectedDevices,
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
      case .setInternetResourceEnabled, .signOut, .clearLogs, .getLogFolderSize, .exportLogs,
        .getEncodedFirezoneId, .drainFlowLogs:
        responseHandler(nil)
      }
    }
  }

  /// Both factory methods hand back the same `MockTunnelProviderManager` instance, so
  /// session identity is stable across reloads — `Store` can subscribe to one mock
  /// session for the lifetime of the app.
  @MainActor
  private final class MockTunnelProviderManagerFactory: TunnelProviderManagerFactory {
    private let manager = MockTunnelProviderManager()

    func loadAllFromPreferences() async throws -> [any TunnelProviderManager] { [manager] }
    func createManager() -> any TunnelProviderManager { manager }
  }

  @MainActor
  private final class MockTunnelProviderManager: TunnelProviderManager {
    var isEnabled = true
    var localizedDescription: String? = VPNConfigurationManager.bundleDescription
    var protocolConfiguration: NEVPNProtocol?
    var tunnelSession: (any TunnelSessionProtocol)? { session }

    private let session = MockTunnelSession()

    init() {
      let proto = NETunnelProviderProtocol()
      proto.providerConfiguration = Configuration().toProviderConfiguration()
      // Only the system would read this, to launch the extension; the mock never talks to
      // the system, so the shipped identifier serves as well as a derived one.
      proto.providerBundleIdentifier = "dev.firezone.firezone.network-extension"
      proto.serverAddress = "Firezone"
      protocolConfiguration = proto
    }

    func saveToPreferences() async throws {}
    func loadFromPreferences() async throws {}
  }

  #if os(macOS)
    @MainActor
    private final class MockSystemExtensionManager: SystemExtensionManagerProtocol {
      func check() async throws -> SystemExtensionStatus { .installed }
      func tryInstall() async throws -> SystemExtensionStatus { .installed }
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

  /// Reports notifications as already authorised so the iOS app routes straight to the
  /// session UI instead of `GrantNotificationsView`.
  ///
  /// Both platforms use it: the real `SessionNotification` reaches
  /// `UNUserNotificationCenter`, which raises rather than returning an error when the
  /// process has no app bundle, so it cannot be built from a test.
  @MainActor
  private final class MockSessionNotification: SessionNotificationProtocol {
    var signInHandler: () async -> Void = {}

    func askUserForNotificationPermissions() async throws -> UNAuthorizationStatus { .authorized }
    func loadAuthorizationStatus() async -> UNAuthorizationStatus { .authorized }
    func showResourceNotification(title: String, body: String) async {}

    #if os(macOS)
      func showSignedOutAlertMacOS(_ message: String?) async {}
      func showDisconnectedAlertMacOS(_ message: String?) async {}
      func showRestartRequiredAlertMacOS() {}
    #endif
  }

  private enum MockFixtures {
    static let resources: [Resource] = {
      let site = Site(id: "demo-site", name: "Demo Site")
      return [
        Resource(
          id: "internet-resource", name: "Internet Resource", address: nil,
          addressDescription: nil, status: .online, sites: [site], type: .internet),
        Resource(
          id: "office-network", name: "Office network", address: "10.0.0.0/16",
          addressDescription: "CIDR resource", status: .online, sites: [site], type: .cidr),
        Resource(
          id: "demo-gitlab", name: "Demo GitLab", address: "gitlab.demo.example",
          addressDescription: "https://gitlab.demo.example", status: .online, sites: [site],
          type: .dns),
        Resource(
          id: "lab-network", name: "Lab network (offline)", address: "192.168.50.0/24",
          addressDescription: "Gateway offline", status: .offline, sites: [site], type: .cidr),
        Resource(
          id: "demo-wiki", name: "Demo Wiki (unknown)", address: "wiki.demo.example",
          addressDescription: "Gateway state unknown", status: .unknown, sites: [site], type: .dns),
      ]
    }()

    static let connectedDevices: [ConnectedDevice] = {
      let poolPatterns: [[String]] = [
        ["Engineering Pool"],
        ["Engineering Pool", "QA Pool"],
        ["QA Pool"],
        ["Sales Pool"],
      ]
      return (0..<22).map { index in
        ConnectedDevice(
          id: "client-\(index + 1)",
          name: "Demo Device \(index + 1)",
          tunIPv4: "100.96.0.\(index + 1)",
          tunIPv6: "fd00:2021:1111::\(String(index + 1, radix: 16))",
          pools: poolPatterns[index % poolPatterns.count]
        )
      }
    }()
  }
#endif
