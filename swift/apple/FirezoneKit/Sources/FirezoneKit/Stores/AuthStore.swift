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

  @Published private(set) var authResponse: AuthResponse?

  private init() {
    Task {
      self.authResponse = await {
        guard let portalURL = settingsClient.fetchSettings()?.portalURL else {
          logger.debug("No portal URL found in settings")
          return nil
        }
        guard let token = try? await keychain.token() else {
          logger.debug("Token not found in keychain")
          return nil
        }
        guard let actorName = try? await keychain.actorName() else {
          logger.debug("Actor not found in keychain")
          return nil
        }
        guard let authResponse = try? AuthResponse(portalURL: portalURL, token: token, actorName: actorName) else {
          logger.debug("Token or Actor recovered from keychain is invalid")
          return nil
        }
        logger.debug("Token recovered from keychain.")
        return authResponse
      }()
    }

    $authResponse.dropFirst()
      .sink { [weak self] authResponse in
        Task { [weak self] in
          if let authResponse {
            try? await self?.keychain.save(token: authResponse.token, actorName: authResponse.actorName)
            self?.logger.debug("authResponse saved on keychain.")
          } else {
            try? await self?.keychain.deleteAuthResponse()
            self?.logger.debug("token deleted from keychain.")
          }
        }
      }
      .store(in: &cancellables)
  }

  func signIn(portalURL: URL) async throws {
    logger.trace("\(#function)")

    let authResponse = try await auth.signIn(portalURL)
    self.authResponse = authResponse
  }

  func signIn() async throws {
    logger.trace("\(#function)")

    let portalURL = try settingsClient.fetchSettings().flatMap(\.portalURL)
      .unwrap(throwing: FirezoneError.missingPortalURL)
    try await signIn(portalURL: portalURL)
  }

  func signOut() {
    logger.trace("\(#function)")

    authResponse = nil
  }
}
