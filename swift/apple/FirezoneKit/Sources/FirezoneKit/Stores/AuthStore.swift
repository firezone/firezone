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

  static let shared = AuthStore()

  @Dependency(\.keychain) private var keychain
  @Dependency(\.auth) private var auth
  @Dependency(\.settingsClient) private var settingsClient

  private var cancellables = Set<AnyCancellable>()

  @Published private(set) var token: Token?

  private init() {
    Task {
      self.token = await {
        guard let portalURL = settingsClient.fetchSettings()?.portalURL else {
          logger.debug("No portal URL found in settings")
          return nil
        }
        guard let tokenString = try? await keychain.tokenString() else {
          logger.debug("Token string not found in keychain")
          return nil
        }
        guard let token = try? Token(portalURL: portalURL, tokenString: tokenString) else {
          logger.debug("Token string recovered from keychain is invalid")
          return nil
        }
        logger.debug("Token recovered from keychain.")
        return token
      }()
    }

    $token.dropFirst()
      .sink { [weak self] token in
        Task { [weak self] in
          if let token {
            try? await self?.keychain.save(tokenString: token.string)
            self?.logger.debug("token saved on keychain.")
          } else {
            try? await self?.keychain.deleteTokenString()
            self?.logger.debug("token deleted from keychain.")
          }
        }
      }
      .store(in: &cancellables)
  }

  func signIn(portalURL: URL) async throws {
    logger.trace("\(#function)")

    let token = try await auth.signIn(portalURL)
    self.token = token
  }

  func signIn() async throws {
    logger.trace("\(#function)")

    let portalURL = try settingsClient.fetchSettings().flatMap(\.portalURL)
      .unwrap(throwing: FirezoneError.missingPortalURL)
    try await signIn(portalURL: portalURL)
  }

  func signOut() {
    logger.trace("\(#function)")

    token = nil
  }
}
