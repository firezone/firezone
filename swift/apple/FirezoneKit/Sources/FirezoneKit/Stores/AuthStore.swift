//
//  AuthStore.swift
//  (c) 2023 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Combine
import Dependencies
import Foundation
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

  enum LoginStatus {
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
  }

  @Dependency(\.keychain) private var keychain
  @Dependency(\.auth) private var auth

  let tunnelStore: TunnelStore

  public var authBaseURL: URL
  private var cancellables = Set<AnyCancellable>()

  @Published private(set) var loginStatus: LoginStatus

  private init(tunnelStore: TunnelStore) {
    self.tunnelStore = tunnelStore
    self.authBaseURL = AppInfoPlistConstants.authBaseURL
    self.loginStatus = .uninitialized

    tunnelStore.$tunnelAuthStatus
      .sink { [weak self] tunnelAuthStatus in
        guard let self = self else { return }
        Task {
          self.loginStatus = await self.getLoginStatus(from: tunnelAuthStatus)
        }
      }
      .store(in: &cancellables)
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

  func signOut() async throws {
    logger.trace("\(#function)")

    guard case .signedIn = self.loginStatus else {
      return
    }

    Task {
      if let tokenRef = try await tunnelStore.stopAndSignOut() {
        try await keychain.delete(tokenRef)
      }
    }
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

  func setAuthBaseURL(_ authBaseURL: URL, isChanged: inout Bool) {
    isChanged = (self.authBaseURL == authBaseURL)
    self.authBaseURL = authBaseURL
  }
}
