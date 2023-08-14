//
//  AuthClient.swift
//  (c) 2023 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import AuthenticationServices
import Dependencies
import Foundation

enum AuthClientError: Error {
  case invalidCallbackURL(URL?)
  case openedWithURLWithBadScheme(URL)
  case missingCSRFToken(URL)
  case mismatchInCSRFToken(URL, String)
  case authResponseError(Error)
  case sessionFailure(Error)
  case noAuthSessionInProgress
}

struct AuthClient: Sendable {
  var signIn: @Sendable (URL) async throws -> AuthResponse
  var continueSignIn: @Sendable (URL) throws -> AuthResponse
}

extension AuthClient: DependencyKey {
  static var liveValue: AuthClient {
    let session = WebAuthenticationSession()
    return AuthClient(
      signIn: { host in
        try await session.signIn(host)
      },
      continueSignIn: { callbackURL in
        try session.continueSignIn(appOpenedWithURL: callbackURL)
      }
    )
  }
}

extension DependencyValues {
  var auth: AuthClient {
    get { self[AuthClient.self] }
    set { self[AuthClient.self] = newValue }
  }
}

private final class WebAuthenticationSession: NSObject,
  ASWebAuthenticationPresentationContextProviding
{
  var currentAuthSession: (webAuthSession: ASWebAuthenticationSession, host: URL, csrfToken: String)?
  @MainActor
  func signIn(_ host: URL) async throws -> AuthResponse {
    try await withCheckedThrowingContinuation { continuation in
      let csrfToken = UUID().uuidString
      let callbackURLScheme = "firezone"
      let session = ASWebAuthenticationSession(
        url: host.appendingPathComponent("sign_in")
          .appendingQueryItem(URLQueryItem(name: "client_csrf_token", value: csrfToken))
          .appendingQueryItem(URLQueryItem(name: "client_platform", value: "apple")),
        callbackURLScheme: callbackURLScheme
      ) { [weak self] callbackURL, error in

        guard let self = self else { return }

        self.currentAuthSession = nil

        if let error {
          continuation.resume(throwing: AuthClientError.sessionFailure(error))
          return
        }

        guard let callbackURL else {
          continuation.resume(throwing: AuthClientError.invalidCallbackURL(callbackURL))
          return
        }

        do {
          let authResponse = try self.readAuthCallback(portalURL: host, callbackURL: callbackURL, csrfToken: nil)
          continuation.resume(returning: authResponse)
        } catch {
          continuation.resume(throwing: error)
        }
      }

      self.currentAuthSession = (session, host, csrfToken)

      session.presentationContextProvider = self

      // We want to load any SSO cookies that the user may have set in their default browser
      session.prefersEphemeralWebBrowserSession = false

      session.start()
    }
  }

  func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
    ASPresentationAnchor()
  }

  func continueSignIn(appOpenedWithURL: URL) throws -> AuthResponse {
    guard let currentAuthSession = self.currentAuthSession else {
      throw AuthClientError.noAuthSessionInProgress
    }
    guard appOpenedWithURL.scheme == "firezone-fd0020211111" else {
      throw AuthClientError.openedWithURLWithBadScheme(appOpenedWithURL)
    }
    currentAuthSession.webAuthSession.cancel()
    self.currentAuthSession = nil
    return try readAuthCallback(portalURL: currentAuthSession.host, callbackURL: appOpenedWithURL, csrfToken: currentAuthSession.csrfToken)
  }

  private func readAuthCallback(portalURL: URL, callbackURL: URL, csrfToken: String?) throws -> AuthResponse {
    guard
      let token = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
        .queryItems?
        .first(where: { $0.name == "client_auth_token" })?
        .value
    else {
      throw AuthClientError.invalidCallbackURL(callbackURL)
    }

    guard
      let actorName = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
        .queryItems?
        .first(where: { $0.name == "actor_name" })?
        .value?
        .removingPercentEncoding?
        .replacingOccurrences(of: "+", with: " ")
    else {
      throw AuthClientError.invalidCallbackURL(callbackURL)
    }

    if let csrfToken = csrfToken {
      guard
        let callbackCSRFToken = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
          .queryItems?
          .first(where: { $0.name == "client_csrf_token" })?
          .value
      else {
        throw AuthClientError.missingCSRFToken(callbackURL)
      }

      guard callbackCSRFToken == csrfToken else {
        throw AuthClientError.mismatchInCSRFToken(callbackURL, csrfToken)
      }
    }

    return AuthResponse(portalURL: portalURL, token: token, actorName: actorName)
  }
}

extension URL {
  func appendingQueryItem(_ queryItem: URLQueryItem) -> URL {
    guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
      return self
    }

    if components.queryItems == nil {
      components.queryItems = []
    }

    components.queryItems!.append(queryItem)
    return components.url ?? self
  }
}
