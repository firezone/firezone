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
    case decodeIPCDataFailed
    case noIPCData
    case invalidStatus(NEVPNStatus)

    var localizedDescription: String {
      switch self {
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

  init(session: NETunnelProviderSession) {
    self.session = session
  }

  // Encoder used to send messages to the tunnel
  let encoder = PropertyListEncoder()
  let decoder = PropertyListDecoder()

  // Auto-connect
  func start() throws {
    try session().startTunnel(options: nil)
  }

  // Sign in
  func start(token: String) throws {
    let options: [String: NSObject] = [
      "token": token as NSObject
    ]

    try session().startTunnel(options: options)
  }

  func signOut() async throws {
    try await sendMessageWithoutResponse(ProviderMessage.signOut)
  }

  func stop() throws {
    try session().stopTunnel()
  }

#if os(macOS)
  // On macOS, IPC calls to the system extension won't work after it's been upgraded, until the startTunnel call.
  // Since we rely on IPC for the GUI to function, we need to send a dummy `startTunnel` that doesn't actually
  // start the tunnel, but causes the system to start the extension.
  func startSystemExtension() throws {
    let options: [String: NSObject] = ["dryRun": true as NSObject]
    try session().startTunnel(options: options)
  }
#endif

  @MainActor
  func setConfiguration(_ configuration: Configuration) async throws {
    let tunnelConfiguration = configuration.toTunnelConfiguration()
    let message = ProviderMessage.setConfiguration(tunnelConfiguration)

    try await sendMessageWithoutResponse(message)
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
        continuation.resume(throwing: error)
      }
    }
  }
}
