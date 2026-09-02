//
//  MockTunnelSession.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

#if DEBUG
  import Foundation
  @preconcurrency import NetworkExtension

  /// Stands in for the provider behind `NETunnelProviderSession`.
  ///
  /// Answers the app's messages from state a scenario or a test sets, and moves through
  /// the statuses a start or stop would.
  ///
  /// `@unchecked Sendable`: the protocol is `Sendable`, but the mock is only ever driven
  /// from the main actor.
  final class MockTunnelSession: TunnelSessionProtocol, @unchecked Sendable {
    private(set) var status: NEVPNStatus

    /// What the next poll reports; `nil` resources are a portal that has not sent `init`.
    var resources: [Resource]?  // swiftlint:disable:this discouraged_optional_collection
    var connectedDevices: [ConnectedDevice]
    var actorName: String?
    var accountSlug: String?
    /// Handed over on the next poll and consumed by it, like the provider's mailbox.
    var notifications: [UnreachableResource] = []
    /// Drops to zero when a clear is acknowledged, so the settings screen shows the size
    /// a real provider would report afterwards.
    var providerLogFolderSize: Int64

    /// Ends every start the way a provider that cannot bring the tunnel up does: the
    /// status falls back to disconnected with this as the last disconnect error.
    var startFailure: (any Error)?

    /// The options of every start, cycle starts included.
    private(set) var starts: [[String: Any]] = []
    private(set) var messages: [ProviderMessage] = []
    private var lastDisconnectError: (any Error)?
    private var statusObservers: [AsyncStream<NEVPNStatus>.Continuation] = []

    init(
      status: NEVPNStatus,
      resources: [Resource]? = nil,  // swiftlint:disable:this discouraged_optional_collection
      connectedDevices: [ConnectedDevice] = [],
      actorName: String? = nil,
      providerLogFolderSize: Int64 = 0
    ) {
      self.status = status
      self.resources = resources
      self.connectedDevices = connectedDevices
      self.actorName = actorName
      self.providerLogFolderSize = providerLogFolderSize
    }

    // swiftlint:disable:next discouraged_optional_collection
    func startTunnel(options: [String: Any]?) throws {
      starts.append(options ?? [:])
      lastDisconnectError = nil
      transition(to: .connecting)

      if let startFailure {
        lastDisconnectError = startFailure
        transition(to: .disconnected)
        return
      }

      transition(to: .connected)
    }

    func statusUpdates() -> AsyncStream<NEVPNStatus> {
      AsyncStream { statusObservers.append($0) }
    }

    func stopTunnel() {
      guard [.connected, .connecting, .reasserting].contains(status) else { return }

      transition(to: .disconnecting)
      transition(to: .disconnected)
    }

    /// Ends the session the way the provider does when connlib reports a disconnect.
    func disconnect(with error: any Error) {
      lastDisconnectError = error
      transition(to: .disconnected)
    }

    func fetchLastDisconnectError(completionHandler: @escaping @Sendable (Error?) -> Void) {
      completionHandler(lastDisconnectError)
    }

    func sendProviderMessage(_ messageData: Data, responseHandler: ((Data?) -> Void)?) throws {
      let message: ProviderMessage
      do {
        message = try PropertyListDecoder().decode(ProviderMessage.self, from: messageData)
      } catch {
        Log.warning("MockTunnelSession: ignoring undecodable ProviderMessage: \(error)")
        responseHandler?(nil)
        return
      }

      messages.append(message)

      guard let responseHandler else { return }

      // Listed exhaustively (no `default`) so adding a `ProviderMessage` variant
      // fails to compile here and forces a decision about the mock's response.
      switch message {
      case .pollUpdates(let request):
        do {
          let stateChange = try ConnlibState.makeIfChanged(
            resources: resources,
            connectedDevices: connectedDevices,
            isLogStreamingActive: false,
            accountSlug: accountSlug,
            actorName: actorName,
            comparedTo: request.stateHash
          )
          let response = StatePollResponse(stateChange: stateChange, notifications: notifications)
          let encoded = try PropertyListEncoder().encode(response)

          notifications.removeAll()
          responseHandler(encoded)
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
            try PropertyListEncoder().encode(LogChunk(done: true, data: Self.exportedTunnelLogs))
          )
        } catch {
          Log.warning("MockTunnelSession: failed to encode the log chunk: \(error)")
          responseHandler(nil)
        }
      case .setInternetResourceEnabled, .signOut, .getEncodedFirezoneId, .drainFlowLogs:
        responseHandler(nil)
      }
    }

    private func transition(to newStatus: NEVPNStatus) {
      status = newStatus

      for observer in statusObservers {
        observer.yield(newStatus)
      }
    }

    /// The provider streams the bytes of a ZIP archive, so answer with the smallest
    /// valid one: an empty end-of-central-directory record. An export produced against
    /// the mock then unzips cleanly.
    private static let exportedTunnelLogs = Data(
      [0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18)
    )
  }

  @MainActor
  final class MockTunnelProviderManager: TunnelProviderManager {
    var isEnabled = true
    var localizedDescription: String? = VPNConfigurationManager.bundleDescription
    var protocolConfiguration: NEVPNProtocol?
    var tunnelSession: (any TunnelSessionProtocol)? { session }
    // Only the system would read this, to launch the extension; the mock never talks to
    // the system, so the shipped identifier serves as well as a derived one.
    let extensionBundleIdentifier = "dev.firezone.firezone.network-extension"

    let session: MockTunnelSession

    init(session: MockTunnelSession) {
      self.session = session

      let proto = NETunnelProviderProtocol()
      proto.providerConfiguration = Configuration.shared.toProviderConfiguration()
      proto.providerBundleIdentifier = extensionBundleIdentifier
      proto.serverAddress = "Firezone"
      protocolConfiguration = proto
    }

    func saveToPreferences() async throws {}
    func loadFromPreferences() async throws {}
  }

  /// Both factory methods hand back the same manager, so session identity survives a
  /// reload and `Store` can subscribe to one mock session for the life of the app.
  @MainActor
  final class MockTunnelProviderManagerFactory: TunnelProviderManagerFactory {
    private let manager: MockTunnelProviderManager
    private let isInstalled: Bool

    /// `installed` says whether a load finds the configuration; creating one hands it
    /// out either way.
    init(manager: MockTunnelProviderManager, installed: Bool = true) {
      self.manager = manager
      self.isInstalled = installed
    }

    func loadAllFromPreferences() async throws -> [any TunnelProviderManager] {
      isInstalled ? [manager] : []
    }

    func createManager() -> any TunnelProviderManager { manager }
  }
#endif
