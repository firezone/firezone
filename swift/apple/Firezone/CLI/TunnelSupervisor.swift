//
//  TunnelSupervisor.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import FirezoneKit
import Foundation
import NetworkExtension

/// Follows a tunnel that was just started, and says why when it doesn't come up.
///
/// A tunnel that stops for want of a token ends the wait saying how to supply one,
/// since there is no way to ask for it here.
@MainActor
struct TunnelWatcher {
  private enum Outcome {
    case connected
    case failed(any Error)
  }

  private static let connectTimeout = Duration.seconds(30)

  let session: any TunnelSessionProtocol
  let noTokenAdvice: String

  /// Returns once the tunnel is connected, throws with the reason it never got there.
  func waitUntilConnected() async throws {
    let (outcomes, emit) = AsyncStream.makeStream(of: Outcome.self)

    let statusTask = Task {
      // The stream only carries what happens from here on, and the tunnel was started
      // before we got to look at it.
      guard session.status != .connected else {
        emit.yield(.connected)
        return
      }

      for await status in session.statusUpdates() {
        if status == .connected {
          emit.yield(.connected)
        } else if let error = await terminalError(for: status) {
          emit.yield(.failed(error))
        }
      }
    }

    let timeoutTask = Task {
      try? await Task.sleep(for: Self.connectTimeout)
      guard !Task.isCancelled else { return }
      guard session.status != .connected else {
        emit.yield(.connected)
        return
      }

      emit.yield(.failed(await timedOut()))
    }

    defer {
      statusTask.cancel()
      timeoutTask.cancel()
    }

    for await outcome in outcomes {
      switch outcome {
      case .connected:
        Log.info("Tunnel connected")
        return
      case .failed(let error):
        throw error
      }
    }
  }

  /// Returns when a connected tunnel is down again, with what took it down.
  func waitUntilDown() async -> any Error {
    if let error = await terminalError(for: session.status) {
      return error
    }

    for await status in session.statusUpdates() {
      if let error = await terminalError(for: status) {
        return error
      }
    }

    return CLIError("Tunnel disconnected")
  }

  /// Logs where the tunnel got to, and reports the error when it got nowhere.
  private func terminalError(for status: NEVPNStatus) async -> (any Error)? {
    switch status {
    case .connected:
      return nil
    case .connecting:
      Log.info("Tunnel connecting...")
      return nil
    case .reasserting:
      Log.info("Tunnel reasserting...")
      return nil
    case .disconnecting:
      Log.info("Tunnel disconnecting...")
      return nil
    case .invalid:
      // The profile or the system extension went away. Nothing is going to bring it
      // back on its own, and without this we would sit here doing nothing.
      return CLIError("VPN configuration is no longer usable, it may have been removed.")
    case .disconnected:
      return await disconnected()
    @unknown default:
      Log.warning("Unknown tunnel status: \(status.rawValue)")
      return nil
    }
  }

  private func disconnected() async -> any Error {
    let error = await lastDisconnectError()

    if let error, Self.isMissingCredential(error) {
      return CLIError(noTokenAdvice)
    }

    log(disconnect: error)

    return error ?? CLIError("Tunnel disconnected")
  }

  private func timedOut() async -> any Error {
    // The tunnel is started before this is watching it, so a provider that gave up
    // for want of a token can do so unobserved. Timing out would be an unhelpful way
    // to say that a token is all it needed.
    if let error = await lastDisconnectError(), Self.isMissingCredential(error) {
      return CLIError(noTokenAdvice)
    }

    return CLIError("Timed out waiting for the tunnel to connect.")
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
}

/// Keeps the tunnel running until a signal or an unrecoverable disconnect stops it.
///
/// SIGINT/SIGTERM shut down, SIGHUP restarts. The tunnel is stopped on the way out,
/// which is what a service manager supervising this process expects of it.
///
/// Anything other than a signal is a failure and is rethrown, so a service manager
/// watching the exit status can tell a tunnel that stopped from one that was stopped.
@MainActor
final class TunnelSupervisor {
  private enum Action {
    case shutdown
    case restart
  }

  private let watcher: TunnelWatcher
  private var session: any TunnelSessionProtocol { watcher.session }

  private var isRestarting = false
  private var failure: (any Error)?

  init(watcher: TunnelWatcher) {
    self.watcher = watcher
  }

  func run() async throws {
    let (actions, emit) = AsyncStream.makeStream(of: Action.self)

    let tunnelTask = Task { await follow(emit: emit) }
    let signalSources = installSignalHandlers(emit: emit)

    defer {
      tunnelTask.cancel()
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
        // races the stop and is dropped. `follow` picks it up from there.
        session.stopTunnel()
      }
    }
  }

  /// Follows the tunnel up and down again for as long as it keeps being restarted.
  private func follow(emit: AsyncStream<Action>.Continuation) async {
    while !Task.isCancelled {
      let error = await waitForTunnelToStop()

      guard isRestarting else {
        fail(with: error, emit: emit)
        return
      }

      isRestarting = false
      Log.info("Tunnel disconnected, starting it again")

      do {
        try IPCClient.start(session: session)
      } catch {
        fail(with: error, emit: emit)
        return
      }
    }
  }

  /// One run of the tunnel, from the start it was given to the next time it is down.
  private func waitForTunnelToStop() async -> any Error {
    do {
      try await watcher.waitUntilConnected()
    } catch {
      return error
    }

    return await watcher.waitUntilDown()
  }

  private func fail(with error: any Error, emit: AsyncStream<Action>.Continuation) {
    failure = error
    emit.yield(.shutdown)
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
