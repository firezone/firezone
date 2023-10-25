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

  private var cancellables = Set<AnyCancellable>()

  @Published private(set) var loginStatus: LoginStatus

  private init(tunnelStore: TunnelStore) {
    self.tunnelStore = tunnelStore
    self.loginStatus = .uninitialized

    tunnelStore.$tunnelState
      .sink { [weak self] tunnelState in
        guard let self = self else { return }
        Task {
          self.loginStatus = await self.getLoginStatus(from: tunnelState)
        }
      }
      .store(in: &cancellables)
  }

  private func getLoginStatus(from tunnelState: TunnelState) async -> LoginStatus {
    switch tunnelState {
    case .tunnelUninitialized:
      return .uninitialized
    case .accountNotSetup:
      return .signedOut(accountId: nil)
    case .signedOut(_, let tunnelAccountId, _, _):
      return .signedOut(accountId: tunnelAccountId)
    case .signedIn(let tunnelAuthBaseURL, let tunnelAccountId, _, _, let tokenReference):
      let tunnelAuthURLString = self.authURL(
        authBaseURL: tunnelAuthBaseURL, accountId: tunnelAccountId
      ).absoluteString
      guard let tokenAttributes = await keychain.loadAttributes(tokenReference),
        tunnelAuthURLString == tokenAttributes.authURLString
      else {
        return .signedOut(accountId: tunnelAccountId)
      }
      return .signedIn(accountId: tunnelAccountId, actorName: tokenAttributes.actorName)
    }
  }

  func signIn(accountId: String) async throws {
    logger.trace("\(#function)")

    let authURL = authURL(authBaseURL: tunnelStore.tunnelState.authBaseURL(), accountId: accountId)
    let authResponse = try await auth.signIn(authURL)
    let attributes = Keychain.TokenAttributes(
      authURLString: authURL.absoluteString, actorName: authResponse.actorName ?? "")
    let tokenRef = try await keychain.store(authResponse.token, attributes)

    try await tunnelStore.setState(
      .signedIn(
        authBaseURL: tunnelStore.tunnelState.authBaseURL(), accountId: accountId,
        apiURL: tunnelStore.tunnelState.apiURL(), logFilter: tunnelStore.tunnelState.logFilter(),
        tokenReference: tokenRef))
  }

  func signIn() async throws {
    logger.trace("\(#function)")

    guard case .signedOut(let accountId) = self.loginStatus, let accountId = accountId,
      !accountId.isEmpty
    else {
      logger.log("No account-id found in tunnel")
      throw FirezoneError.missingAccountId
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

  func tunnelStateForAccount(authBaseURL: URL, accountId: String, apiURL: URL, logFilter: String)
    async -> TunnelState
  {
    let authURL = authURL(authBaseURL: authBaseURL, accountId: accountId)
    if let tokenRef = await keychain.searchByAuthURL(authURL) {
      logger.debug("Found tokenref")
      return .signedIn(
        authBaseURL: authBaseURL, accountId: accountId, apiURL: apiURL, logFilter: logFilter,
        tokenReference: tokenRef)
    } else {
      logger.debug("signed out")
      return .signedOut(
        authBaseURL: authBaseURL, accountId: accountId, apiURL: apiURL, logFilter: logFilter)
    }
  }

  func authURL(authBaseURL: URL, accountId: String) -> URL {
    authBaseURL.appendingPathComponent(accountId)
  }
}
