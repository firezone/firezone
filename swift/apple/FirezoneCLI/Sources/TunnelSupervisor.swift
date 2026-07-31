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
@MainActor
final class TunnelSupervisor {
  private enum Action {
    case shutdown
    case restart
    case signIn
  }

  private static let connectTimeout = Duration.seconds(30)

  private let session: any TunnelSessionProtocol
  private let requestToken: () throws -> Token

  private var isRestarting = false
  private var hasRequestedToken = false
  private var timeoutTask: Task<Void, Never>?

  init(session: any TunnelSessionProtocol, requestToken: @escaping () throws -> Token) {
    self.session = session
    self.requestToken = requestToken
  }

  func run() async throws {
    let (actions, emit) = AsyncStream.makeStream(of: Action.self)

    if session.status == .connected {
      Log.info("Tunnel already connected")
    }

    let statusTask = Task { await watchStatus(emit: emit) }
    let signalSources = installSignalHandlers(emit: emit)
    startConnectTimeout(emit: emit)

    defer {
      timeoutTask?.cancel()
      statusTask.cancel()
      signalSources.forEach { $0.cancel() }
    }

    for await action in actions {
      switch action {
      case .shutdown:
        Log.info("Shutting down...")
        session.stopTunnel()
        return

      case .restart:
        Log.info("Restarting tunnel...")
        isRestarting = true
        session.stopTunnel()
        try IPCClient.start(session: session)
        Log.info("Tunnel restarted")

      case .signIn:
        timeoutTask?.cancel()
        hasRequestedToken = true
        let token = try requestToken()
        try IPCClient.start(session: session, token: token.description)
        Log.info("Tunnel started with token")
        startConnectTimeout(emit: emit)
      }
    }
  }

  // MARK: - Status

  private func watchStatus(emit: AsyncStream<Action>.Continuation) async {
    for await status in IPCClient.vpnStatusUpdates(session: session) {
      switch status {
      case .connected:
        Log.info("Tunnel connected")
        isRestarting = false
      case .connecting:
        Log.info("Tunnel connecting...")
      case .reasserting:
        Log.info("Tunnel reasserting...")
      case .disconnecting:
        Log.info("Tunnel disconnecting...")
      case .invalid:
        Log.warning("Tunnel status invalid")
      case .disconnected:
        await handleDisconnect(emit: emit)
      @unknown default:
        Log.warning("Unknown tunnel status: \(status.rawValue)")
      }
    }
  }

  private func handleDisconnect(emit: AsyncStream<Action>.Continuation) async {
    guard !isRestarting else {
      Log.info("Tunnel disconnected (restarting)")
      return
    }

    let error = await lastDisconnectError()

    if let error, !hasRequestedToken, Self.isTokenNotFound(error) {
      Log.info("Token not found in keychain: \(error)")
      emit.yield(.signIn)
      return
    }

    log(disconnect: error)
    emit.yield(.shutdown)
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
      Log.error("Timed out waiting for tunnel to connect")
      emit.yield(.shutdown)
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
