//
//  AuthClient.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import AuthenticationServices
import Dependencies
import Foundation

enum AuthClientError: Error {
  case invalidCallbackURL(URL?)
  case invalidStateReturnedInCallback(expected: String, got: String)
  case authResponseError(Error)
  case sessionFailure(Error)
  case randomNumberGenerationFailure(errorStatus: Int32)
}

struct AuthClient: Sendable {
  var signIn: @Sendable (URL) async throws -> AuthResponse
  var cancelSignIn: @Sendable () -> Void
}

extension AuthClient: DependencyKey {
  static var liveValue: AuthClient {
    let session = WebAuthenticationSession()
    return AuthClient(
      signIn: { host in
        try await session.signIn(host)
      },
      cancelSignIn: {
        session.cancelSignIn()
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
  var webAuthSession: ASWebAuthenticationSession?

  @MainActor
  func signIn(_ host: URL) async throws -> AuthResponse {
    let statePassedToPortal = try Self.createRandomHexString(byteCount: 32)
    let nonce = try Self.createRandomHexString(byteCount: 32)
    let url =
      host
      .appendingQueryItem(URLQueryItem(name: "state", value: statePassedToPortal))
      .appendingQueryItem(URLQueryItem(name: "nonce", value: nonce))
      .appendingQueryItem(URLQueryItem(name: "as", value: "client"))
    return try await withCheckedThrowingContinuation { continuation in
      let callbackURLScheme = "firezone-fd0020211111"
      let session = ASWebAuthenticationSession(
        url: url,
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
          let stateInCallback = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "state" })?
            .value
        else {
          continuation.resume(throwing: AuthClientError.invalidCallbackURL(callbackURL))
          return
        }

        guard Self.areStringsEqualConstantTime(statePassedToPortal, stateInCallback) else {
          continuation.resume(
            throwing: AuthClientError.invalidStateReturnedInCallback(
              expected: statePassedToPortal, got: stateInCallback))
          return
        }

        guard
          let fragment = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "fragment" })?
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

        let token = nonce + fragment
        let authResponse = AuthResponse(portalURL: host, token: token, actorName: actorName)
        continuation.resume(returning: authResponse)
      }

      session.presentationContextProvider = self

      // We want to load any SSO cookies that the user may have set in their default browser
      session.prefersEphemeralWebBrowserSession = false

      session.start()

      self.webAuthSession = session
    }
  }

  static func createRandomHexString(byteCount: Int) throws -> String {
    var bytes = [Int8](repeating: 0, count: byteCount)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)

    guard status == errSecSuccess else {
      throw AuthClientError.randomNumberGenerationFailure(errorStatus: status)
    }

    return bytes.map { String(format: "%02hhx", $0) }.joined()
  }

  static func areStringsEqualConstantTime(_ string1: String, _ string2: String) -> Bool {
    let charArray1 = string1.utf8CString
    let charArray2 = string2.utf8CString

    if charArray1.count != charArray2.count {
      return false
    }

    var result: CChar = 0
    for (char1, char2) in zip(charArray1, charArray2) {
      // Iff all the XORs result in 0, then the strings are equal
      result |= (char1 ^ char2)
    }

    return (result == 0)
  }

  func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
    ASPresentationAnchor()
  }

  func cancelSignIn() {
    self.webAuthSession?.cancel()
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
