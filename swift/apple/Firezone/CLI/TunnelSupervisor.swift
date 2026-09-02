//
//  TunnelSupervisor.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import FirezoneKit
import Foundation
import NetworkExtension

/// Keeps the tunnel running until a signal or an unrecoverable disconnect stops it.
///
/// SIGINT/SIGTERM shut down, SIGHUP restarts. A tunnel that stops for want of a token
/// ends the run saying how to supply one, since there is no way to ask for it here.
///
/// Anything other than a signal is a failure and is rethrown, so a service manager
/// watching the exit status can tell a tunnel that stopped from one that was stopped.
@MainActor
final class TunnelSupervisor {
  private enum Action {
    case shutdown
    case restart
  }

  private static let connectTimeout = Duration.seconds(30)

  private let session: any TunnelSessionProtocol
  private let noTokenAdvice: String

  private var isRestarting = false
  private var failure: (any Error)?
  private var timeoutTask: Task<Void, Never>?

  init(session: any TunnelSessionProtocol, noTokenAdvice: String) {
    self.session = session
    self.noTokenAdvice = noTokenAdvice
  }

  func run() async throws {
    let (actions, emit) = AsyncStream.makeStream(of: Action.self)

    let statusTask = Task { await watchStatus(emit: emit) }
    let signalSources = installSignalHandlers(emit: emit)
    startConnectTimeout(emit: emit)

    defer {
      timeoutTask?.cancel()
      statusTask.cancel()
      for source in signalSources { source.cancel() }
    }

    for await action in actions {
      switch action {
      case .shutdown:
        Log.info("Shutting down...")
        session.stopTunnel()
        if let failure {
          throw failure
        }
        return

      case .restart:
        Log.info("Restarting tunnel...")
        isRestarting = true
        // Starting again has to wait for the tunnel to actually be down, or the start
        // races the stop and is dropped. `handle(status:)` picks it up from there.
        session.stopTunnel()
      }
    }
  }

  private func fail(with error: any Error, emit: AsyncStream<Action>.Continuation) {
    failure = error
    emit.yield(.shutdown)
  }

  // MARK: - Status

  private func watchStatus(emit: AsyncStream<Action>.Continuation) async {
    for await status in session.statusUpdates() {
      await handle(status: status, emit: emit)
    }
  }

  private func handle(status: NEVPNStatus, emit: AsyncStream<Action>.Continuation) async {
    switch status {
    case .connected:
      Log.info("Tunnel connected")
    case .connecting:
      Log.info("Tunnel connecting...")
    case .reasserting:
      Log.info("Tunnel reasserting...")
    case .disconnecting:
      Log.info("Tunnel disconnecting...")
    case .invalid:
      // The profile or the system extension went away. Nothing is going to bring it
      // back on its own, and without this the process would sit here doing nothing.
      fail(
        with: CLIError("VPN configuration is no longer usable, it may have been removed."),
        emit: emit)
    case .disconnected:
      await handleDisconnect(emit: emit)
    @unknown default:
      Log.warning("Unknown tunnel status: \(status.rawValue)")
    }
  }

  private func handleDisconnect(emit: AsyncStream<Action>.Continuation) async {
    if isRestarting {
      isRestarting = false
      Log.info("Tunnel disconnected, starting it again")
      do {
        try IPCClient.start(session: session)
        startConnectTimeout(emit: emit)
      } catch {
        fail(with: error, emit: emit)
      }
      return
    }

    let error = await lastDisconnectError()

    if let error, Self.isMissingCredential(error) {
      fail(with: CLIError(noTokenAdvice), emit: emit)
      return
    }

    log(disconnect: error)
    fail(with: error ?? CLIError("Tunnel disconnected"), emit: emit)
  }

  private func lastDisconnectError() async -> (any Error)? {
    await withCheckedContinuation { continuation in
      session.fetchLastDisconnectError { continuation.resume(returning: $0) }
    }
  }

  private static func isMissingCredential(_ error: any Error) -> Bool {
    let expected = PacketTunnelProviderError.credentialNotConfigured as NSError
    let actual = error as NSError
    return actual.domain == expected.domain && actual.code == expected.code
  }

  private func log(disconnect error: (any Error)?) {
    guard let error else {
      Log.info("Tunnel disconnected externally, shutting down...")
      return
    }

    let nsError = error as NSError
    guard nsError.domain == ConnlibError.errorDomain,
      let code = ConnlibError.Code(rawValue: nsError.code),
      let reason = nsError.userInfo["reason"] as? String
    else {
      Log.error("Tunnel disconnected: \(error)")
      return
    }

    switch code {
    case .sessionExpired: Log.error("Authentication failed: \(reason)")
    case .disconnected: Log.error("Tunnel disconnected: \(reason)")
    }
  }

  // MARK: - Timers and signals

  private func startConnectTimeout(emit: AsyncStream<Action>.Continuation) {
    timeoutTask?.cancel()
    timeoutTask = Task {
      try? await Task.sleep(for: Self.connectTimeout)
      guard !Task.isCancelled, session.status != .connected else { return }

      // The tunnel is started before this is watching it, so a provider that gave up
      // for want of a token can do so unobserved. Timing out would be an unhelpful way
      // to say that a token is all it needed.
      if let error = await lastDisconnectError(), Self.isMissingCredential(error) {
        fail(with: CLIError(noTokenAdvice), emit: emit)
        return
      }

      fail(with: CLIError("Timed out waiting for the tunnel to connect."), emit: emit)
    }
  }

  private func installSignalHandlers(
    emit: AsyncStream<Action>.Continuation
  ) -> [any DispatchSourceSignal] {
    let handled: [(Int32, Action)] = [
      (SIGINT, .shutdown),
      (SIGTERM, .shutdown),
      (SIGHUP, .restart),
    ]

    return handled.map { number, action in
      // Ignore the default disposition so the process survives long enough to react.
      signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
      source.setEventHandler { emit.yield(action) }
      source.resume()
      return source
    }
  }
}
