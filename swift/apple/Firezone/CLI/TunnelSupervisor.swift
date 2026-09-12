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
  /// A tunnel that is not up, ahead of working out what to say about it.
  enum Stop {
    case timedOut
    case invalidConfiguration
    case disconnected
  }

  private static let connectTimeout = Duration.seconds(30)
  private static let portalTimeout: Duration = .seconds(30)
  private static let portalPollInterval: Duration = .milliseconds(250)

  let session: any TunnelSessionProtocol
  let noTokenAdvice: String

  /// Returns once the tunnel is connected, throws with the reason it never got there.
  func waitUntilConnected() async throws {
    guard let stop = await waitForConnect() else { return }

    let error = await report(stop)

    throw error
  }

  /// Returns `nil` once the tunnel is connected, or how it stopped instead.
  func waitForConnect() async -> Stop? {
    let (outcomes, emit) = AsyncStream.makeStream(of: Stop?.self)

    let statusTask = Task {
      // The stream only carries what happens from here on, and the tunnel was started
      // before we got to look at it.
      guard session.status != .connected else {
        emit.yield(nil)
        return
      }

      for await status in session.statusUpdates() {
        announce(status: status)

        if status == .connected {
          emit.yield(nil)
        } else if let stop = Self.stop(for: status) {
          emit.yield(stop)
        }
      }
    }

    let timeoutTask = Task {
      try? await Task.sleep(for: Self.connectTimeout)
      guard !Task.isCancelled else { return }
      guard session.status != .connected else {
        emit.yield(nil)
        return
      }

      emit.yield(.timedOut)
    }

    defer {
      statusTask.cancel()
      timeoutTask.cancel()
    }

    for await outcome in outcomes {
      guard let stop = outcome else {
        if await portalNamedSession() {
          say("Tunnel connected")
        } else {
          say("Tunnel connected, but the portal has not answered yet")
        }

        return nil
      }

      return stop
    }

    return .timedOut
  }

  /// Waits for the portal to say who this session is.
  ///
  /// The system reports the tunnel connected as soon as its interface is up, before
  /// connlib has reached the portal. Returning then leaves a `status` run straight
  /// afterwards with nothing definite to say, so this holds until the extension can
  /// name the account, or until it is clear the portal is not answering.
  private func portalNamedSession() async -> Bool {
    let deadline = ContinuousClock.now + Self.portalTimeout

    while ContinuousClock.now < deadline {
      // A tunnel that went down meanwhile is the watcher's to report, not something
      // to wake up for the sake of asking.
      guard [.connected, .connecting, .reasserting].contains(session.status) else {
        return false
      }

      if case .connected? = try? await IPCClient.status(session: session, wakeIfStopped: false) {
        return true
      }

      try? await Task.sleep(for: Self.portalPollInterval)
    }

    return false
  }

  /// Returns when a connected tunnel is down again, with how it went down.
  func waitUntilDown() async -> Stop {
    if let stop = Self.stop(for: session.status) {
      return stop
    }

    for await status in session.statusUpdates() {
      announce(status: status)

      if let stop = Self.stop(for: status) {
        return stop
      }
    }

    return .disconnected
  }

  /// Says what happened, and hands back the error to fail with.
  func report(_ stop: Stop) async -> any Error {
    switch stop {
    case .timedOut:
      // The tunnel is started before this is watching it, so a provider that gave up
      // for want of a token can do so unobserved. Timing out would be an unhelpful way
      // to say that a token is all it needed.
      guard let error = await lastDisconnectError(), Self.isMissingCredential(error) else {
        return CLIError("Timed out waiting for the tunnel to connect.")
      }

      return CLIError(noTokenAdvice)

    case .invalidConfiguration:
      // The profile or the system extension went away. Nothing is going to bring it
      // back on its own.
      return CLIError("VPN configuration is no longer usable, it may have been removed.")

    case .disconnected:
      let error = await lastDisconnectError()

      if let error, Self.isMissingCredential(error) {
        return CLIError(noTokenAdvice)
      }

      announce(disconnect: error)

      return error ?? CLIError("Tunnel disconnected")
    }
  }

  private static func stop(for status: NEVPNStatus) -> Stop? {
    switch status {
    case .invalid: return .invalidConfiguration
    case .disconnected: return .disconnected
    case .connected, .connecting, .reasserting, .disconnecting: return nil
    @unknown default: return nil
    }
  }

  private func announce(status: NEVPNStatus) {
    switch status {
    case .connecting: say("Tunnel connecting...")
    case .reasserting: say("Tunnel reasserting...")
    case .disconnecting: say("Tunnel disconnecting...")
    case .connected, .disconnected, .invalid: break
    @unknown default: Log.warning("Unknown tunnel status: \(status.rawValue)")
    }
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

  private func announce(disconnect error: (any Error)?) {
    guard let error else {
      say("Tunnel disconnected externally, shutting down...")
      return
    }

    let nsError = error as NSError
    guard nsError.domain == ConnlibError.errorDomain,
      let code = ConnlibError.Code(rawValue: nsError.code),
      let reason = nsError.userInfo["reason"] as? String
    else {
      say("Tunnel disconnected: \(error)")
      return
    }

    switch code {
    case .sessionExpired: say("Authentication failed: \(reason)")
    case .disconnected: say("Tunnel disconnected: \(reason)")
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
        say("Shutting down...")
        session.stopTunnel()
        if let failure {
          throw failure
        }
        return

      case .restart:
        say("Restarting tunnel...")
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
      let stop = await waitForTunnelToStop()

      // A stop of our own says nothing about the tunnel, so it isn't reported.
      guard isRestarting else {
        fail(with: await watcher.report(stop), emit: emit)
        return
      }

      isRestarting = false
      say("Tunnel disconnected, starting it again")

      do {
        try IPCClient.start(session: session)
      } catch {
        fail(with: error, emit: emit)
        return
      }
    }
  }

  /// One run of the tunnel, from the start it was given to the next time it is down.
  private func waitForTunnelToStop() async -> TunnelWatcher.Stop {
    if let stop = await watcher.waitForConnect() {
      return stop
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
