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

extension AuthStore: DependencyKey {
  static var liveValue: AuthStore = .shared
}

extension DependencyValues {
  var authStore: AuthStore {
    get { self[AuthStore.self] }
    set { self[AuthStore.self] = newValue }
  }
}

@MainActor
final class AuthStore: ObservableObject {
  private let logger = Logger.make(for: AuthStore.self)

  static let shared = AuthStore(tunnelStore: TunnelStore.shared)

  enum LoginStatus: CustomStringConvertible {
    case uninitialized
    case signedOut(accountId: String?)
    case signedIn(accountId: String, actorName: String)

    var accountId: String? {
      switch self {
      case .uninitialized: return nil
      case .signedOut(let accountId): return accountId
      case .signedIn(let accountId, _): return accountId
      }
    }

    var description: String {
      switch self {
      case .uninitialized:
        return "uninitialized"
      case .signedOut(let accountId):
        return "signedOut(accountId: \(accountId ?? "nil"))"
      case .signedIn(let accountId, let actorName):
        return "signedIn(accountId: \(accountId), actorName: \(actorName))"
      }
    }
  }

  @Dependency(\.keychain) private var keychain
  @Dependency(\.auth) private var auth

  let tunnelStore: TunnelStore

  private var cancellables = Set<AnyCancellable>()

  @Published private(set) var loginStatus: LoginStatus {
    didSet {
      self.handleLoginStatusChanged()
    }
  }

  private var status: NEVPNStatus = .invalid

  private static let maxReconnectionAttemptCount = 3
  private var reconnectionAttemptsRemaining = maxReconnectionAttemptCount

  private init(tunnelStore: TunnelStore) {
    self.tunnelStore = tunnelStore
    self.loginStatus = .uninitialized

    Task {
      self.loginStatus = await self.getLoginStatus(from: tunnelStore.tunnelAuthStatus)
    }

    tunnelStore.$tunnelAuthStatus
      .sink { [weak self] tunnelAuthStatus in
        guard let self = self else { return }
        logger.log("Tunnel auth status changed to: \(tunnelAuthStatus)")
        Task {
          let loginStatus = await self.getLoginStatus(from: tunnelAuthStatus)
          if tunnelStore.tunnelAuthStatus == tunnelAuthStatus {
            // Make sure the tunnelAuthStatus hasn't changed while we were getting the login status
            self.loginStatus = loginStatus
          }
        }
      }
      .store(in: &cancellables)

    tunnelStore.$status
      .sink { [weak self] status in
        guard let self = self else { return }
        Task {
          if status == .disconnected {
            self.logger.log("\(#function): Disconnected")
            if let tsEvent = TunnelShutdownEvent.loadFromDisk() {
              self.logger.log(
                "\(#function): Tunnel shutdown event: \(tsEvent, privacy: .public)"
              )
              switch tsEvent.action {
              case .signoutImmediately:
                self.signOut()
              case .retryThenSignout:
                self.retryStartTunnel()
              }
            } else {
              self.logger.log("\(#function): Tunnel shutdown event not found")
            }
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

  private func getLoginStatus(from tunnelAuthStatus: TunnelAuthStatus) async -> LoginStatus {
    switch tunnelAuthStatus {
    case .tunnelUninitialized:
      return .uninitialized
    case .accountNotSetup:
      return .signedOut(accountId: nil)
    case .signedOut(_, let tunnelAccountId):
      return .signedOut(accountId: tunnelAccountId)
    case .signedIn(let tunnelAuthBaseURL, let tunnelAccountId, let tokenReference):
      guard self.authBaseURL == tunnelAuthBaseURL else {
        return .signedOut(accountId: tunnelAccountId)
      }
      let tunnelPortalURLString = self.authURL(accountId: tunnelAccountId).absoluteString
      guard let tokenAttributes = await keychain.loadAttributes(tokenReference),
        tunnelPortalURLString == tokenAttributes.authURLString
      else {
        return .signedOut(accountId: tunnelAccountId)
      }
      return .signedIn(accountId: tunnelAccountId, actorName: tokenAttributes.actorName)
    }
  }

  func signIn(accountId: String) async throws {
    logger.trace("\(#function)")

    let portalURL = authURL(accountId: accountId)
    let authResponse = try await auth.signIn(portalURL)
    let attributes = Keychain.TokenAttributes(
      authURLString: portalURL.absoluteString, actorName: authResponse.actorName ?? "")
    let tokenRef = try await keychain.store(authResponse.token, attributes)

    try await tunnelStore.saveAuthStatus(
      .signedIn(authBaseURL: self.authBaseURL, accountId: accountId, tokenReference: tokenRef))
  }

  func signIn() async throws {
    logger.trace("\(#function)")

    guard case .signedOut(let accountId) = self.loginStatus, let accountId = accountId,
      !accountId.isEmpty
    else {
      logger.log("No account-id found in tunnel")
      throw FirezoneError.missingTeamId
    }

    try await signIn(accountId: accountId)
  }

  func signOut() {
    logger.trace("\(#function)")

    guard case .signedIn = self.tunnelStore.tunnelAuthStatus else {
      logger.trace("\(#function): Not signed in, so can't signout.")
      return
    }

    Task {
      if let tokenRef = try await tunnelStore.stopAndSignOut() {
        try await keychain.delete(tokenRef)
      }
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
        logger.error("\(#function): Error starting tunnel: \(String(describing: error))")
      }
    }
  }

  func retryStartTunnel() {
    // Try to reconnect, but don't try more than 3 times at a time.
    // If this gets called the third time, sign out.
    let shouldReconnect = (self.reconnectionAttemptsRemaining > 0)
    self.reconnectionAttemptsRemaining = self.reconnectionAttemptsRemaining - 1
    if shouldReconnect {
      self.logger.log(
        "\(#function): Will try to reconnect after 1 second (\(self.reconnectionAttemptsRemaining) attempts after this)"
      )
      DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(1)) {
        self.logger.log("\(#function): Trying to reconnect")
        self.startTunnel()
      }
    } else {
      self.signOut()
    }
  }

  private func handleLoginStatusChanged() {
    logger.log("\(#function): Login status: \(self.loginStatus)")
    switch self.loginStatus {
    case .signedIn:
      Task {
        do {
          try await tunnelStore.start()
        } catch {
          logger.error("\(#function): Error starting tunnel: \(String(describing: error))")
        }
      }
    case .signedOut:
      Task {
        do {
          try await tunnelStore.stop()
        } catch {
          logger.error("\(#function): Error stopping tunnel: \(String(describing: error))")
        }
      }
    case .uninitialized:
      break
    }
  }

  func resetReconnectionAttemptsRemaining() {
    self.reconnectionAttemptsRemaining = Self.maxReconnectionAttemptCount
  }

  func tunnelAuthStatusForAccount(accountId: String) async -> TunnelAuthStatus {
    let portalURL = authURL(accountId: accountId)
    if let tokenRef = await keychain.searchByAuthURL(portalURL) {
      return .signedIn(authBaseURL: authBaseURL, accountId: accountId, tokenReference: tokenRef)
    } else {
      return .signedOut(authBaseURL: authBaseURL, accountId: accountId)
    }
  }

  func authURL(accountId: String) -> URL {
    self.authBaseURL.appendingPathComponent(accountId)
  }
}
