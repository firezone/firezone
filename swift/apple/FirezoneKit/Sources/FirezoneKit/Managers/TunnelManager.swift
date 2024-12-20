//
//  TunnelManager.swift
//
//
//  Created by Jamil Bou Kheir on 4/2/24.
//
//  Abstracts the nitty gritty of loading and saving to our
//  VPN profile in system preferences.

import CryptoKit
import Foundation
import NetworkExtension

enum TunnelManagerError: Error {
  case cannotSaveIfMissing
  case decodeIPCDataFailed
}

public enum TunnelManagerKeys {
  static let actorName = "actorName"
  static let authBaseURL = "authBaseURL"
  static let apiURL = "apiURL"
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
      }
  }
}

public class TunnelManager {
  public static let shared = TunnelManager()

  // Expose closures that someone else can use to respond to events
  // for this manager.
  var statusChangeHandler: ((NEVPNStatus) async -> Void)?

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
  private let encoder = PropertyListEncoder()

  public static let bundleIdentifier: String = "\(Bundle.main.bundleIdentifier!).network-extension"
  private let bundleDescription = "Firezone"

  // Initialize and save a new VPN profile in system Preferences
  func create() async throws -> Settings {
    let protocolConfiguration = NETunnelProviderProtocol()
    let manager = NETunnelProviderManager()
    let settings = Settings.defaultValue

    protocolConfiguration.providerConfiguration = settings.toProviderConfiguration()
    protocolConfiguration.providerBundleIdentifier = TunnelManager.bundleIdentifier
    protocolConfiguration.serverAddress = settings.apiURL
    manager.localizedDescription = bundleDescription
    manager.protocolConfiguration = protocolConfiguration
    encoder.outputFormat = .binary

    // Save the new VPN profile to System Preferences and reload it,
    // which should update our status from invalid -> disconnected.
    // If the user denied the operation, the status will be .invalid
    try await manager.saveToPreferences()
    try await manager.loadFromPreferences()

    await statusChangeHandler?(manager.connection.status)
    self.manager = manager

    return settings
  }

  func load(callback: @escaping (NEVPNStatus, Settings?, String?) -> Void) {
    Task {
      // loadAllFromPreferences() returns list of tunnel configurations created by our main app's bundle ID.
      // Since our bundle ID can change (by us), find the one that's current and ignore the others.
      guard let managers = try? await NETunnelProviderManager.loadAllFromPreferences()
      else {
        Log.app.error("\(#function): Could not load VPN configurations!")
        return
      }

      Log.app.log("\(#function): \(managers.count) tunnel managers found")
      for manager in managers {
        if let protocolConfiguration = manager.protocolConfiguration as? NETunnelProviderProtocol,
           protocolConfiguration.providerBundleIdentifier == TunnelManager.bundleIdentifier,
           let providerConfiguration = protocolConfiguration.providerConfiguration as? [String: String]
        {
          // Found it
          let settings = Settings.fromProviderConfiguration(providerConfiguration)
          let actorName = providerConfiguration[TunnelManagerKeys.actorName]
          if let internetResourceEnabled = providerConfiguration[TunnelManagerKeys.internetResourceEnabled]?.data(using: .utf8) {

            self.internetResourceEnabled = (try? JSONDecoder().decode(Bool.self, from: internetResourceEnabled)) ?? false

          }
          let status = manager.connection.status

          // Share what we found with our caller
          callback(status, settings, actorName)

          // Update our state
          self.manager = manager

          // Stop looking for our tunnel
          break
        }
      }

      // Hook up status updates
      setupTunnelObservers()

      // If no tunnel configuration was found, update state to
      // prompt user to create one.
      if manager == nil {
        callback(.invalid, nil, nil)
      }
    }
  }

  func saveActorName(_ actorName: String?) async throws {
    guard let manager = manager,
          let protocolConfiguration = manager.protocolConfiguration as? NETunnelProviderProtocol,
          var providerConfiguration = protocolConfiguration.providerConfiguration
    else {
      Log.app.error("Manager doesn't seem initialized. Can't save settings.")
      throw TunnelManagerError.cannotSaveIfMissing
    }

    providerConfiguration[TunnelManagerKeys.actorName] = actorName
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
      Log.app.error("Manager doesn't seem initialized. Can't save settings.")
      throw TunnelManagerError.cannotSaveIfMissing
    }

    var newProviderConfiguration = settings.toProviderConfiguration()

    // Don't clobber existing actorName
    newProviderConfiguration[TunnelManagerKeys.actorName] = providerConfiguration[TunnelManagerKeys.actorName]
    protocolConfiguration.providerConfiguration = newProviderConfiguration
    protocolConfiguration.serverAddress = settings.apiURL
    manager.protocolConfiguration = protocolConfiguration

    // We always set this to true when starting the tunnel in case our tunnel
    // was disabled by the system for some reason.
    manager.isEnabled = true

    try await manager.saveToPreferences()
    try await manager.loadFromPreferences()
  }

  func start(token: String? = nil) {
    var options: [String: NSObject]?

    if let token = token {
      options = ["token": token as NSObject]
    }

    do {
      try session().startTunnel(options: options)
    } catch {
      Log.app.error("Error starting tunnel: \(error)")
    }
  }

  func stop(clearToken: Bool = false) {
    if clearToken {
      do {
        try session().sendProviderMessage(encoder.encode(TunnelMessage.signOut)) { _ in
          self.session().stopTunnel()
        }
      } catch {
        Log.app.error("\(#function): \(error)")
      }
    } else {
      session().stopTunnel()
    }
  }

  func updateInternetResourceState() {
    guard session().status == .connected else { return }

    try? session().sendProviderMessage(encoder.encode(TunnelMessage.internetResourceEnabled(internetResourceEnabled))) { _ in }
  }

  func toggleInternetResource(enabled: Bool) {
    internetResourceEnabled = enabled
    updateInternetResourceState()
  }

  func fetchResources(callback: @escaping (ResourceList) -> Void) {
    guard session().status == .connected else { return }

    do {
      try session().sendProviderMessage(encoder.encode(TunnelMessage.getResourceList(resourceListHash))) { data in
        if let data = data {
          self.resourceListHash = Data(SHA256.hash(data: data))
          let decoder = JSONDecoder()
          decoder.keyDecodingStrategy = .convertFromSnakeCase
          self.resourcesListCache = ResourceList.loaded(try! decoder.decode([Resource].self, from: data))
        }

        callback(self.resourcesListCache)
      }
    } catch {
      Log.app.error("Error: sendProviderMessage: \(error)")
    }
  }

  func clearLogs() async throws {
    return try await withCheckedThrowingContinuation { continuation in
      do {
        try session().sendProviderMessage(
          encoder.encode(TunnelMessage.clearLogs)
        ) { _ in continuation.resume() }
      } catch {
        continuation.resume(throwing: error)
      }
    }
  }

  func getLogFolderSize() async throws -> Int64 {
    return try await withCheckedThrowingContinuation { continuation in
      do {
        try session().sendProviderMessage(
          encoder.encode(TunnelMessage.getLogFolderSize)
        ) { data in

          guard let data = data
          else {
            continuation
              .resume(throwing: TunnelManagerError.decodeIPCDataFailed)

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
    errorHandler: @escaping (TunnelManagerError) -> Void
  ) {
    let decoder = PropertyListDecoder()

    func loop() {
      do {
        try session().sendProviderMessage(
          encoder.encode(TunnelMessage.exportLogs)
        ) { data in
          guard let data = data
          else {
            Log.app.error("Error: \(#function): No data received")
            errorHandler(TunnelManagerError.decodeIPCDataFailed)

            return
          }

          guard let chunk = try? decoder.decode(
            LogChunk.self, from: data
          )
          else {
            Log.app.error("Error: \(#function): Invalid data received")
            errorHandler(TunnelManagerError.decodeIPCDataFailed)

            return
          }

          appender(chunk)

          if !chunk.done {
            // Continue
            loop()
          }
        }
      } catch {
        Log.app.error("Error: \(#function): \(error)")
      }
    }

    // Start exporting
    loop()
  }

  private func session() -> NETunnelProviderSession {
    guard let manager = manager,
          let session = manager.connection as? NETunnelProviderSession
    else { fatalError("Could not cast tunnel connection to NETunnelProviderSession!") }

    return session
  }

  // Subscribe to system notifications about our VPN status changing
  // and let our handler know about them.
  private func setupTunnelObservers() {
    Log.app.log("\(#function)")

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
            Log.app.error("\(#function): NEVPNStatusDidChange notification doesn't seem to be valid")
            return
          }

          if session.status == .disconnected {
            // Reset resource list on disconnect
            resourceListHash = Data()
            resourcesListCache = ResourceList.loading
          }

          await statusChangeHandler?(session.status)
        }
      }
    )
  }
}
