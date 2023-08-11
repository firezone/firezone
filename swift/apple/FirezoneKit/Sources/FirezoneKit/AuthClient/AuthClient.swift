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
  case authResponseError(Error)
  case sessionFailure(Error)
}

struct AuthClient: Sendable {
  var signIn: @Sendable (URL) async throws -> AuthResponse
}

extension AuthClient: DependencyKey {
  static var liveValue: AuthClient {
    let session = WebAuthenticationSession()
    return AuthClient(
      signIn: { host in
        try await session.signIn(host)
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
  @MainActor
  func signIn(_ host: URL) async throws -> AuthResponse {
    try await withCheckedThrowingContinuation { continuation in
      let callbackURLScheme = "firezone"
      let session = ASWebAuthenticationSession(
        url: host.appendingPathComponent("sign_in")

          .appendingQueryItem(URLQueryItem(name: "client_platform", value: "apple")),
        callbackURLScheme: callbackURLScheme
      ) { callbackURL, error in
        if let error {
          continuation.resume(throwing: AuthClientError.sessionFailure(error))
          return
        }

        guard let callbackURL else {
          continuation.resume(throwing: AuthClientError.invalidCallbackURL(callbackURL))
          return
        }

        guard
          let token = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "client_auth_token" })?
            .value
        else {
          continuation.resume(throwing: AuthClientError.invalidCallbackURL(callbackURL))
          return
        }

        guard
          let actorName = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "actor_name" })?
            .value?
            .removingPercentEncoding?
            .replacingOccurrences(of: "+", with: " ")
        else {
          continuation.resume(throwing: AuthClientError.invalidCallbackURL(callbackURL))
          return
        }

        do {
          let authResponse = try AuthResponse(portalURL: host, token: token, actorName: actorName)
          continuation.resume(returning: authResponse)
        } catch {
          continuation.resume(throwing: AuthClientError.authResponseError(error))
        }
      }

      session.presentationContextProvider = self
      session.prefersEphemeralWebBrowserSession = true

      session.start()
    }
  }

  func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
    ASPresentationAnchor()
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
