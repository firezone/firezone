//
//  AuthClient.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import AuthenticationServices
import Foundation

enum AuthClientError: Error {
  case invalidCallbackURL
  case randomNumberGenerationFailure(errorStatus: Int32)
  case invalidAuthURL

  var description: String {
    switch self {
    case .invalidCallbackURL:
      return """
        Invalid callback URL. Please try signing in again.
        If this issue persists, contact your administrator.
        """
    case .randomNumberGenerationFailure(let errorStatus):
      return """
        Could not generate secure sign in params. Please try signing in again.
        If this issue persists, contact your administrator.

        Code: \(errorStatus)
        """
    case .invalidAuthURL:
      return """
        The provided Auth URL seems invalid. Please double-check your settings.
        """
    }
  }
}

struct AuthClient {
  private var authURL: URL
  private var state: String
  private var nonce: String

  init?(authURL: URL) throws {
    self.authURL = authURL
    state = try Self.createRandomHexString(byteCount: 32)
    nonce = try Self.createRandomHexString(byteCount: 32)
  }

  // Builds a full URL to send to the portal
  func build() throws -> URL {
    return
      authURL
      .appendingQueryItem(URLQueryItem(name: "state", value: state))
      .appendingQueryItem(URLQueryItem(name: "nonce", value: nonce))
      .appendingQueryItem(URLQueryItem(name: "as", value: "client"))
  }

  func response(url: URL?) throws -> AuthResponse {
    guard let url = url,
      let urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let returnedState = urlComponents.sanitizedQueryParam("state"),
      areStringsEqualConstantTime(state, returnedState),
      let fragment = urlComponents.sanitizedQueryParam("fragment"),
      let actorName = urlComponents.sanitizedQueryParam("actor_name"),
      let accountSlug = urlComponents.sanitizedQueryParam("account_slug")
    else {
      throw AuthClientError.invalidCallbackURL
    }

    let token = nonce + fragment

    return AuthResponse(
      actorName: actorName,
      accountSlug: accountSlug,
      token: token
    )
  }

  private static func createRandomHexString(byteCount: Int) throws -> String {
    var bytes = [Int8](repeating: 0, count: byteCount)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)

    guard status == errSecSuccess else {
      throw AuthClientError.randomNumberGenerationFailure(errorStatus: status)
    }

    return bytes.map { String(format: "%02hhx", $0) }.joined()
  }

  private func areStringsEqualConstantTime(_ string1: String, _ string2: String) -> Bool {
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

    return result == 0
  }
}

extension URL {
  func appendingQueryItem(_ queryItem: URLQueryItem) -> URL {
    guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
      return self
    }

    components.queryItems = (components.queryItems ?? []) + [queryItem]
    return components.url ?? self
  }
}

extension URLComponents {
  func sanitizedQueryParam(_ queryParam: String) -> String? {
    let value = self.queryItems?.first(where: { $0.name == queryParam })?.value

    return value?.removingPercentEncoding?.replacingOccurrences(of: "+", with: " ")
  }
}
