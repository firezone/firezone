//
//  VPNConfigurationManager.swift
//
//
//  Created by Jamil Bou Kheir on 4/2/24.
//
//  Abstracts the nitty gritty of loading and saving to our
//  VPN configuration in system preferences.

// TODO: Refactor to fix file length
// swiftlint:disable file_length

import CryptoKit
import Foundation
import NetworkExtension

enum VPNConfigurationManagerError: Error {
  case managerNotInitialized
  case cannotLoad
  case decodeIPCDataFailed
  case invalidStatusChange
  case noIPCData

  var localizedDescription: String {
    switch self {
    case .managerNotInitialized:
      return "Manager doesn't seem initialized."
    case .decodeIPCDataFailed:
      return "Decoding IPC data failed."
    case .invalidStatusChange:
      return "NEVPNStatusDidChange notification doesn't seem to be valid."
    case .cannotLoad:
      return "Could not load VPN configurations!"
    case .noIPCData:
      return "No IPC data returned from the XPC connection!"
    }
  }
}

public enum VPNConfigurationManagerKeys {
  static let actorName = "actorName"
  static let authBaseURL = "authBaseURL"
  static let apiURL = "apiURL"
  public static let accountSlug = "accountSlug"
  public static let logFilter = "logFilter"
  public static let internetResourceEnabled = "internetResourceEnabled"
}

public enum TunnelMessage: Codable {
  case getResourceList(Data)
  case signOut
  case internetResourceEnabled(Bool)
  case clearLogs
  case getLogFolderSize
  case exportLogs
  case consumeStopReason

  enum CodingKeys: String, CodingKey {
    case type
    case value
  }

  enum MessageType: String, Codable {
    case getResourceList
    case signOut
    case internetResourceEnabled
    case clearLogs
    case getLogFolderSize
    case exportLogs
    case consumeStopReason
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(MessageType.self, forKey: .type)
    switch type {
    case .internetResourceEnabled:
      let value = try container.decode(Bool.self, forKey: .value)
      self = .internetResourceEnabled(value)
    case .getResourceList:
      let value = try container.decode(Data.self, forKey: .value)
      self = .getResourceList(value)
    case .signOut:
      self = .signOut
    case .clearLogs:
      self = .clearLogs
    case .getLogFolderSize:
      self = .getLogFolderSize
    case .exportLogs:
      self = .exportLogs
    case .consumeStopReason:
      self = .consumeStopReason
    }
  }
  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .internetResourceEnabled(let value):
      try container.encode(MessageType.internetResourceEnabled, forKey: .type)
      try container.encode(value, forKey: .value)
    case .getResourceList(let value):
      try container.encode(MessageType.getResourceList, forKey: .type)
      try container.encode(value, forKey: .value)
    case .signOut:
      try container.encode(MessageType.signOut, forKey: .type)
    case .clearLogs:
      try container.encode(MessageType.clearLogs, forKey: .type)
    case .getLogFolderSize:
      try container.encode(MessageType.getLogFolderSize, forKey: .type)
    case .exportLogs:
      try container.encode(MessageType.exportLogs, forKey: .type)
    case .consumeStopReason:
      try container.encode(MessageType.consumeStopReason, forKey: .type)
    }
  }
}

// TODO: Refactor this to remove the lint ignore
// swiftlint:disable:next type_body_length
public class VPNConfigurationManager {

  // Connect status updates with our listeners
  private var tunnelObservingTasks: [Task<Void, Never>] = []

  // Track the "version" of the resource list so we can more efficiently
  // retrieve it from the Provider
  private var resourceListHash = Data()

  // Cache resources on this side of the IPC barrier so we can
  // return them to callers when they haven't changed.
  private var resourcesListCache: ResourceList = ResourceList.loading

  // Persists our tunnel settings
  private var manager: NETunnelProviderManager?

  // Indicates if the internet resource is currently enabled
  public var internetResourceEnabled: Bool = false

  // Encoder used to send messages to the tunnel
  private let encoder = {
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary

    return encoder
  }()

  public static let bundleIdentifier: String = "\(Bundle.main.bundleIdentifier!).network-extension"
  private let bundleDescription = "Firezone"

  // Initialize and save a new VPN configuration in system Preferences
  func create() async throws {
    let protocolConfiguration = NETunnelProviderProtocol()
    let manager = NETunnelProviderManager()
    let settings = Settings.defaultValue

    protocolConfiguration.providerConfiguration = settings.toProviderConfiguration()
    protocolConfiguration.providerBundleIdentifier = VPNConfigurationManager.bundleIdentifier
    protocolConfiguration.serverAddress = settings.apiURL
    manager.localizedDescription = bundleDescription
    manager.protocolConfiguration = protocolConfiguration

    // Save the new VPN configuration to System Preferences and reload it,
    // which should update our status from nil -> disconnected.
    // If the user denied the operation, the status will be .invalid
    do {
      try await manager.saveToPreferences()
      try await manager.loadFromPreferences()
      self.manager = manager
    } catch let error as NSError {
      if error.domain == "NEVPNErrorDomain" && error.code == 5 {
        // Silence error when the user doesn't click "Allow" on the VPN
        // permission dialog
        Log.info("VPN permission was denied by the user")

        return
      }

      throw error
    }
  }

  func loadFromPreferences(
    vpnStateUpdateHandler: @escaping @MainActor (NEVPNStatus, Settings?, String?, NEProviderStopReason?) async -> Void
  ) async throws {
    // loadAllFromPreferences() returns list of VPN configurations created by our main app's bundle ID.
    // Since our bundle ID can change (by us), find the one that's current and ignore the others.
    let managers = try await NETunnelProviderManager.loadAllFromPreferences()

    Log.log("\(#function): \(managers.count) tunnel managers found")
    for manager in managers where manager.localizedDescription == bundleDescription {
      guard let protocolConfiguration = manager.protocolConfiguration as? NETunnelProviderProtocol,
            let providerConfiguration = protocolConfiguration.providerConfiguration as? [String: String]
      else {
        throw VPNConfigurationManagerError.cannotLoad
      }

      // Update our state
      self.manager = manager

      let settings = Settings.fromProviderConfiguration(providerConfiguration)
      let actorName = providerConfiguration[VPNConfigurationManagerKeys.actorName]
      if let internetResourceEnabled = providerConfiguration[
        VPNConfigurationManagerKeys.internetResourceEnabled
      ]?.data(using: .utf8) {

        self.internetResourceEnabled = (try? JSONDecoder().decode(Bool.self, from: internetResourceEnabled)) ?? false

      }
      let status = manager.connection.status

      // Configure our Telemetry environment
      Telemetry.setEnvironmentOrClose(settings.apiURL)
      Telemetry.accountSlug = providerConfiguration[VPNConfigurationManagerKeys.accountSlug]

      // Share what we found with our caller
      await vpnStateUpdateHandler(status, settings, actorName, nil)

      // Stop looking for our tunnel
      break
    }

    // If no tunnel configuration was found, update state to
    // prompt user to create one.
    if manager == nil {
      await vpnStateUpdateHandler(.invalid, nil, nil, nil)
    }

    // Hook up status updates
    subscribeToVPNStatusUpdates(handler: vpnStateUpdateHandler)
  }

  func saveAuthResponse(_ authResponse: AuthResponse) async throws {
    guard let manager = manager,
          let protocolConfiguration = manager.protocolConfiguration as? NETunnelProviderProtocol,
          var providerConfiguration = protocolConfiguration.providerConfiguration
    else {
      throw VPNConfigurationManagerError.managerNotInitialized
    }

    providerConfiguration[VPNConfigurationManagerKeys.actorName] = authResponse.actorName
    providerConfiguration[VPNConfigurationManagerKeys.accountSlug] = authResponse.accountSlug
    protocolConfiguration.providerConfiguration = providerConfiguration
    manager.protocolConfiguration = protocolConfiguration

    // We always set this to true when starting the tunnel in case our tunnel
    // was disabled by the system for some reason.
    manager.isEnabled = true

    try await manager.saveToPreferences()
    try await manager.loadFromPreferences()
  }

  func saveSettings(_ settings: Settings) async throws {
    guard let manager = manager,
          let protocolConfiguration = manager.protocolConfiguration as? NETunnelProviderProtocol,
          let providerConfiguration = protocolConfiguration.providerConfiguration as? [String: String]
    else {
      throw VPNConfigurationManagerError.managerNotInitialized
    }

    var newProviderConfiguration = settings.toProviderConfiguration()

    // Don't clobber existing actorName
    newProviderConfiguration[VPNConfigurationManagerKeys.actorName] =
    providerConfiguration[VPNConfigurationManagerKeys.actorName]
    protocolConfiguration.providerConfiguration = newProviderConfiguration
    protocolConfiguration.serverAddress = settings.apiURL
    manager.protocolConfiguration = protocolConfiguration

    // We always set this to true when starting the tunnel in case our tunnel
    // was disabled by the system for some reason.
    manager.isEnabled = true

    try await manager.saveToPreferences()
    try await manager.loadFromPreferences()

    // Reconfigure our Telemetry environment in case it changed
    Telemetry.setEnvironmentOrClose(settings.apiURL)
  }

  func start(token: String? = nil) throws {
    var options: [String: NSObject] = [:]

    // Pass token if provided
    if let token = token {
      options.merge(["token": token as NSObject]) { _, new in new }
    }

    // Pass pre-1.4.0 Firezone ID if it exists. Pre 1.4.0 clients will have this
    // persisted to the app side container URL.
    if let id = FirezoneId.load(.pre140) {
      options.merge(["id": id as NSObject]) { _, new in new }
    }

    try session()?.startTunnel(options: options)
  }

  func stop(clearToken: Bool = false) {
    if clearToken {
      do {
        try session()?.sendProviderMessage(encoder.encode(TunnelMessage.signOut)) { _ in
          self.session()?.stopTunnel()
        }
      } catch {
        Log.error(error)
      }
    } else {
      session()?.stopTunnel()
    }
  }

  func updateInternetResourceState() {
    guard session()?.status == .connected else { return }

    try? session()?.sendProviderMessage(encoder.encode(TunnelMessage.internetResourceEnabled(internetResourceEnabled)))
  }

  func toggleInternetResource(enabled: Bool) {
    internetResourceEnabled = enabled
    updateInternetResourceState()
  }

  func fetchResources(callback: @escaping (ResourceList) -> Void) {
    guard session()?.status == .connected else { return }

    do {
      try session()?.sendProviderMessage(encoder.encode(TunnelMessage.getResourceList(resourceListHash))) { data in
        if let data = data {
          self.resourceListHash = Data(SHA256.hash(data: data))
          let decoder = JSONDecoder()
          decoder.keyDecodingStrategy = .convertFromSnakeCase

          guard let decoded = try? decoder.decode([Resource].self, from: data)
          else {
            fatalError("Should be able to decode ResourceList")
          }

          self.resourcesListCache = ResourceList.loaded(decoded)
        }

        callback(self.resourcesListCache)
      }
    } catch {
      Log.error(error)
    }
  }

  func clearLogs() async throws {
    return try await withCheckedThrowingContinuation { continuation in
      guard let session = session()
      else {
        continuation.resume(throwing: VPNConfigurationManagerError.managerNotInitialized)

        return
      }

      do {
        try session.sendProviderMessage(
          encoder.encode(TunnelMessage.clearLogs)
        ) { _ in continuation.resume() }
      } catch {
        continuation.resume(throwing: error)
      }
    }
  }

  func getLogFolderSize() async throws -> Int64 {
    return try await withCheckedThrowingContinuation { continuation in
      guard let session = session()
      else {
        continuation.resume(throwing: VPNConfigurationManagerError.managerNotInitialized)

        return
      }

      do {
        try session.sendProviderMessage(
          encoder.encode(TunnelMessage.getLogFolderSize)
        ) { data in

          guard let data = data
          else {
            continuation
              .resume(throwing: VPNConfigurationManagerError.noIPCData)

            return
          }
          data.withUnsafeBytes { rawBuffer in
            continuation.resume(returning: rawBuffer.load(as: Int64.self))
          }
        }
      } catch {
        continuation.resume(throwing: error)
      }
    }
  }

  // Call this with a closure that will append each chunk to a buffer
  // of some sort, like a file. The completed buffer is a valid Apple Archive
  // in AAR format.
  func exportLogs(
    appender: @escaping (LogChunk) -> Void,
    errorHandler: @escaping (VPNConfigurationManagerError) -> Void
  ) {
    let decoder = PropertyListDecoder()

    func loop() {
      do {
        try session()?.sendProviderMessage(
          encoder.encode(TunnelMessage.exportLogs)
        ) { data in
          guard let data = data
          else {
            errorHandler(VPNConfigurationManagerError.noIPCData)

            return
          }

          guard let chunk = try? decoder.decode(
            LogChunk.self, from: data
          )
          else {
            errorHandler(VPNConfigurationManagerError.decodeIPCDataFailed)

            return
          }

          appender(chunk)

          if !chunk.done {
            // Continue
            loop()
          }
        }
      } catch {
        Log.error(error)
      }
    }

    // Start exporting
    loop()
  }

  func consumeStopReason() async throws -> NEProviderStopReason? {
    return try await withCheckedThrowingContinuation { continuation in
      guard let session = session()
      else {
        continuation.resume(throwing: VPNConfigurationManagerError.managerNotInitialized)

        return
      }

      do {
        try session.sendProviderMessage(
          encoder.encode(TunnelMessage.consumeStopReason)
        ) { data in

          guard let data = data,
                let reason = String(data: data, encoding: .utf8),
                let rawValue = Int(reason)
          else {
            continuation.resume(returning: nil)

            return
          }

          continuation.resume(returning: NEProviderStopReason(rawValue: rawValue))
        }
      } catch {
        continuation.resume(throwing: error)
      }
    }
  }

  private func session() -> NETunnelProviderSession? {
    return manager?.connection as? NETunnelProviderSession
  }

  // Subscribe to system notifications about our VPN status changing
  // and let our handler know about them.
  private func subscribeToVPNStatusUpdates(
    handler: @escaping @MainActor (NEVPNStatus, Settings?, String?, NEProviderStopReason?
    ) async -> Void) {
    Log.log("\(#function)")

    for task in tunnelObservingTasks {
      task.cancel()
    }
    tunnelObservingTasks.removeAll()

    tunnelObservingTasks.append(
      Task {
        for await notification in NotificationCenter.default.notifications(
          named: .NEVPNStatusDidChange
        ) {
          guard let session = notification.object as? NETunnelProviderSession
          else {
            Log.error(VPNConfigurationManagerError.invalidStatusChange)
            return
          }

          var reason: NEProviderStopReason?

          if session.status == .disconnected {
            // Reset resource list
            resourceListHash = Data()
            resourcesListCache = ResourceList.loading

            // Attempt to consume the last stopped reason
            do { reason = try await consumeStopReason() } catch { Log.error(error) }
          }

          await handler(session.status, nil, nil, reason)
        }
      }
    )
  }
}
