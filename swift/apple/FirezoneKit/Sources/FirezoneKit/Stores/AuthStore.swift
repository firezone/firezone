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
  }

  @Dependency(\.keychain) private var keychain
  @Dependency(\.auth) private var auth

  let tunnelStore: TunnelStore

  public let authBaseURL: URL
  private var cancellables = Set<AnyCancellable>()

  @Published private(set) var loginStatus: LoginStatus

  private init(tunnelStore: TunnelStore) {
    self.tunnelStore = tunnelStore
    self.authBaseURL = Self.getAuthBaseURLFromInfoPlist()
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
      case .signedOut(let tunnelAuthBaseURL, let tunnelAccountId):
        if self.authBaseURL == tunnelAuthBaseURL {
          return .signedOut(accountId: tunnelAccountId)
        } else {
          return .signedOut(accountId: nil)
        }
      case .signedIn(let tunnelAuthBaseURL, let tunnelAccountId, let tokenReference):
        guard self.authBaseURL == tunnelAuthBaseURL else {
          return .signedOut(accountId: nil)
        }
        let tunnelPortalURLString = self.authURL(accountId: tunnelAccountId).absoluteString
        guard let tokenAttributes = await keychain.loadAttributes(tokenReference),
              tunnelPortalURLString == tokenAttributes.portalURLString else {
          return .signedOut(accountId: tunnelAccountId)
        }
        return .signedIn(accountId: tunnelAccountId, actorName: tokenAttributes.actorName)
    }
  }

  func signIn(accountId: String) async throws {
    logger.trace("\(#function)")

    let portalURL = authURL(accountId: accountId)
    let authResponse = try await auth.signIn(portalURL)
    let attributes = Keychain.TokenAttributes(portalURLString: portalURL.absoluteString, actorName: authResponse.actorName ?? "")
    let tokenRef = try await keychain.store(authResponse.token, attributes)

    try await tunnelStore.setAuthStatus(.signedIn(authBaseURL: self.authBaseURL, accountId: accountId, tokenReference: tokenRef))
  }

  func signIn() async throws {
    logger.trace("\(#function)")

    guard case .signedOut(let accountId) = self.loginStatus, let accountId = accountId, !accountId.isEmpty else {
      logger.debug("No account-id found in tunnel")
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

  static func getAuthBaseURLFromInfoPlist() -> URL {
    let infoPlistDictionary = Bundle.main.infoDictionary
    guard let urlScheme = (infoPlistDictionary?["AuthURLScheme"] as? String), !urlScheme.isEmpty else {
      fatalError("AuthURLScheme missing in Info.plist. Please define AUTH_URL_SCHEME, AUTH_URL_HOST, CONTROL_PLANE_URL_SCHEME, and CONTROL_PLANE_URL_HOST in Server.xcconfig.")
    }
    guard let urlHost = (infoPlistDictionary?["AuthURLHost"] as? String), !urlHost.isEmpty else {
      fatalError("AuthURLHost missing in Info.plist. Please define AUTH_URL_SCHEME, AUTH_URL_HOST, CONTROL_PLANE_URL_SCHEME, and CONTROL_PLANE_URL_HOST in Server.xcconfig.")
    }
    let urlString = "\(urlScheme)://\(urlHost)/"
    guard let url = URL(string: urlString) else {
      fatalError("Cannot form valid URL from string: \(urlString)")
    }
    return url
  }

  func authURL(accountId: String) -> URL {
    self.authBaseURL.appendingPathComponent(accountId)
  }
}
