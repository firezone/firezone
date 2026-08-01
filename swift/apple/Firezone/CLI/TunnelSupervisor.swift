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
/// SIGINT/SIGTERM shut down, SIGHUP restarts. If the extension reports a missing
/// token, `requestToken` is called once to sign in and the tunnel is retried.
///
/// Anything other than a signal is a failure and is rethrown, so a service manager
/// watching the exit status can tell a tunnel that stopped from one that was stopped.
@MainActor
final class TunnelSupervisor {
  private enum Action {
    case shutdown
    case restart
    case signIn
    case tokenReceived(Token)
  }

  private static let connectTimeout = Duration.seconds(30)

  private let session: any TunnelSessionProtocol
  private let requestToken: () async throws -> Token

  private var isRestarting = false
  private var hasRequestedToken = false
  private var isAwaitingToken = false
  private var failure: (any Error)?
  private var timeoutTask: Task<Void, Never>?
  private var signInTask: Task<Void, Never>?

  init(session: any TunnelSessionProtocol, requestToken: @escaping () async throws -> Token) {
    self.session = session
    self.requestToken = requestToken
  }

  func run() async throws {
    let (actions, emit) = AsyncStream.makeStream(of: Action.self)

    let statusTask = Task { await watchStatus(emit: emit) }
    let signalSources = installSignalHandlers(emit: emit)
    startConnectTimeout(emit: emit)

    defer {
      timeoutTask?.cancel()
      signInTask?.cancel()
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

      case .signIn:
        timeoutTask?.cancel()
        // Signing in waits on the user, so it runs alongside the loop rather than
        // inside it. A signal arriving mid-prompt still shuts us down promptly.
        signInTask = Task { await signIn(emit: emit) }

      case .tokenReceived(let token):
        isAwaitingToken = false
        try IPCClient.start(session: session, token: token.description)
        Log.info("Tunnel started with token")
        startConnectTimeout(emit: emit)
      }
    }
  }

  private func signIn(emit: AsyncStream<Action>.Continuation) async {
    do {
      emit.yield(.tokenReceived(try await requestToken()))
    } catch {
      isAwaitingToken = false
      fail(with: error, emit: emit)
    }
  }

  private func fail(with error: any Error, emit: AsyncStream<Action>.Continuation) {
    failure = error
    emit.yield(.shutdown)
  }

  // MARK: - Status

  private func watchStatus(emit: AsyncStream<Action>.Continuation) async {
    for await status in IPCClient.vpnStatusUpdates(session: session) {
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

    if isAwaitingToken {
      // Of course it's disconnected: it has no token, which is what we're waiting on.
      // Failing here would tear down the prompt mid-answer.
      Log.info("Tunnel disconnected, waiting for the token")
      return
    }

    let error = await lastDisconnectError()

    if let error, !hasRequestedToken, Self.isTokenNotFound(error) {
      // Set before yielding, so a repeated disconnect can't queue a second prompt.
      hasRequestedToken = true
      isAwaitingToken = true
      Log.info("Token not found in keychain: \(error)")
      emit.yield(.signIn)
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

  private static func isTokenNotFound(_ error: any Error) -> Bool {
    let expected = PacketTunnelProviderError.tokenNotFoundInKeychain as NSError
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
      // for want of a token can do so unobserved. Nothing else would ask for one, and
      // timing out instead would be an unhelpful way to say "sign in".
      if !hasRequestedToken, let error = await lastDisconnectError(),
        Self.isTokenNotFound(error)
      {
        hasRequestedToken = true
        isAwaitingToken = true
        Log.info("Token not found in keychain: \(error)")
        emit.yield(.signIn)
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
