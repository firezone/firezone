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
  #if os(iOS)
    import UserNotifications
  #endif

  extension Store {
    /// A `Store` wired to mock dependencies for the `--mock-tunnel` demo.
    #if os(macOS)
      public static func mock() -> Store {
        Store(
          systemExtensionManager: MockSystemExtensionManager(),
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

  /// Answers `getState` with the canned snapshot and reports a connected tunnel.
  final class MockTunnelSession: TunnelSessionProtocol {
    var status: NEVPNStatus { .connected }

    // swiftlint:disable:next discouraged_optional_collection
    func startTunnel(options: [String: Any]?) throws {}
    func stopTunnel() {}

    func fetchLastDisconnectError(completionHandler: @escaping @Sendable (Error?) -> Void) {
      completionHandler(nil)
    }

    func sendProviderMessage(_ messageData: Data, responseHandler: ((Data?) -> Void)?) throws {
      guard let responseHandler else { return }

      switch try? PropertyListDecoder().decode(ProviderMessage.self, from: messageData) {
      case .getState(let currentHash):
        responseHandler(
          try? ConnlibState.encodeIfChanged(
            resources: MockFixtures.resources,
            connectedDevices: MockFixtures.connectedDevices,
            unreachableResources: [],
            isLogStreamingActive: false,
            comparedTo: currentHash
          )
        )
      default:
        responseHandler(nil)
      }
    }
  }

  @MainActor
  final class MockTunnelProviderManagerFactory: TunnelProviderManagerFactory {
    private let manager = MockTunnelProviderManager()

    func loadAllFromPreferences() async throws -> [any TunnelProviderManager] { [manager] }
    func createManager() -> any TunnelProviderManager { manager }
  }

  @MainActor
  final class MockTunnelProviderManager: TunnelProviderManager {
    var isEnabled = true
    var localizedDescription: String? = VPNConfigurationManager.bundleDescription
    var protocolConfiguration: NEVPNProtocol?
    var tunnelSession: (any TunnelSessionProtocol)? { session }

    private let session = MockTunnelSession()

    init() {
      let proto = NETunnelProviderProtocol()
      proto.providerConfiguration = Configuration().toProviderConfiguration()
      proto.providerBundleIdentifier = VPNConfigurationManager.bundleIdentifier
      proto.serverAddress = "Firezone"
      protocolConfiguration = proto
    }

    func saveToPreferences() async throws {}
    func loadFromPreferences() async throws {}
  }

  #if os(macOS)
    @MainActor
    final class MockSystemExtensionManager: SystemExtensionManagerProtocol {
      func check() async throws -> SystemExtensionStatus { .installed }
      func tryInstall() async throws -> SystemExtensionStatus { .installed }
    }
  #else
    /// Reports notifications as already authorised so the iOS app routes straight to the
    /// session UI instead of `GrantNotificationsView`.
    @MainActor
    final class MockSessionNotification: SessionNotificationProtocol {
      var signInHandler: () async -> Void = {}

      func askUserForNotificationPermissions() async throws -> UNAuthorizationStatus { .authorized }
      func loadAuthorizationStatus() async -> UNAuthorizationStatus { .authorized }
      func showResourceNotification(title: String, body: String) async {}
    }
  #endif

  /// Canned fixtures mirroring the desktop client's `fake_controller.rs`.
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
          tunIPv4: "100.96.0.\(index + 1)",
          pools: poolPatterns[index % poolPatterns.count]
        )
      }
    }()
  }
#endif
