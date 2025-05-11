//
//  IPCClient.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import CryptoKit
import Foundation
import NetworkExtension

// TODO: Use a more abstract IPC protocol to make this less terse
// TODO: Consider making this an actor to guarantee strict ordering

class IPCClient {
  enum Error: Swift.Error {
    case invalidNotification
    case decodeIPCDataFailed
    case noIPCData
    case invalidStatus(NEVPNStatus)

    var localizedDescription: String {
      switch self {
      case .invalidNotification:
        return "NEVPNStatusDidChange notification doesn't seem to be valid."
      case .decodeIPCDataFailed:
        return "Decoding IPC data failed."
      case .noIPCData:
        return "No IPC data returned from the XPC connection!"
      case .invalidStatus(let status):
        return "The IPC operation couldn't complete because the VPN status is \(status)."
      }
    }
  }

  // IPC only makes sense if there's a valid session. Session in this case refers to the `connection` field of
  // the NETunnelProviderManager instance.
  let session: NETunnelProviderSession

  // Track the "version" of the resource list so we can more efficiently
  // retrieve it from the Provider
  var resourceListHash = Data()

  // Cache resources on this side of the IPC barrier so we can
  // return them to callers when they haven't changed.
  var resourcesListCache: ResourceList = ResourceList.loading

  // Cache the configuration on this side of the IPC barrier so we can return it to callers if it hasn't changed.
  private var configurationHash = Data()
  private var configurationCache: Configuration?

  init(session: NETunnelProviderSession) {
    self.session = session
  }

  // Encoder used to send messages to the tunnel
  let encoder = PropertyListEncoder()
  let decoder = PropertyListDecoder()

  func start(token: String? = nil) throws {
    var options: [String: NSObject] = [:]

    // Pass token if provided
    if let token = token {
      options.merge(["token": token as NSObject]) { _, new in new }
    }

    try session().startTunnel(options: options)
  }

  func signOut() async throws {
    try await sendMessageWithoutResponse(ProviderMessage.signOut)
  }

  func stop() throws {
    try session([.connected, .connecting, .reasserting]).stopTunnel()
  }

  func getConfiguration() async throws -> Configuration? {
    return try await withCheckedThrowingContinuation { continuation in
      do {
        try session().sendProviderMessage(
          encoder.encode(ProviderMessage.getConfiguration(configurationHash))
        ) { data in
          guard let data = data
          else {
            // Configuration hasn't changed
            continuation.resume(returning: self.configurationCache)
            return
          }

          // Compute new hash
          self.configurationHash = Data(SHA256.hash(data: data))

          do {
            let decoded = try self.decoder.decode(Configuration.self, from: data)
            self.configurationCache = decoded
            continuation.resume(returning: decoded)
          } catch {
            continuation.resume(throwing: error)
          }
        }
      } catch {
        continuation.resume(throwing: error)
      }
    }
  }

  func setAuthURL(_ authURL: URL) async throws {
    try await sendMessageWithoutResponse(ProviderMessage.setAuthURL(authURL))
  }

  func setApiURL(_ apiURL: URL) async throws {
    try await sendMessageWithoutResponse(ProviderMessage.setApiURL(apiURL))
  }

  func setLogFilter(_ logFilter: String) async throws {
    try await sendMessageWithoutResponse(ProviderMessage.setLogFilter(logFilter))
  }

  func setActorName(_ actorName: String) async throws {
    try await sendMessageWithoutResponse(ProviderMessage.setActorName(actorName))
  }

  func setAccountSlug(_ accountSlug: String) async throws {
    try await sendMessageWithoutResponse(ProviderMessage.setAccountSlug(accountSlug))
  }

  func setInternetResourceEnabled(_ enabled: Bool) async throws {
    try await sendMessageWithoutResponse(ProviderMessage.setInternetResourceEnabled(enabled))
  }

  func fetchResources() async throws -> ResourceList {
    return try await withCheckedThrowingContinuation { continuation in
      do {
        // Request list of resources from the provider. We send the hash of the resource list we already have.
        // If it differs, we'll get the full list in the callback. If not, we'll get nil.
        try session([.connected]).sendProviderMessage(
          encoder.encode(ProviderMessage.getResourceList(resourceListHash))) { data in
            guard let data = data
            else {
              // No data returned; Resources haven't changed
              continuation.resume(returning: self.resourcesListCache)

              return
            }

            // Save hash to compare against
            self.resourceListHash = Data(SHA256.hash(data: data))

            let jsonDecoder = JSONDecoder()
            jsonDecoder.keyDecodingStrategy = .convertFromSnakeCase

            do {
              let decoded = try jsonDecoder.decode([Resource].self, from: data)
              self.resourcesListCache = ResourceList.loaded(decoded)

              continuation.resume(returning: self.resourcesListCache)
            } catch {
              continuation.resume(throwing: error)
            }
          }
      } catch {
        continuation.resume(throwing: error)
      }
    }
  }

  func clearLogs() async throws {
    try await sendMessageWithoutResponse(ProviderMessage.clearLogs)
  }

  func getLogFolderSize() async throws -> Int64 {
    return try await withCheckedThrowingContinuation { continuation in

      do {
        try session().sendProviderMessage(
          encoder.encode(ProviderMessage.getLogFolderSize)
        ) { data in

          guard let data = data
          else {
            continuation
              .resume(throwing: Error.noIPCData)

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
    errorHandler: @escaping (Error) -> Void
  ) {
    func loop() {
      do {
        try session().sendProviderMessage(
          encoder.encode(ProviderMessage.exportLogs)
        ) { data in
          guard let data = data
          else {
            errorHandler(Error.noIPCData)

            return
          }

          guard let chunk = try? self.decoder.decode(
            LogChunk.self, from: data
          )
          else {
            errorHandler(Error.decodeIPCDataFailed)

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
      do {
        try session().sendProviderMessage(
          encoder.encode(ProviderMessage.consumeStopReason)
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

  // Subscribe to system notifications about our VPN status changing
  // and let our handler know about them.
  func subscribeToVPNStatusUpdates(handler: @escaping @MainActor (NEVPNStatus) async throws -> Void) {
    Task {
      for await notification in NotificationCenter.default.notifications(named: .NEVPNStatusDidChange) {
        guard let session = notification.object as? NETunnelProviderSession
        else {
          Log.error(Error.invalidNotification)
          return
        }

        if session.status == .disconnected {
          // Reset resource list
          resourceListHash = Data()
          resourcesListCache = ResourceList.loading
        }

        do { try await handler(session.status) } catch { Log.error(error) }
      }
    }
  }

  func sessionStatus() -> NEVPNStatus {
    return session.status
  }

  private func session(_ requiredStatuses: Set<NEVPNStatus> = []) throws -> NETunnelProviderSession {
    if requiredStatuses.isEmpty || requiredStatuses.contains(session.status) {
      return session
    }

    throw Error.invalidStatus(session.status)
  }

  private func sendMessageWithoutResponse(_ message: ProviderMessage) async throws {
    try await withCheckedThrowingContinuation { continuation in
      do {
        try session().sendProviderMessage(encoder.encode(message)) { _ in
          continuation.resume()
        }
      } catch {
        Log.error(error)
        continuation.resume(throwing: error)
      }
    }
  }
}
