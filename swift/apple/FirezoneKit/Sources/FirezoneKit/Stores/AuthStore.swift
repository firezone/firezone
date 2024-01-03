//
//  AuthStore.swift
//  (c) 2023 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Combine
import Dependencies
import Foundation
import NetworkExtension
import OSLog

@MainActor
public final class AuthStore: ObservableObject {
  private let logger = Logger.make(for: AuthStore.self)

  enum LoginStatus: CustomStringConvertible {
    case uninitialized
    case needsTunnelCreationPermission
    case signedOut
    case signedIn(actorName: String)

    var description: String {
      switch self {
      case .uninitialized:
        return "uninitialized"
      case .needsTunnelCreationPermission:
        return "needsTunnelCreationPermission"
      case .signedOut:
        return "signedOut"
      case .signedIn(let actorName):
        return "signedIn(actorName: \(actorName))"
      }
    }
  }

  @Dependency(\.keychain) private var keychain
  @Dependency(\.auth) private var auth
  @Dependency(\.mainQueue) private var mainQueue

  let tunnelStore: TunnelStore

  private var cancellables = Set<AnyCancellable>()

  @Published private(set) var loginStatus: LoginStatus {
    didSet {
      self.handleLoginStatusChanged()
    }
  }

  private var status: NEVPNStatus = .invalid

  // Try to automatically reconnect on network changes
  private static let maxReconnectionAttemptCount = 60
  private let reconnectDelaySecs = 1
  private var reconnectionAttemptsRemaining = maxReconnectionAttemptCount

  init(tunnelStore: TunnelStore) {
    self.tunnelStore = tunnelStore
    self.loginStatus = .uninitialized

    Task {
      self.loginStatus = await self.getLoginStatus(from: tunnelStore.tunnelAuthStatus)
    }

    tunnelStore.$tunnelAuthStatus
      .receive(on: mainQueue)
      .sink { [weak self] tunnelAuthStatus in
        guard let self = self else { return }
        logger.log("Tunnel auth status changed to: \(tunnelAuthStatus)")
        self.upateLoginStatus()
      }
      .store(in: &cancellables)

    tunnelStore.$status
      .sink { [weak self] status in
        guard let self = self else { return }
        Task {
          if status == .disconnected {
            self.handleTunnelDisconnectionEvent()
          }
          if status == .connected {
            self.resetReconnectionAttemptsRemaining()
          }
          self.status = status
        }
      }
      .store(in: &cancellables)
  }

  private var authBaseURL: URL {
    if let advancedSettings = self.tunnelStore.advancedSettings(),
      let url = URL(string: advancedSettings.authBaseURLString)
    {
      return url
    }
    return URL(string: AdvancedSettings.defaultValue.authBaseURLString)!
  }

  private func upateLoginStatus() {
    Task {
      let loginStatus = await self.getLoginStatus(from: self.tunnelStore.tunnelAuthStatus)
      await MainActor.run {
        self.loginStatus = loginStatus
      }
    }
  }

  private func getLoginStatus(from tunnelAuthStatus: TunnelAuthStatus) async -> LoginStatus {
    switch tunnelAuthStatus {
    case .uninitialized:
      return .uninitialized
    case .noTunnelFound:
      return .needsTunnelCreationPermission
    case .signedOut:
      return .signedOut
    case .signedIn(let tunnelAuthBaseURL, let tokenReference):
      guard self.authBaseURL == tunnelAuthBaseURL else {
        return .signedOut
      }
      let tunnelBaseURLString = self.authBaseURL.absoluteString
      guard let tokenAttributes = await keychain.loadAttributes(tokenReference),
        tunnelBaseURLString == tokenAttributes.authBaseURLString
      else {
        return .signedOut
      }
      return .signedIn(actorName: tokenAttributes.actorName)
    }
  }

  func signIn() async throws {
    logger.trace("\(#function)")

    let authResponse = try await auth.signIn(self.authBaseURL)
    let attributes = Keychain.TokenAttributes(
      authBaseURLString: self.authBaseURL.absoluteString, actorName: authResponse.actorName ?? "")
    let tokenRef = try await keychain.store(authResponse.token, attributes)

    try await tunnelStore.saveAuthStatus(
      .signedIn(authBaseURL: self.authBaseURL, tokenReference: tokenRef))
  }

  func signOut() async {
    logger.trace("\(#function)")

    guard case .signedIn = self.tunnelStore.tunnelAuthStatus else {
      logger.trace("\(#function): Not signed in, so can't signout.")
      return
    }

    do {
      try await tunnelStore.stop()
      if let tokenRef = try await tunnelStore.signOut() {
        try await keychain.delete(tokenRef)
      }
    } catch {
      logger.error("\(#function): Error signing out: \(error, privacy: .public)")
    }

    resetReconnectionAttemptsRemaining()
  }

  func startTunnel() {
    logger.trace("\(#function)")

    guard case .signedIn = self.tunnelStore.tunnelAuthStatus else {
      logger.trace("\(#function): Not signed in, so can't start the tunnel.")
      return
    }

    Task {
      do {
        try await tunnelStore.start()
      } catch {
        if case TunnelStoreError.startTunnelErrored(let startTunnelError) = error {
          logger.error(
            "\(#function): Starting tunnel errored: \(String(describing: startTunnelError))"
          )
          handleTunnelDisconnectionEvent()
        } else {
          logger.error("\(#function): Starting tunnel failed: \(String(describing: error))")
          // Disconnection event will be handled in the tunnel status change handler
        }
      }
    }
  }

  func handleTunnelDisconnectionEvent() {
    logger.log("\(#function)")
    if let tsEvent = TunnelShutdownEvent.loadFromDisk() {
      self.logger.log(
        "\(#function): Tunnel shutdown event: \(tsEvent, privacy: .public)"
      )
      switch tsEvent.action {
      case .signoutImmediately:
        Task {
          await self.signOut()
        }
      case .retryThenSignout:
        self.retryStartTunnel()
      case .doNothing:
        break
      }
    } else {
      self.logger.log("\(#function): Tunnel shutdown event not found")
      self.retryStartTunnel()
    }
  }

  func retryStartTunnel() {
    // Try to reconnect, but don't try more than 3 times at a time.
    // If this gets called the third time, sign out.
    let shouldReconnect = (self.reconnectionAttemptsRemaining > 0)
    self.reconnectionAttemptsRemaining = self.reconnectionAttemptsRemaining - 1
    if shouldReconnect {
      self.logger.log(
        "\(#function): Will try every second to reconnect (\(self.reconnectionAttemptsRemaining) attempts after this)"
      )
      DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(self.reconnectDelaySecs)) {
        self.logger.log("\(#function): Trying to reconnect")
        self.startTunnel()
      }
    } else {
      Task {
        await self.signOut()
      }
    }
  }

  private func handleLoginStatusChanged() {
    logger.log("\(#function): Login status: \(self.loginStatus)")
    switch self.loginStatus {
    case .signedIn:
      self.startTunnel()
    case .signedOut:
      Task {
        do {
          try await tunnelStore.stop()
        } catch {
          logger.error("\(#function): Error stopping tunnel: \(String(describing: error))")
        }
        if tunnelStore.tunnelAuthStatus != .signedOut {
          // Bring tunnelAuthStatus in line, in case it's out of touch with the login status
          try await tunnelStore.saveAuthStatus(.signedOut)
        }
      }
    case .needsTunnelCreationPermission:
      break
    case .uninitialized:
      break
    }
  }

  func resetReconnectionAttemptsRemaining() {
    self.reconnectionAttemptsRemaining = Self.maxReconnectionAttemptCount
  }

  func tunnelAuthStatus(for authBaseURL: URL) async -> TunnelAuthStatus {
    if let tokenRef = await keychain.searchByAuthBaseURL(authBaseURL) {
      return .signedIn(authBaseURL: authBaseURL, tokenReference: tokenRef)
    } else {
      return .signedOut
    }
  }
}
