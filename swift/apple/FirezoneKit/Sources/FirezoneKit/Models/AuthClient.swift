//
//  AuthClient.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import AuthenticationServices
import Foundation

enum AuthClientError: Error {
  case invalidCallbackURL
  case invalidStateReturnedInCallback(expected: String, got: String)
  case authResponseError(Error)
  case sessionFailure(Error)
  case randomNumberGenerationFailure(errorStatus: Int32)
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
    return authURL
      .appendingQueryItem(URLQueryItem(name: "state", value: state))
      .appendingQueryItem(URLQueryItem(name: "nonce", value: nonce))
      .appendingQueryItem(URLQueryItem(name: "as", value: "client"))
  }

  func response(url: URL?) throws -> AuthResponse {
    guard let url = url,
          let returnedState = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "state" })?.value,
          areStringsEqualConstantTime(state, returnedState),
          let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?
          .queryItems?
          .first(where: { $0.name == "fragment" })?
          .value,
          let actorName = URLComponents(url: url, resolvingAgainstBaseURL: false)?
          .queryItems?
          .first(where: { $0.name == "actor_name" })?
          .value?
          .removingPercentEncoding?
          .replacingOccurrences(of: "+", with: " ")
    else {
      throw AuthClientError.invalidCallbackURL
    }

    let token = nonce + fragment

    return AuthResponse(token: token, actorName: actorName)
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

    if components.queryItems == nil {
      components.queryItems = []
    }

    components.queryItems!.append(queryItem)
    return components.url ?? self
  }
}
